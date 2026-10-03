unit hildegard.helper.tui.approvalmodal;
{ The approval dialog: a modal box for one TApprovalAsk, drawn to the design in
  docs/design/chat_panel_tui.md.

    ╭─ Approval needed ─────────────────────────────────────────────╮
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
  dimmed (bullets, the scope label, and every keybinding), and the soft accent
  for the selected option and the active scope value.

  Keys: arrows or digits pick an option, Enter accepts it, Escape denies, Tab or
  g/w/s choose the persistence scope (default workspace, as the CLI). Picking is
  never the same as accepting: only Enter/Escape - or a click on the footer's
  accept/deny - leave the dialog.

  Mouse: moving over an option brightens it, clicking one selects it, and
  clicking the footer's accept or deny acts. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme,
  hildegard.helper.approval;

type
  TApprovalChoiceEvent = procedure(const AChoice: TApprovalChoice) of object;

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
    function RightCol(const AText: UnicodeString): Integer;
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
    property Choice: TApprovalChoice read FChoice;
    property OnChoose: TApprovalChoiceEvent read FOnChoose write FOnChoose;
  end;

implementation

uses
  SysUtils,
  hildegard.helper.tui.grapheme;

const
  { Row offsets from the box's top: the details band, then the first option. }
  RowDetails = 1;
  RowOption0 = 3;
  { Rows after the last option: a blank, the scope line, the separator, the
    footer, and the heavy bottom border. }
  RowsAfterOptions = 5;
  { The dialog is at least this wide, so a short ask still reads as a dialog. }
  MinWidth = 55;
  { Columns kept clear at the inner right edge, so right-aligned keys are not
    tight against the border. }
  RightPad = 2;
  { What the pointer is over. }
  HoverNone = -1;
  HitAccept = -2;
  HitDeny = -3;

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

function TApprovalModal.HitTest(AX, AY: Integer): Integer;
var
  N, L, R, T, B, X, FooterRow: Integer;
begin
  Result := HoverNone;
  N := Length(FAsk.Options);
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  if (AX <= L + 1) or (AX >= R - 1) or (AY <= T) or (AY >= B) then
    Exit;
  if (AY >= T + RowOption0) and (AY < T + RowOption0 + N) then
    Exit(AY - (T + RowOption0));
  FooterRow := T + RowOption0 + N + 3;
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
  I, W, OptW, InnerW: Integer;
  DetailW, ScopeW: Integer;
begin
  Result := Default(TSize);
  DetailW := StringWidth(UnicodeString(FAsk.Summary));
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
  W := DetailW;
  if OptW > W then
    W := OptW;
  if ScopeW > W then
    W := ScopeW;
  Result.W := W + 4 + RightPad;   { borders plus padding each side }
  if Result.W < MinWidth then
    Result.W := MinWidth;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
  Result.H := RowOption0 + Length(FAsk.Options) + RowsAfterOptions;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TApprovalModal.Render(const S: ISurface);
var
  L, R, T, B, N, I, X, Y, InnerL, InnerR, Row: Integer;
  Bg, BorderAttr, MutedAttr, ActiveAttr, NormalAttr, DetailAttr: TAttr;
  Key: UnicodeString;

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
  for Y := T + 1 to B - 1 do
  begin
    PutCh(S, L, Y, '│', BorderAttr);
    PutCh(S, R, Y, '│', BorderAttr);
  end;
  Text(L + 2, T, ' Approval needed ', OnBg(FTheme.Title, FTheme.RaisedBg));

  { Tool details on the sunken background. }
  if T + RowDetails < B then
  begin
    DetailAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
    S.FillRect(Rc(InnerL, T + RowDetails, InnerR - InnerL + 1, 1), DetailAttr);
    Text(InnerL + 1, T + RowDetails, UnicodeString(FAsk.Summary), DetailAttr);
  end;

  { Options: a bullet, the caption, and the numeric key right-aligned. The
    selected option, and whichever the pointer is over, use the soft accent. }
  for I := 0 to N - 1 do
  begin
    Row := T + RowOption0 + I;
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
    Row := T + RowOption0 + FSelected;
    if Row < B then
      Text(InnerL + 1, Row, '→ ', MutedAttr);
  end;

  { Scope line: dimmed label, soft-accent value, dimmed keys. }
  Row := T + RowOption0 + N + 1;
  if Row < B then
  begin
    Text(InnerL + 1, Row, 'scope: ', MutedAttr);
    Text(InnerL + 8, Row, UnicodeString(ScopeName(FScope)), ActiveAttr);
    Text(RightCol(ScopeKeys), Row, ScopeKeys, MutedAttr);
  end;

  { Separator. }
  Row := T + RowOption0 + N + 2;
  if Row < B then
  begin
    PutCh(S, L, Row, '├', BorderAttr);
    PutCh(S, R, Row, '┤', BorderAttr);
    for X := L + 1 to R - 1 do
      PutCh(S, X, Row, '─', BorderAttr);
  end;

  { Footer, right-aligned: keys dimmed, actions normal, brighter on hover. }
  Row := T + RowOption0 + N + 3;
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
