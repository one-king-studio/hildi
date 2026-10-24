unit tui.widgets.approvalmodal;
{ The approval dialog: a modal box for one TApprovalAsk, drawn to the design in
  docs/design/chat_panel_tui.md.

    ╭─ Approval needed ─────────────────────────────────────────────╮
    │ reason: free space before the deploy                          │
    │ rm -rf build/                                                 │
    │                                                               │
    │ → allow once                                                1 │
    │ ◦ always this exact command                                 2 │
    │ ◦ always command with any arguments                         3 │
    │                                                               │
    │ scope: workspace                              tab / g w s     │
    ├───────────────────────────────────────────────────────────────┤
    │                             enter accept   esc deny           │
    ╰═══════════════════════════════════════════════════════════════╯

  Three text roles only, from the theme: normal (labels and unselected values),
  dimmed (the reason label, bullets, the scope label, and every keybinding), and
  the soft accent for the selected option and the active scope value.

  The reason sits beneath the title; the tool details follow on the sunken band,
  wrapped to the width and compacted when long, so a big command cannot grow the
  dialog without bound. The dialog keeps four columns and four rows clear of the
  screen edge.

  Keys: arrows or digits pick an option, Enter accepts it, Escape denies, Tab or
  g/w/s choose the persistence scope (default workspace, as the CLI). Picking is
  never the same as accepting: only Enter/Escape - or a click on the footer's
  accept/deny - leave the dialog.

  Mouse: moving over an option brightens it, clicking one selects it, and
  clicking the footer's accept or deny acts. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme, tui.compact,
  hildegard.helper.approval;

type
  TApprovalChoiceEvent = procedure(const AChoice: TApprovalChoice) of object;

  { One display row of the ask's script: the wrapped text and the part of it
    that falls inside the focus span (1-based within Text; HiLen 0 = outside). }
  TScriptRow = record
    Text: UnicodeString;
    HiStart, HiLen: Integer;
  end;
  TScriptRowArray = array of TScriptRow;

  TApprovalModal = class(TWidget)
  private
    FAsk: TApprovalAsk;
    FTheme: TTheme;
    FSelected: Integer;
    FScope: TApprovalScope;
    FAnswered: Boolean;
    FChoice: TApprovalChoice;
    FOnChoose: TApprovalChoiceEvent;
    FHover: Integer;
    { The script laid out for the current width, the row holding the focus, and
      the first row shown. Empty when the ask has no script (older producer). }
    FScriptRows: TScriptRowArray;
    FFocusRow: Integer;
    FScroll: Integer;
    FScriptWidth: Integer;
    procedure EnsureLayout(AWidth: Integer);
    function ScriptBandRows: Integer;
    procedure ScrollBy(ADelta: Integer);
    function SummaryLines(AWidth: Integer): TUnicodeLines;
    { The summary is shown when there is no script (an older producer), and
      beside one for an effect ask (`file:read` and friends), where the path is
      the thing being approved and the script is its context. }
    function ShowSummary: Boolean;
    function RightCol(const AText: UnicodeString): Integer;
    function RowOptionBase: Integer;
    function HitTest(AX, AY: Integer): Integer;
    procedure Choose(AIndex: Integer);
    procedure Deny;
    procedure CycleScope;
  public
    constructor Create(const AAsk: TApprovalAsk); overload;
    constructor Create(const AAsk: TApprovalAsk;
      const ATheme: TTheme); overload;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    property Ask: TApprovalAsk read FAsk;
    property Theme: TTheme read FTheme write FTheme;
    { The option the arrow is on; accepting is a separate action. }
    property Selected: Integer read FSelected;
    property Answered: Boolean read FAnswered;
    { The first script row the details band shows. }
    property Scroll: Integer read FScroll;
    property Choice: TApprovalChoice read FChoice;
    property OnChoose: TApprovalChoiceEvent read FOnChoose write FOnChoose;
  end;

implementation

uses
  SysUtils, tui.grapheme;

const
  { Rows after the last option: a blank, the scope line, the separator, the
    footer, and the heavy bottom border. }
  RowsAfterOptions = 5;
  { The dialog is at least this wide, so a short ask still reads as a dialog. }
  MinWidth = 55;
  { Columns kept clear at the inner right edge, so right-aligned keys are not
    tight against the border. }
  RightPad = 2;
  { Columns/rows kept clear of the screen edge when the dialog grows. }
  EdgePad = 4;
  { Width of the 'reason: ' label, before the reason text. }
  ReasonLabelW = 8;
  { Inline padding inside the sunken details band, on each side. }
  DetailPad = 2;
  { The script band never shows more rows than this; PageUp/PageDown (or the
    wheel) scroll the rest. }
  MaxScriptRows = 8;
  { What the pointer is over. }
  HoverNone = -1;
  HitAccept = -2;
  HitDeny = -3;

function WrapPlain(const AText: UnicodeString; AWidth: Integer): TUnicodeLines; forward;

{ Word-wrap the script to AWidth columns, honouring explicit newlines and
  hard-breaking a word longer than the line, marking the characters inside the
  ask's focus span. The span is 1-based bytes into the UTF-8 script and the
  layout is in characters, so it is converted once: a span always ends on a
  token boundary, hence on a character boundary. AFocusRow = the row holding
  the span's first character, -1 when there is no focus. }
procedure LayoutScript(const AScript: string; AFocusStart, AFocusLen,
  AWidth: Integer; out ARows: TScriptRowArray; out AFocusRow: Integer);
var
  U: UnicodeString;
  F0, F1, RowCount, ParaStart, I: Integer;

  procedure Push(const AText: UnicodeString; AFrom, ATo: Integer);
  var
    Row: TScriptRow;
    HS, HE: Integer;
  begin
    Row := Default(TScriptRow);
    Row.Text := AText;
    if (F1 >= F0) and (ATo >= AFrom) then
    begin
      HS := F0;
      if HS < AFrom then
        HS := AFrom;
      HE := F1;
      if HE > ATo then
        HE := ATo;
      if HS <= HE then
      begin
        Row.HiStart := HS - AFrom + 1;
        Row.HiLen := HE - HS + 1;
      end;
      if (AFocusRow < 0) and (F0 >= AFrom) and (F0 <= ATo) then
        AFocusRow := RowCount;
    end;
    SetLength(ARows, RowCount + 1);
    ARows[RowCount] := Row;
    Inc(RowCount);
  end;

  procedure EmitPara(const APara: UnicodeString; const AParaStart: Integer);
  var
    C: TClusterArray;
    Prefix: array of Integer;
    K, J, Q, W, CurW, LastSpace, Start: Integer;

    function Slice(AFrom, ATo: Integer): UnicodeString;
    var
      X: Integer;
    begin
      Result := '';
      for X := AFrom to ATo do
        Result := Result + C[X];
    end;

    procedure Emit(AFrom, ATo: Integer);
    begin
      if AFrom > ATo then
        Push('', AParaStart, AParaStart - 1)
      else
        Push(Slice(AFrom, ATo), AParaStart + Prefix[AFrom],
          AParaStart + Prefix[ATo + 1] - 1);
    end;

  begin
    C := Clusters(APara);
    if Length(C) = 0 then
    begin
      Push('', AParaStart, AParaStart - 1);
      Exit;
    end;
    SetLength(Prefix, Length(C) + 1);
    Prefix[0] := 0;
    for Q := 0 to High(C) do
      Prefix[Q + 1] := Prefix[Q] + Length(C[Q]);
    Start := 0;
    CurW := 0;
    LastSpace := -1;
    K := 0;
    while K <= High(C) do
    begin
      W := ClusterWidth(C[K]);
      if (CurW + W > AWidth) and (K > Start) then
      begin
        if LastSpace > Start then
        begin
          Emit(Start, LastSpace - 1);
          Start := LastSpace + 1;
        end
        else
        begin
          Emit(Start, K - 1);
          Start := K;
        end;
        CurW := 0;
        LastSpace := -1;
        for J := Start to K - 1 do
        begin
          Inc(CurW, ClusterWidth(C[J]));
          if C[J] = ' ' then
            LastSpace := J;
        end;
        Continue;
      end;
      if C[K] = ' ' then
        LastSpace := K;
      Inc(CurW, W);
      Inc(K);
    end;
    Emit(Start, High(C));
  end;

begin
  ARows := nil;
  AFocusRow := -1;
  RowCount := 0;
  U := UnicodeString(AScript);
  F0 := 1;
  if AFocusStart > 1 then
    F0 := Length(UnicodeString(Copy(AScript, 1, AFocusStart - 1))) + 1;
  if (AFocusLen > 0) and (AFocusStart > 0) then
    F1 := F0 + Length(UnicodeString(Copy(AScript, AFocusStart, AFocusLen))) - 1
  else
    F1 := F0 - 1;

  ParaStart := 1;
  I := 1;
  while I <= Length(U) do
  begin
    if (U[I] = #13) or (U[I] = #10) then
    begin
      EmitPara(Copy(U, ParaStart, I - ParaStart), ParaStart);
      if (U[I] = #13) and (I < Length(U)) and (U[I + 1] = #10) then
        Inc(I);
      ParaStart := I + 1;
    end;
    Inc(I);
  end;
  EmitPara(Copy(U, ParaStart, Length(U) - ParaStart + 1), ParaStart);
end;

procedure TApprovalModal.EnsureLayout(AWidth: Integer);
begin
  if (FAsk.Script = '') or (AWidth < 1) then
  begin
    FScriptRows := nil;
    FFocusRow := -1;
    FScroll := 0;
    FScriptWidth := 0;
    Exit;
  end;
  if (FScriptWidth > 0) and (AWidth = FScriptWidth) then
    Exit;
  LayoutScript(FAsk.Script, FAsk.FocusStart, FAsk.FocusLen, AWidth,
    FScriptRows, FFocusRow);
  FScriptWidth := AWidth;
  FScroll := 0;
  { Open on the command being approved, when the script is longer than the
    band. }
  if FFocusRow >= MaxScriptRows then
    FScroll := FFocusRow - (MaxScriptRows div 2);
  ScrollBy(0);
end;

function TApprovalModal.SummaryLines(AWidth: Integer): TUnicodeLines;
begin
  Result := WrapPlain(CompactLines(UnicodeString(FAsk.Summary),
    DefaultCompactOptions), AWidth);
end;

function TApprovalModal.ShowSummary: Boolean;
begin
  Result := (FAsk.Script = '') or (FAsk.Subject.Path <> '');
end;

function TApprovalModal.ScriptBandRows: Integer;
begin
  Result := Length(FScriptRows);
  if Result > MaxScriptRows then
    Result := MaxScriptRows;
end;

procedure TApprovalModal.ScrollBy(ADelta: Integer);
var
  Max: Integer;
begin
  Inc(FScroll, ADelta);
  Max := Length(FScriptRows) - MaxScriptRows;
  if Max < 0 then
    Max := 0;
  if FScroll > Max then
    FScroll := Max;
  if FScroll < 0 then
    FScroll := 0;
end;

function ScopeName(AScope: TApprovalScope): string;
begin
  case AScope of
    asGlobal:
      Result := 'global';
    asSession:
      Result := 'session';
  else
    Result := 'workspace';
  end;
end;

function ScopeKeys: UnicodeString;
begin
  Result := 'tab / g w s';
end;

function FooterKeys: UnicodeString;
begin
  Result := 'enter accept   esc deny';
end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function LongestLineWidth(const AText: UnicodeString): Integer;
var
  I, Start: Integer;

  procedure Consider(AFrom, ATo: Integer);
  var
    W: Integer;
  begin
    W := StringWidth(Copy(AText, AFrom, ATo - AFrom + 1));
    if W > Result then
      Result := W;
  end;

begin
  Result := 0;
  Start := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = #10) or (AText[I] = #13) then
    begin
      Consider(Start, I - 1);
      Start := I + 1;
    end;
end;

{ Word-wrap AText to AWidth columns, honouring explicit newlines and
  hard-breaking a word longer than the width. Cluster-aware. }
function WrapPlain(const AText: UnicodeString; AWidth: Integer): TUnicodeLines;
var
  Para: UnicodeString;
  I: Integer;

  procedure Push(const S: UnicodeString);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

  procedure WrapPara(const APara: UnicodeString);
  var
    C: TClusterArray;
    K, J, W, CurW, LastSpace, Start: Integer;

    function Slice(AFrom, ATo: Integer): UnicodeString;
    var
      Q: Integer;
    begin
      Result := '';
      for Q := AFrom to ATo do
        Result := Result + C[Q];
    end;

  begin
    if AWidth < 1 then
    begin
      Push(APara);
      Exit;
    end;
    C := Clusters(APara);
    if Length(C) = 0 then
    begin
      Push('');
      Exit;
    end;
    Start := 0;
    CurW := 0;
    LastSpace := -1;
    K := 0;
    while K <= High(C) do
    begin
      W := ClusterWidth(C[K]);
      if (CurW + W > AWidth) and (K > Start) then
      begin
        if LastSpace > Start then
        begin
          Push(Slice(Start, LastSpace - 1));
          Start := LastSpace + 1;
        end
        else
        begin
          Push(Slice(Start, K - 1));
          Start := K;
        end;
        CurW := 0;
        LastSpace := -1;
        for J := Start to K - 1 do
        begin
          Inc(CurW, ClusterWidth(C[J]));
          if C[J] = ' ' then
            LastSpace := J;
        end;
        Continue;
      end;
      if C[K] = ' ' then
        LastSpace := K;
      Inc(CurW, W);
      Inc(K);
    end;
    Push(Slice(Start, High(C)));
  end;

begin
  Result := nil;
  Para := '';
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = #13) or (AText[I] = #10) then
    begin
      if (AText[I] = #13) and (I < Length(AText)) and (AText[I + 1] = #10) then
        Inc(I);
      WrapPara(Para);
      Para := '';
    end
    else
      Para := Para + AText[I];
    Inc(I);
  end;
  WrapPara(Para);
end;

{ The wrap widths for the reason text and the details band inside a box of
  ABoxW columns. The details carry an inline pad on each side. }
procedure ContentWidths(const ABoxW: Integer; out AReasonW, ADetailW: Integer);
begin
  ADetailW := ABoxW - 4 - 2 * DetailPad;
  AReasonW := ABoxW - 4 - ReasonLabelW;
  if ADetailW < 1 then
    ADetailW := 1;
  if AReasonW < 1 then
    AReasonW := 1;
end;

constructor TApprovalModal.Create(const AAsk: TApprovalAsk);
begin
  Create(AAsk, DarkTheme);
end;

constructor TApprovalModal.Create(const AAsk: TApprovalAsk;
  const ATheme: TTheme);
begin
  inherited Create;
  FAsk := AAsk;
  FTheme := ATheme;
  FSelected := 0;
  FScope := asWorkspace;
  FAnswered := False;
  FHover := HoverNone;
end;

function TApprovalModal.RightCol(const AText: UnicodeString): Integer;
begin
  Result := FBounds.X + FBounds.W - 1 - 1 - RightPad - StringWidth(AText) + 1;
end;

function TApprovalModal.RowOptionBase: Integer;
var
  ReasonW, DetailW, R, D: Integer;
begin
  ContentWidths(FBounds.W, ReasonW, DetailW);
  R := Length(WrapPlain(CompactLines(UnicodeString(FAsk.Reason),
    DefaultCompactOptions), ReasonW));
  D := 0;
  if ShowSummary then
    Inc(D, Length(SummaryLines(DetailW)));
  if FAsk.Script <> '' then
  begin
    EnsureLayout(DetailW);
    Inc(D, ScriptBandRows);
  end;
  if R < 1 then
    R := 1;
  if D < 1 then
    D := 1;
  { Top border, the reason rows, a blank, the details rows, and one blank. }
  Result := FBounds.Y + 1 + R + 1 + D + 1;
end;

function TApprovalModal.HitTest(AX, AY: Integer): Integer;
var
  N, L, R, T, B, X, Option0, FooterRow: Integer;
begin
  Result := HoverNone;
  N := Length(FAsk.Options);
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  if (AX <= L + 1) or (AX >= R - 1) or (AY <= T) or (AY >= B) then
    Exit;
  Option0 := RowOptionBase;
  if (AY >= Option0) and (AY < Option0 + N) then
    Exit(AY - Option0);
  FooterRow := Option0 + N + 3;
  if AY = FooterRow then
  begin
    X := RightCol(FooterKeys);
    if (AX >= X) and (AX < X + 12) then
      Exit(HitAccept);
    if (AX >= X + 15) and (AX < X + 23) then
      Exit(HitDeny);
  end;
end;

function TApprovalModal.Measure(const AAvail: TSize): TSize;
var
  I, W, OptW, ScopeW, InnerW, MaxW, MaxH, R, D, ReasonW, DetailW: Integer;
  NaturalW: Integer;
begin
  Result := Default(TSize);
  ScopeW := StringWidth(UnicodeString('scope: ') +
    UnicodeString(ScopeName(FScope))) + 2 + StringWidth(ScopeKeys);
  if StringWidth(FooterKeys) > ScopeW then
    ScopeW := StringWidth(FooterKeys);
  OptW := 0;
  for I := 0 to High(FAsk.Options) do
  begin
    InnerW := 2 + StringWidth(UnicodeString(FAsk.Options[I].Caption)) + 2 +
      StringWidth(UnicodeString(IntToStr(I + 1)));
    if InnerW > OptW then
      OptW := InnerW;
  end;
  W := OptW;
  if ScopeW > W then
    W := ScopeW;
  if W < MinWidth then
    W := MinWidth;
  { Let a wide reason or detail line widen the box, up to the edge padding. }
  NaturalW := LongestLineWidth(UnicodeString(FAsk.Summary)) + 4;
  if LongestLineWidth(UnicodeString(FAsk.Reason)) + 4 + ReasonLabelW >
    NaturalW then
    NaturalW := LongestLineWidth(UnicodeString(FAsk.Reason)) + 4 +
      ReasonLabelW;
  if NaturalW > W then
    W := NaturalW;
  { The edge padding only bites once the dialog is wider than the minimum; on a
    very narrow screen the dialog uses what it can. }
  MaxW := AAvail.W - 2 * EdgePad;
  if MaxW < MinWidth then
    MaxW := AAvail.W;
  if W > MaxW then
    W := MaxW;
  if W < 4 then
    W := 4;
  Result.W := W;

  ContentWidths(W, ReasonW, DetailW);
  R := Length(WrapPlain(CompactLines(UnicodeString(FAsk.Reason),
    DefaultCompactOptions), ReasonW));
  D := 0;
  if ShowSummary then
    Inc(D, Length(SummaryLines(DetailW)));
  if FAsk.Script <> '' then
  begin
    EnsureLayout(DetailW);
    Inc(D, ScriptBandRows);
  end;
  if R < 1 then
    R := 1;
  if D < 1 then
    D := 1;
  Result.H := R + D + Length(FAsk.Options) + RowsAfterOptions + 3;
  MaxH := AAvail.H - 2 * EdgePad;
  if MaxH < 7 then
    MaxH := AAvail.H;
  if Result.H > MaxH then
    Result.H := MaxH;
end;

procedure TApprovalModal.Render(const S: ISurface);
var
  L, R, T, B, N, I, X, Row, InnerL, InnerR, Option0: Integer;
  D, Col, RowIdx: Integer;
  ReasonW, DetailW: Integer;
  Bg, BorderAttr, MutedAttr, ActiveAttr, NormalAttr, DetailAttr: TAttr;
  DimAttr, FocusAttr: TAttr;
  Key: UnicodeString;
  SRow: TScriptRow;
  ReasonLines, DetailLines: TUnicodeLines;

  procedure Text(ACol, ARow: Integer; const AText: UnicodeString;
    const AAttr: TAttr);
  begin
    PutText(S, ACol, ARow, AText, AAttr);
  end;

  procedure Action(ACol, ARow: Integer; const AText: UnicodeString;
    AActive: Boolean);
  begin
    if AActive then
      Text(ACol, ARow, AText, ActiveAttr)
    else
      Text(ACol, ARow, AText, NormalAttr);
  end;

begin
  if (FBounds.W < 4) or (FBounds.H < 4) then
    Exit;
  N := Length(FAsk.Options);
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  InnerL := L + 1;
  InnerR := R - 1;

  Bg := OnBg(FTheme.Text, FTheme.RaisedBg);
  BorderAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  MutedAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  ActiveAttr := OnBg(FTheme.AccentSoft, FTheme.RaisedBg);
  NormalAttr := OnBg(FTheme.Text, FTheme.RaisedBg);

  S.FillRect(FBounds, Bg);

  { Rounded top with the title, a heavy bottom edge, and side borders. }
  PutCh(S, L, T, '╭', BorderAttr);
  PutCh(S, R, T, '╮', BorderAttr);
  PutCh(S, L, B, '╰', BorderAttr);
  PutCh(S, R, B, '╯', BorderAttr);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '─', BorderAttr);
    PutCh(S, X, B, '═', BorderAttr);
  end;
  for X := T + 1 to B - 1 do
  begin
    PutCh(S, L, X, '│', BorderAttr);
    PutCh(S, R, X, '│', BorderAttr);
  end;
  Text(L + 2, T, ' Approval needed ', OnBg(FTheme.Title, FTheme.RaisedBg));

  ContentWidths(FBounds.W, ReasonW, DetailW);
  ReasonLines := WrapPlain(CompactLines(UnicodeString(FAsk.Reason),
    DefaultCompactOptions), ReasonW);
  DetailLines := WrapPlain(CompactLines(UnicodeString(FAsk.Summary),
    DefaultCompactOptions), DetailW);

  { Reason beneath the title: a muted label, the reason text (or a placeholder). }
  Row := T + 1;
  for I := 0 to High(ReasonLines) do
  begin
    if Row >= B then
      Break;
    if I = 0 then
      Text(InnerL + 1, Row, 'reason: ', MutedAttr);
    if FAsk.Reason = '' then
      Text(InnerL + 1 + ReasonLabelW, Row, '—', MutedAttr)
    else
      Text(InnerL + 1 + ReasonLabelW, Row, ReasonLines[I], NormalAttr);
    Inc(Row);
  end;

  { A blank line, then the details on the sunken background, with an inline
    pad on each side. With a script, the whole command is shown, scrolled to
    the focus: the span being approved is bold and the rest of the script is
    dimmed - rendition only, no colour, so the eye lands on the command being
    approved. Without a script (an older producer) the summary is wrapped and
    compacted. }
  Inc(Row);
  if Row < B then
  begin
    DetailAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
    DimAttr := OnBg(WithStyle(FTheme.Text, [sfDim]), FTheme.SunkenBg);
    if ShowSummary then
      for I := 0 to High(DetailLines) do
      begin
        if Row >= B then
          Break;
        S.FillRect(Rc(InnerL, Row, InnerR - InnerL + 1, 1), DetailAttr);
        Text(InnerL + DetailPad, Row, DetailLines[I], DetailAttr);
        Inc(Row);
      end;
    if FAsk.Script <> '' then
    begin
      EnsureLayout(DetailW);
      FocusAttr := OnBg(WithStyle(FTheme.Text, [sfBold]), FTheme.SunkenBg);
      D := ScriptBandRows;
      for I := 0 to D - 1 do
      begin
        if Row >= B then
          Break;
        RowIdx := FScroll + I;
        if RowIdx > High(FScriptRows) then
          Break;
        S.FillRect(Rc(InnerL, Row, InnerR - InnerL + 1, 1), DetailAttr);
        if RowIdx = FFocusRow then
          Text(InnerL + 1, Row, '→', FocusAttr);
        SRow := FScriptRows[RowIdx];
        if SRow.HiLen > 0 then
        begin
          Col := InnerL + DetailPad;
          if SRow.HiStart > 1 then
          begin
            Text(Col, Row, Copy(SRow.Text, 1, SRow.HiStart - 1), DimAttr);
            Inc(Col, StringWidth(Copy(SRow.Text, 1, SRow.HiStart - 1)));
          end;
          Text(Col, Row, Copy(SRow.Text, SRow.HiStart, SRow.HiLen), FocusAttr);
          Inc(Col, StringWidth(Copy(SRow.Text, SRow.HiStart, SRow.HiLen)));
          Text(Col, Row, Copy(SRow.Text, SRow.HiStart + SRow.HiLen, MaxInt),
            DimAttr);
        end
        else
          Text(InnerL + DetailPad, Row, SRow.Text, DimAttr);
        Inc(Row);
      end;
    end;
  end;

  Option0 := RowOptionBase;

  { Options: a bullet, the caption, and the numeric key right-aligned. The
    selected option, and whichever the pointer is over, use the soft accent. }
  for I := 0 to N - 1 do
  begin
    Row := Option0 + I;
    if Row >= B then
      Break;
    Key := UnicodeString(IntToStr(I + 1));
    Text(InnerL + 1, Row, '◦ ', MutedAttr);
    if (I = FSelected) or (I = FHover) then
      Text(InnerL + 3, Row, UnicodeString(FAsk.Options[I].Caption), ActiveAttr)
    else
      Text(InnerL + 3, Row, UnicodeString(FAsk.Options[I].Caption), NormalAttr);
    Text(RightCol(Key), Row, Key, MutedAttr);
  end;
  if (FSelected >= 0) and (FSelected < N) then
  begin
    Row := Option0 + FSelected;
    if Row < B then
      Text(InnerL + 1, Row, '→ ', MutedAttr);
  end;

  { Scope line: dimmed label, soft-accent value, dimmed keys. }
  Row := Option0 + N + 1;
  if Row < B then
  begin
    Text(InnerL + 1, Row, 'scope: ', MutedAttr);
    Text(InnerL + 8, Row, UnicodeString(ScopeName(FScope)), ActiveAttr);
    Text(RightCol(ScopeKeys), Row, ScopeKeys, MutedAttr);
  end;

  { Separator. }
  Row := Option0 + N + 2;
  if Row < B then
  begin
    PutCh(S, L, Row, '├', BorderAttr);
    PutCh(S, R, Row, '┤', BorderAttr);
    for X := L + 1 to R - 1 do
      PutCh(S, X, Row, '─', BorderAttr);
  end;

  { Footer, right-aligned: keys dimmed, actions normal, brighter on hover. }
  Row := Option0 + N + 3;
  if Row < B then
  begin
    X := RightCol(FooterKeys);
    Text(X, Row, 'enter', MutedAttr);
    Inc(X, StringWidth('enter'));
    Action(X, Row, ' accept', FHover = HitAccept);
    Inc(X, StringWidth(' accept'));
    Text(X, Row, '   ', NormalAttr);
    Inc(X, StringWidth('   '));
    Text(X, Row, 'esc', MutedAttr);
    Inc(X, StringWidth('esc'));
    Action(X, Row, ' deny', FHover = HitDeny);
  end;
end;

procedure TApprovalModal.Choose(AIndex: Integer);
begin
  if FAnswered then
    Exit;
  FChoice := Default(TApprovalChoice);
  if (AIndex >= 0) and (AIndex < Length(FAsk.Options)) then
  begin
    FChoice.Allowed := True;
    FChoice.OptionKey := FAsk.Options[AIndex].Key;
    FChoice.Scope := FScope;
  end;
  FAnswered := True;
  if Assigned(FOnChoose) then
    FOnChoose(FChoice);
end;

procedure TApprovalModal.Deny;
begin
  Choose(-1);
end;

procedure TApprovalModal.CycleScope;
begin
  case FScope of
    asWorkspace:
      FScope := asSession;
    asSession:
      FScope := asGlobal;
  else
    FScope := asWorkspace;
  end;
end;

function TApprovalModal.HandleEvent(const E: TInputEvent): Boolean;
var
  N, Hit: Integer;
begin
  if FAnswered then
    Exit(False);

  if E.Kind = ikMouse then
  begin
    Hit := HitTest(E.Mouse.X, E.Mouse.Y);
    if E.Mouse.Button = mbNone then
    begin
      { Motion (or a release): brighten whatever is under the pointer. }
      if Hit = FHover then
        Exit(False);
      FHover := Hit;
      Exit(True);
    end;
    if (E.Mouse.Button = mbWheelUp) or (E.Mouse.Button = mbWheelDown) then
    begin
      if FAsk.Script = '' then
        Exit(False);
      EnsureLayout(FBounds.W - 2 - 2 * DetailPad);
      if E.Mouse.Button = mbWheelUp then
        ScrollBy(-3)
      else
        ScrollBy(3);
      Exit(True);
    end;
    if E.Mouse.Button = mbLeft then
    begin
      if Hit = HitAccept then
      begin
        if Length(FAsk.Options) = 0 then
          Deny
        else
          Choose(FSelected);
        Exit(True);
      end;
      if Hit = HitDeny then
      begin
        Deny;
        Exit(True);
      end;
      if Hit >= 0 then
      begin
        { Selecting is not accepting; Enter (or the footer) is. }
        FSelected := Hit;
        Exit(True);
      end;
    end;
    Exit(False);
  end;

  if E.Kind <> ikKey then
    Exit(False);
  case E.Key.Kind of
    kkUp, kkLeft:
      begin
        if FSelected > 0 then
          Dec(FSelected);
        Exit(True);
      end;
    kkDown, kkRight:
      begin
        if FSelected < Length(FAsk.Options) - 1 then
          Inc(FSelected);
        Exit(True);
      end;
    kkPageUp:
      begin
        EnsureLayout(FBounds.W - 2 - 2 * DetailPad);
        ScrollBy(-(MaxScriptRows - 1));
        Exit(True);
      end;
    kkPageDown:
      begin
        EnsureLayout(FBounds.W - 2 - 2 * DetailPad);
        ScrollBy(MaxScriptRows - 1);
        Exit(True);
      end;
    kkEnter:
      begin
        if Length(FAsk.Options) = 0 then
          Deny
        else
          Choose(FSelected);
        Exit(True);
      end;
    kkEscape:
      begin
        Deny;
        Exit(True);
      end;
    kkTab:
      begin
        CycleScope;
        Exit(True);
      end;
    kkChar:
      begin
        if E.Key.Ch = 'g' then
        begin
          FScope := asGlobal;
          Exit(True);
        end;
        if E.Key.Ch = 'w' then
        begin
          FScope := asWorkspace;
          Exit(True);
        end;
        if E.Key.Ch = 's' then
        begin
          FScope := asSession;
          Exit(True);
        end;
        N := StrToIntDef(string(E.Key.Ch), 0);
        if (N >= 1) and (N <= Length(FAsk.Options)) then
        begin
          { A digit selects only; accepting stays a separate action. }
          FSelected := N - 1;
          Exit(True);
        end;
        Exit(False);
      end;
  else
    ;
  end;
  Result := False;
end;

end.
