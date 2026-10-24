unit tui.widgets.markdownview;
{ Draws a parsed markdown block array as a vertical stack of styled text.

  One TTextBlock per finalised block, plus one reused block for the open tail.
  A finalised block's text block is created once and never rebuilt, so a stream
  only re-measures and re-clusters the tail - flattening the whole document into
  a single TTextBlock would re-cluster everything on every chunk. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  hildegard.helper.markdown,
  tui.base, tui.widget,
  tui.widgets.text, tui.surface,
  tui.grapheme;

type
  TSpanList = array of TSpan;

  { A heading underline drawn beneath the heading text. }
  TBlockRule = record
    Glyph: UnicodeString;   { '' when the block has no underline }
    Width: Integer;         { preferred width (the heading text width) }
  end;

  { One mbTable block: a rounded grid whose columns are sized to content and
    whose cells wrap when the table is wider than the available width. }
  TTableBlock = class(TWidget)
  private
    FTheme: TMdTheme;
    FAlign: TMdAlignArray;
    FCols: Integer;
    FRows: Integer;                 { including the header }
    FCells: array of TTextBlock;    { FRows * FCols, row-major, header first }
    FNatW: array of Integer;        { per-cell natural (unwrapped) width }
    FMinW: array of Integer;        { per-cell longest-word width }
    FLinesMemo: array of TIntArray; { per-cell line count by width; -1 = unknown }
    FColNat: TIntArray;             { per-column natural width }
    FColMin: TIntArray;             { per-column word floor }
    FColW: array of Integer;        { resolved column widths }
    FRowH: array of Integer;        { resolved row heights }
    FUsedW: Integer;
    procedure BuildCells(const AHead: TMdTableRow; const ARows: TMdTableRows);
    procedure Layout(AWidth: Integer);
    procedure AllocateWidths(ABudget: Integer);
    function CellLines(ARow, ACol, AWidth: Integer): Integer;
    function ColumnHeight(ACol, AWidth: Integer): Integer;
    function NextDrop(ACol, AWidth: Integer): Integer;
    function MinWidthForHeight(ARow, ACol, H: Integer): Integer;
    function ColumnWidthForHeight(ACol, H: Integer): Integer;
    function RowHeight(ARow: Integer): Integer;
    function TotalHeight: Integer;
    function TotalHeightWith(ACol, AWidth: Integer): Integer;
    function Horizontal(const ALeft, AMid, ARight: UnicodeString): UnicodeString;
  public
    constructor Create(const ABlock: TMdBlock; const ATheme: TMdTheme);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    { Instrumentation: total layout builds across the cells. }
    function LayoutBuilds: Integer;
  end;

  TMarkdownView = class(TWidget)
  private
    FParser: TMarkdownParser;
    FTheme: TMdTheme;
    FBlocks: array of TWidget;      { one per finalised block }
    FKinds: array of TMdBlockKind;
    FRules: array of TBlockRule;
    FLangs: array of UnicodeString;  { a code fence's language, else '' }
    FTail: TTextBlock;              { the open tail, or nil }
    FTailText: UnicodeString;
    function GetBlockCount: Integer;
    function MakeBlock(const ABlock: TMdBlock): TWidget;
    function GapBetween(AIndex, ANext: Integer): Integer;
    procedure SyncChildren;
    procedure FreeChildren;
  public
    constructor Create(const ATheme: TMdTheme); overload;
    constructor Create; overload;
    destructor Destroy; override;

    { Parse a complete document (resets the parser). }
    procedure SetSource(const AText: string);
    { Feed a streaming chunk. }
    procedure AppendSource(const AChunk: string);
    { End the stream: the open tail becomes a final block. }
    procedure FinishSource;

    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;

    { The number of finalised blocks currently drawn. Grows monotonically as a
      stream arrives. }
    property BlockCount: Integer read GetBlockCount;
    { Instrumentation: the layout builds of the finalised block at AIndex, or -1.
      A finalised block's count does not change when a later chunk arrives. }
    function BlockLayoutBuilds(AIndex: Integer): Integer;
    { Diagnostic: the total layout builds across the blocks and the tail. }
    function LayoutBuilds: Integer;
  end;

implementation

uses
  SysUtils;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function RepeatChar(const ACh: UnicodeString; AN: Integer): UnicodeString;
var
  I: Integer;
begin
  if (AN < 0) or (ACh = '') then
    Exit('');
  SetLength(Result, AN);
  for I := 1 to AN do
    Result[I] := ACh[1];
end;

{ The widest cell for which a line count is memoised; beyond it a probe just
  recomputes. Bounds the memo for a pathological single-cell column. }
const
  MaxMemoWidth = 256;

function CodeText(const ABlock: TMdBlock): UnicodeString;
begin
  if Length(ABlock.Spans) > 0 then
    Result := ABlock.Spans[0].Text
  else
    Result := '';
end;

{ The underline glyph for a heading level, or '' when it has none. H1-H3 are
  underlined; H4-H6 are just bold and bright. }
function HeadingRuleGlyph(ALevel: Integer): UnicodeString;
begin
  case ALevel of
    1:
      Result := '━';
    2:
      Result := '═';
    3:
      Result := '─';
  else
    Result := '';
  end;
end;

{ The display width of a block's text, used to size a heading underline. }
function SpansWidth(const ASpans: TMdSpanArray): Integer;
var
  I: Integer;
  T: UnicodeString;
begin
  T := '';
  for I := 0 to High(ASpans) do
    T := T + ASpans[I].Text;
  Result := StringWidth(T);
end;

function PrependSpan(const ASpans: TSpanList; const AText: UnicodeString;
  const AAttr: TAttr): TSpanList;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ASpans) + 1);
  Result[0] := Default(TSpan);
  Result[0].Text := AText;
  Result[0].Attr := AAttr;
  for I := 0 to High(ASpans) do
    Result[I + 1] := ASpans[I];
end;

{ The width available to code inside its box (a border column and a space each
  side). }
function CodeInnerWidth(AWidth: Integer): Integer;
begin
  Result := AWidth - 4;
  if Result < 1 then
    Result := 1;
end;

{ Move an attribute onto an explicit background (the sunken code surface). }
function OnSurface(const AAttr: TAttr; ABg: Byte): TAttr;
begin
  Result := AAttr;
  Result.Bg := ABg;
  Exclude(Result.Style, sfScreenBg);
end;

{ Draw a fenced code block: a rounded thin box on the sunken surface, full
  width, with the language right-aligned on the top border. }
procedure DrawCodeBox(const S: ISurface; const R: TRect;
  const ALanguage: UnicodeString; const ATheme: TMdTheme);
var
  L, Rt, T, Bt, I, Fill: Integer;
  Border, Lang: TAttr;
  LangTag: UnicodeString;
begin
  if (R.W < 2) or (R.H < 2) then
    Exit;
  L := R.X;
  Rt := R.X + R.W - 1;
  T := R.Y;
  Bt := R.Y + R.H - 1;
  S.FillRect(R, ATheme.CodeBackdrop);
  Border := OnSurface(ATheme.Rule, ATheme.CodeBackdrop.Bg);
  Lang := OnSurface(ATheme.Muted, ATheme.CodeBackdrop.Bg);
  LangTag := '';
  if ALanguage <> '' then
    LangTag := UnicodeString(' ') + ALanguage + UnicodeString(' ');
  if (LangTag <> '') and (StringWidth(LangTag) <= R.W - 4) then
  begin
    { ╭───── lang ─╮ }
    Fill := R.W - 2 - StringWidth(LangTag) - 1;
    PutText(S, L, T, UnicodeString('╭') + RepeatChar('─', Fill), Border);
    PutText(S, L + 1 + Fill, T, LangTag, Lang);
    PutText(S, L + 1 + Fill + StringWidth(LangTag), T,
      UnicodeString('─╮'), Border);
  end
  else
    PutText(S, L, T, UnicodeString('╭') + RepeatChar('─', R.W - 2) +
      UnicodeString('╮'), Border);
  PutText(S, L, Bt, UnicodeString('╰') + RepeatChar('─', R.W - 2) +
    UnicodeString('╯'), Border);
  for I := T + 1 to Bt - 1 do
  begin
    PutCh(S, L, I, UnicodeString('│'), Border);
    PutCh(S, Rt, I, UnicodeString('│'), Border);
  end;
end;

{ --- TMarkdownView ------------------------------------------------------- }

constructor TMarkdownView.Create(const ATheme: TMdTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FParser := TMarkdownParser.Create;
  FBlocks := nil;
  FKinds := nil;
  FTail := nil;
  FTailText := '';
end;

constructor TMarkdownView.Create;
begin
  Create(DefaultMdTheme);
end;

destructor TMarkdownView.Destroy;
begin
  FreeChildren;
  FParser.Free;
  inherited Destroy;
end;

function TMarkdownView.GetBlockCount: Integer;
begin
  Result := Length(FBlocks);
end;

{ A block's layout-build count; a table sums its cells. }
function BlockBuilds(const AW: TWidget): Integer;
begin
  if AW is TTextBlock then
    Result := TTextBlock(AW).LayoutBuilds
  else if AW is TTableBlock then
    Result := TTableBlock(AW).LayoutBuilds
  else
    Result := 0;
end;

function TMarkdownView.BlockLayoutBuilds(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex <= High(FBlocks)) then
    Result := BlockBuilds(FBlocks[AIndex])
  else
    Result := -1;
end;

function TMarkdownView.LayoutBuilds: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FBlocks) do
    Inc(Result, BlockBuilds(FBlocks[I]));
  if FTail <> nil then
    Inc(Result, FTail.LayoutBuilds);
end;

{ A styled run carries its own colour; an unstyled run takes the block's. }
function Combine(const ABase: TAttr; const AStyles: TMdInlineStyles;
  const ATheme: TMdTheme): TAttr;
begin
  if AStyles = [] then
    Result := ABase
  else
    Result := StyleFor(AStyles, ATheme);
end;

function ConvertSpans(const ASpans: TMdSpanArray; const ABase: TAttr;
  const ATheme: TMdTheme): TSpanList;
var
  I: Integer;
  Txt: UnicodeString;
begin
  Result := nil;
  SetLength(Result, Length(ASpans));
  for I := 0 to High(ASpans) do
  begin
    Result[I] := Default(TSpan);
    Txt := ASpans[I].Text;
    { A code chip is padded one space each side so it stands out from the words
      around it. }
    if misCode in ASpans[I].Styles then
      Txt := UnicodeString(' ') + Txt + UnicodeString(' ');
    Result[I].Text := Txt;
    Result[I].Attr := Combine(ABase, ASpans[I].Styles, ATheme);
  end;
end;

{ The concatenated text of a span list, for width measurement. }
function SpanListText(const ASpans: TSpanList): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ASpans) do
    Result := Result + ASpans[I].Text;
end;

{ The display width of the longest space-delimited run in AText. }
function TextLongestWord(const AText: UnicodeString): Integer;
var
  I, Start, L: Integer;
begin
  Result := 0;
  Start := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = ' ') then
    begin
      if I > Start then
      begin
        L := StringWidth(Copy(AText, Start, I - Start));
        if L > Result then
          Result := L;
      end;
      Start := I + 1;
    end;
end;

function AlignOf(const AAlign: TMdAlign): TTextAlign;
begin
  case AAlign of
    maCenter:
      Result := taCenter;
    maRight:
      Result := taRight;
  else
    Result := taLeft;
  end;
end;

function TMarkdownView.MakeBlock(const ABlock: TMdBlock): TWidget;
var
  Text: TTextBlock;
  Spans: TSpanList;
  Prefix: UnicodeString;
begin
  { A table is a grid of cells, not a single text block. }
  if ABlock.Kind = mbTable then
  begin
    Result := TTableBlock.Create(ABlock, FTheme);
    Exit;
  end;
  Text := TTextBlock.Create([], wmWord);
  case ABlock.Kind of
    mbRule:
      { The view draws the rule itself; this only claims one row. }
      Text.SetText(' ', FTheme.Rule);
    mbCodeFence:
      begin
        SetLength(Spans, 1);
        Spans[0] := Default(TSpan);
        Spans[0].Text := CodeText(ABlock);
        Spans[0].Attr := FTheme.CodeBackdrop;
        Text.SetSpans(Spans);
      end;
    mbQuote:
      Text.SetSpans(PrependSpan(
        ConvertSpans(ABlock.Spans, FTheme.Quote, FTheme), '│ ', FTheme.Quote));
    mbListItem:
      begin
        if ABlock.Ordered then
          Prefix := UnicodeString(IntToStr(ABlock.Ordinal)) + '. '
        else
          Prefix := '• ';
        Text.SetSpans(PrependSpan(
          ConvertSpans(ABlock.Spans, FTheme.Paragraph, FTheme), Prefix,
          FTheme.ListBullet));
        { Hang the wrapped text under the item text, not under the marker. }
        Text.HangIndent := StringWidth(Prefix);
      end;
    mbHeading:
      Text.SetSpans(ConvertSpans(ABlock.Spans,
        BlockAttr(mbHeading, ABlock.Level, FTheme), FTheme));
  else
    Text.SetSpans(ConvertSpans(ABlock.Spans, FTheme.Paragraph, FTheme));
  end;
  Result := Text;
end;

procedure TMarkdownView.FreeChildren;
var
  I: Integer;
begin
  for I := 0 to High(FBlocks) do
    FBlocks[I].Free;
  FBlocks := nil;
  FKinds := nil;
  FRules := nil;
  FLangs := nil;
  if FTail <> nil then
    FTail.Free;
  FTail := nil;
  FTailText := '';
end;

procedure TMarkdownView.SyncChildren;
var
  N, I: Integer;
  B: TMdBlock;
  Raw: UnicodeString;
  Spans: TSpanList;
begin
  { Create children only for blocks that have finalised; they never change. }
  N := FParser.FinalizedCount;
  while Length(FBlocks) < N do
  begin
    I := Length(FBlocks);
    B := FParser.FinalizedBlock(I);
    SetLength(FBlocks, I + 1);
    SetLength(FKinds, I + 1);
    SetLength(FRules, I + 1);
    SetLength(FLangs, I + 1);
    FKinds[I] := B.Kind;
    FBlocks[I] := MakeBlock(B);
    FRules[I] := Default(TBlockRule);
    FLangs[I] := B.Language;
    if B.Kind = mbHeading then
    begin
      FRules[I].Glyph := HeadingRuleGlyph(B.Level);
      FRules[I].Width := SpansWidth(B.Spans);
    end;
  end;

  { The open tail is one reused text block, redrawn as it grows. }
  Raw := FParser.TailText;
  if Raw = FTailText then
    Exit;
  FTailText := Raw;
  if Raw = '' then
  begin
    if FTail <> nil then
      FTail.SetSpans([]);
    Exit;
  end;
  if FTail = nil then
    FTail := TTextBlock.Create([], wmWord);
  SetLength(Spans, 1);
  Spans[0] := Default(TSpan);
  Spans[0].Text := Raw;
  Spans[0].Attr := FTheme.Paragraph;
  FTail.SetSpans(Spans);
end;

procedure TMarkdownView.SetSource(const AText: string);
begin
  FParser.Reset;
  FreeChildren;
  FParser.Append(AText);
  FParser.Finish;
  SyncChildren;
end;

procedure TMarkdownView.AppendSource(const AChunk: string);
begin
  FParser.Append(AChunk);
  SyncChildren;
end;

procedure TMarkdownView.FinishSource;
begin
  FParser.Finish;
  SyncChildren;
end;

function TMarkdownView.GapBetween(AIndex, ANext: Integer): Integer;
begin
  if (FKinds[AIndex] = mbListItem) and (FKinds[ANext] = mbListItem) then
    Result := 0
  else
    Result := 1;
end;

function TMarkdownView.Measure(const AAvail: TSize): TSize;
var
  I, H, Inner: Integer;
begin
  Result := Default(TSize);
  if AAvail.W < 1 then
    Exit;
  Result.W := AAvail.W;
  H := 0;
  for I := 0 to High(FBlocks) do
  begin
    if I > 0 then
      Inc(H, GapBetween(I - 1, I));
    if FKinds[I] = mbCodeFence then
    begin
      Inner := CodeInnerWidth(AAvail.W);
      TTextBlock(FBlocks[I]).WrapWidth := Inner;
      Inc(H, FBlocks[I].Measure(Default(TSize)).H + 2);  { the box borders }
    end
    else if FKinds[I] = mbTable then
      Inc(H, FBlocks[I].Measure(AAvail).H)
    else
    begin
      TTextBlock(FBlocks[I]).WrapWidth := AAvail.W;
      Inc(H, FBlocks[I].Measure(Default(TSize)).H);
      if FRules[I].Glyph <> '' then
        Inc(H, 1);   { the heading underline row }
    end;
  end;
  if (FTail <> nil) and (FTailText <> '') then
  begin
    if Length(FBlocks) > 0 then
      Inc(H, 1);
    FTail.WrapWidth := AAvail.W;
    Inc(H, FTail.Measure(Default(TSize)).H);
  end;
  Result.H := H;
end;

procedure TMarkdownView.Arrange(const ABounds: TRect);
var
  I, Y, RowH, Inner: Integer;
  Avail: TSize;
begin
  inherited Arrange(ABounds);
  Avail := Default(TSize);
  Avail.W := ABounds.W;
  Avail.H := ABounds.H;
  Y := ABounds.Y;
  for I := 0 to High(FBlocks) do
  begin
    if I > 0 then
      Inc(Y, GapBetween(I - 1, I));
    if FKinds[I] = mbCodeFence then
    begin
      Inner := CodeInnerWidth(ABounds.W);
      TTextBlock(FBlocks[I]).WrapWidth := Inner;
      RowH := FBlocks[I].Measure(Default(TSize)).H;
      FBlocks[I].Arrange(Rc(ABounds.X + 2, Y + 1, Inner, RowH));
      Inc(Y, RowH + 2);
    end
    else if FKinds[I] = mbTable then
    begin
      RowH := FBlocks[I].Measure(Avail).H;
      FBlocks[I].Arrange(Rc(ABounds.X, Y, ABounds.W, RowH));
      Inc(Y, RowH);
    end
    else
    begin
      TTextBlock(FBlocks[I]).WrapWidth := ABounds.W;
      RowH := FBlocks[I].Measure(Default(TSize)).H;
      FBlocks[I].Arrange(Rc(ABounds.X, Y, ABounds.W, RowH));
      Inc(Y, RowH);
      if FRules[I].Glyph <> '' then
        Inc(Y, 1);   { the heading underline row }
    end;
  end;
  if (FTail <> nil) and (FTailText <> '') then
  begin
    if Length(FBlocks) > 0 then
      Inc(Y, 1);
    FTail.WrapWidth := ABounds.W;
    RowH := FTail.Measure(Default(TSize)).H;
    FTail.Arrange(Rc(ABounds.X, Y, ABounds.W, RowH));
  end;
end;

procedure TMarkdownView.Render(const S: ISurface);
var
  I, RuleW: Integer;
begin
  if (FBounds.W < 1) or (FBounds.H < 1) then
    Exit;
  S.PushClip(FBounds);
  for I := 0 to High(FBlocks) do
    if FKinds[I] = mbRule then
      PutText(S, FBlocks[I].Bounds.X, FBlocks[I].Bounds.Y,
        RepeatChar('─', FBlocks[I].Bounds.W), FTheme.Rule)
    else if FKinds[I] = mbCodeFence then
    begin
      { The box surrounds the inset text block. }
      DrawCodeBox(S, Rc(FBlocks[I].Bounds.X - 2, FBlocks[I].Bounds.Y - 1,
        FBlocks[I].Bounds.W + 4, FBlocks[I].Bounds.H + 2), FLangs[I], FTheme);
      FBlocks[I].Render(S);
    end
    else if FKinds[I] = mbTable then
      FBlocks[I].Render(S)
    else
    begin
      FBlocks[I].Render(S);
      if FRules[I].Glyph <> '' then
      begin
        RuleW := FRules[I].Width;
        if (RuleW < 1) or (RuleW > FBlocks[I].Bounds.W) then
          RuleW := FBlocks[I].Bounds.W;
        PutText(S, FBlocks[I].Bounds.X,
          FBlocks[I].Bounds.Y + FBlocks[I].Bounds.H,
          RepeatChar(FRules[I].Glyph, RuleW), FTheme.Rule);
      end;
    end;
  if (FTail <> nil) and (FTailText <> '') then
    FTail.Render(S);
  S.PopClip;
end;

{ --- TTableBlock -------------------------------------------------------- }

constructor TTableBlock.Create(const ABlock: TMdBlock; const ATheme: TMdTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FAlign := ABlock.Align;
  FCols := Length(FAlign);
  BuildCells(ABlock.Head, ABlock.Rows);
end;

destructor TTableBlock.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FCells) do
    FCells[I].Free;
  inherited Destroy;
end;

procedure TTableBlock.BuildCells(const AHead: TMdTableRow;
  const ARows: TMdTableRows);
var
  R, C, I, N, J, MemoSize: Integer;
  Spans: TSpanList;
  Base: TAttr;
  Txt: UnicodeString;
begin
  FCells := nil;
  FNatW := nil;
  FMinW := nil;
  FLinesMemo := nil;
  FRows := 0;
  if FCols < 1 then
    Exit;
  FRows := 1 + Length(ARows);
  N := FRows * FCols;
  SetLength(FCells, N);
  SetLength(FNatW, N);
  SetLength(FMinW, N);
  SetLength(FLinesMemo, N);
  for R := 0 to FRows - 1 do
    for C := 0 to FCols - 1 do
    begin
      I := R * FCols + C;
      if R = 0 then
      begin
        Base := FTheme.Bold;
        if C <= High(AHead) then
          Spans := ConvertSpans(AHead[C], Base, FTheme)
        else
          Spans := nil;
      end
      else
      begin
        Base := FTheme.Paragraph;
        if (R - 1 <= High(ARows)) and (C <= High(ARows[R - 1])) then
          Spans := ConvertSpans(ARows[R - 1][C], Base, FTheme)
        else
          Spans := nil;
      end;
      FCells[I] := TTextBlock.Create(Spans, wmWord);
      Txt := SpanListText(Spans);
      FNatW[I] := StringWidth(Txt);
      FMinW[I] := TextLongestWord(Txt);
      { A per-cell line-count memo, filled lazily as the width search probes. }
      MemoSize := FNatW[I] + 1;
      if MemoSize > MaxMemoWidth + 1 then
        MemoSize := MaxMemoWidth + 1;
      SetLength(FLinesMemo[I], MemoSize);
      for J := 0 to High(FLinesMemo[I]) do
        FLinesMemo[I][J] := -1;
    end;
end;

function TTableBlock.Horizontal(const ALeft, AMid,
  ARight: UnicodeString): UnicodeString;
var
  C: Integer;
begin
  Result := ALeft;
  for C := 0 to FCols - 1 do
  begin
    if C > 0 then
      Result := Result + AMid;
    Result := Result + RepeatChar('─', FColW[C] + 2);
  end;
  Result := Result + ARight;
end;

procedure TTableBlock.Layout(AWidth: Integer);
var
  C, R, I, Chrome, Budget, H: Integer;
begin
  FUsedW := 0;
  if FCols < 1 then
    Exit;
  Chrome := 3 * FCols + 1;
  Budget := AWidth - Chrome;
  if Budget < FCols then
    Budget := FCols;   { a grid narrower than its chrome is clipped }
  AllocateWidths(Budget);
  for C := 0 to FCols - 1 do
    Inc(FUsedW, FColW[C]);
  Inc(FUsedW, Chrome);

  SetLength(FRowH, FRows);
  for R := 0 to FRows - 1 do
  begin
    FRowH[R] := 1;
    for C := 0 to FCols - 1 do
    begin
      I := R * FCols + C;
      FCells[I].WrapWidth := FColW[C];
      FCells[I].Align := AlignOf(FAlign[C]);
      H := FCells[I].Measure(Default(TSize)).H;
      if H > FRowH[R] then
        FRowH[R] := H;
    end;
  end;
end;

{ A cell's line count at AWidth, memoised. }
function TTableBlock.CellLines(ARow, ACol, AWidth: Integer): Integer;
var
  I: Integer;
  M: TIntArray;
begin
  I := ARow * FCols + ACol;
  if AWidth < 1 then
    AWidth := 1;
  M := FLinesMemo[I];
  if (M <> nil) and (AWidth <= High(M)) then
  begin
    if M[AWidth] < 0 then
      M[AWidth] := FCells[I].LineCountAt(AWidth);
    Result := M[AWidth];
  end
  else
    Result := FCells[I].LineCountAt(AWidth);
end;

{ The tallest cell in a column at AWidth. }
function TTableBlock.ColumnHeight(ACol, AWidth: Integer): Integer;
var
  R, H: Integer;
begin
  Result := 1;
  for R := 0 to FRows - 1 do
  begin
    H := CellLines(R, ACol, AWidth);
    if H > Result then
      Result := H;
  end;
end;

{ The smallest width above AWidth at which the column's tallest cell drops a
  line, or its natural width + 1 when it cannot. ColumnHeight is non-increasing
  in the width, so a binary search finds the drop. }
function TTableBlock.NextDrop(ACol, AWidth: Integer): Integer;
var
  Lo, Hi, Mid, H: Integer;
begin
  H := ColumnHeight(ACol, AWidth);
  Lo := AWidth + 1;
  Hi := FColNat[ACol];
  Result := Hi + 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if ColumnHeight(ACol, Mid) < H then
    begin
      Result := Mid;
      Hi := Mid - 1;
    end
    else
      Lo := Mid + 1;
  end;
end;

function TTableBlock.RowHeight(ARow: Integer): Integer;
var
  C, H: Integer;
begin
  Result := 1;
  for C := 0 to FCols - 1 do
  begin
    H := CellLines(ARow, C, FColW[C]);
    if H > Result then
      Result := H;
  end;
end;

function TTableBlock.TotalHeight: Integer;
var
  R: Integer;
begin
  Result := 0;
  for R := 0 to FRows - 1 do
    Inc(Result, RowHeight(R));
end;

{ The total height with column ACol widened to AWidth, the rest unchanged. }
function TTableBlock.TotalHeightWith(ACol, AWidth: Integer): Integer;
var
  R, C, H, RH: Integer;
begin
  Result := 0;
  for R := 0 to FRows - 1 do
  begin
    RH := 1;
    for C := 0 to FCols - 1 do
    begin
      if C = ACol then
        H := CellLines(R, C, AWidth)
      else
        H := CellLines(R, C, FColW[C]);
      if H > RH then
        RH := H;
    end;
    Inc(Result, RH);
  end;
end;

{ The smallest width (at or above the cell's word floor) at which the cell wraps
  to at most H lines. LineCount is non-increasing in the width, so binary
  search. }
function TTableBlock.MinWidthForHeight(ARow, ACol, H: Integer): Integer;
var
  I, Lo, Hi, Mid, FloorW, NatW: Integer;
begin
  I := ARow * FCols + ACol;
  FloorW := FMinW[I];
  if FloorW < 1 then
    FloorW := 1;
  NatW := FNatW[I];
  if NatW < FloorW then
    NatW := FloorW;
  if CellLines(ARow, ACol, FloorW) <= H then
  begin
    Result := FloorW;
    Exit;
  end;
  Lo := FloorW + 1;
  Hi := NatW;
  Result := NatW;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if CellLines(ARow, ACol, Mid) <= H then
    begin
      Result := Mid;
      Hi := Mid - 1;
    end
    else
      Lo := Mid + 1;
  end;
end;

{ The width a column needs so every one of its cells fits in H lines. }
function TTableBlock.ColumnWidthForHeight(ACol, H: Integer): Integer;
var
  R, W: Integer;
begin
  Result := 1;
  for R := 0 to FRows - 1 do
  begin
    W := MinWidthForHeight(R, ACol, H);
    if W > Result then
      Result := W;
  end;
end;

procedure TTableBlock.AllocateWidths(ABudget: Integer);
var
  C, R, I, SumNat, SumMin, Used, Over, Best, BestRoom, BestW: Integer;
  MaxH, H, Lo, Hi, Mid, SumW: Integer;
  Feasible: Boolean;
  BestI, BestGain, BestCost, W2, Cost, Gain: Integer;
begin
  SetLength(FColNat, FCols);
  SetLength(FColMin, FCols);
  SumNat := 0;
  SumMin := 0;
  for C := 0 to FCols - 1 do
  begin
    FColNat[C] := 1;
    FColMin[C] := 1;
    for R := 0 to FRows - 1 do
    begin
      I := R * FCols + C;
      if FNatW[I] > FColNat[C] then
        FColNat[C] := FNatW[I];
      if FMinW[I] > FColMin[C] then
        FColMin[C] := FMinW[I];
    end;
    if FColMin[C] > FColNat[C] then
      FColMin[C] := FColNat[C];
    if FColMin[C] < 1 then
      FColMin[C] := 1;
    if FColNat[C] < 1 then
      FColNat[C] := 1;
    Inc(SumNat, FColNat[C]);
    Inc(SumMin, FColMin[C]);
  end;

  SetLength(FColW, FCols);
  { Content width: if the columns fit, use their natural widths and stop. }
  if SumNat <= ABudget then
  begin
    for C := 0 to FCols - 1 do
      FColW[C] := FColNat[C];
    Exit;
  end;

  if SumMin > ABudget then
  begin
    { Even the word floors overflow: squeeze the widest columns (words break). }
    for C := 0 to FCols - 1 do
      FColW[C] := FColMin[C];
    Over := SumMin - ABudget;
    while Over > 0 do
    begin
      Best := -1;
      BestW := 0;
      for C := 0 to FCols - 1 do
        if FColW[C] > BestW then
        begin
          BestW := FColW[C];
          Best := C;
        end;
      if (Best < 0) or (BestW <= 1) then
        Break;
      Dec(FColW[Best]);
      Dec(Over);
    end;
    Exit;
  end;

  { Search for the smallest per-row line budget H for which every cell fits the
    width; each column then takes exactly the width it needs for H lines. This
    is what balances the columns, rather than letting the widest column keep all
    the slack. Feasibility is monotone in H, so binary search it. }
  MaxH := 1;
  for C := 0 to FCols - 1 do
    for R := 0 to FRows - 1 do
      if CellLines(R, C, FColMin[C]) > MaxH then
        MaxH := CellLines(R, C, FColMin[C]);
  Lo := 1;
  Hi := MaxH;
  Feasible := False;
  H := MaxH;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    SumW := 0;
    for C := 0 to FCols - 1 do
      Inc(SumW, ColumnWidthForHeight(C, Mid));
    if SumW <= ABudget then
    begin
      Feasible := True;
      H := Mid;
      Hi := Mid - 1;
    end
    else
      Lo := Mid + 1;
  end;
  for C := 0 to FCols - 1 do
    if Feasible then
      FColW[C] := ColumnWidthForHeight(C, H)
    else
      FColW[C] := FColMin[C];

  { Spend any leftover width on the drops that shrink the tallest rows, so the
    total falls further and an over-wide table still fills its container. }
  Used := 0;
  for C := 0 to FCols - 1 do
    Inc(Used, FColW[C]);
  repeat
    BestI := -1;
    BestGain := 0;
    BestCost := MaxInt;
    BestW := 0;
    for C := 0 to FCols - 1 do
    begin
      if FColW[C] >= FColNat[C] then
        Continue;
      W2 := NextDrop(C, FColW[C]);
      if W2 > FColNat[C] then
        Continue;
      Cost := W2 - FColW[C];
      if Used + Cost > ABudget then
        Continue;
      Gain := TotalHeight - TotalHeightWith(C, W2);
      if (Gain > BestGain) or
        ((Gain = BestGain) and (Gain > 0) and (Cost < BestCost)) then
      begin
        BestI := C;
        BestGain := Gain;
        BestCost := Cost;
        BestW := W2;
      end;
    end;
    if (BestI < 0) or (BestGain <= 0) then
      Break;
    FColW[BestI] := BestW;
    Inc(Used, BestCost);
  until False;

  while Used < ABudget do
  begin
    Best := -1;
    BestRoom := 0;
    for C := 0 to FCols - 1 do
      if FColNat[C] - FColW[C] > BestRoom then
      begin
        BestRoom := FColNat[C] - FColW[C];
        Best := C;
      end;
    if (Best < 0) or (BestRoom <= 0) then
      Break;
    Inc(FColW[Best]);
    Inc(Used);
  end;
end;

function TTableBlock.Measure(const AAvail: TSize): TSize;
var
  R: Integer;
begin
  Result := Default(TSize);
  if FCols < 1 then
    Exit;
  Layout(AAvail.W);
  Result.W := FUsedW;
  Result.H := FRows + 1;   { a top border, a rule per row, a bottom border }
  for R := 0 to FRows - 1 do
    Inc(Result.H, FRowH[R]);
end;

procedure TTableBlock.Arrange(const ABounds: TRect);
var
  X, Y, R, C: Integer;
begin
  inherited Arrange(ABounds);
  if FCols < 1 then
    Exit;
  Layout(ABounds.W);
  Y := ABounds.Y + 1;   { below the top border }
  for R := 0 to FRows - 1 do
  begin
    if R > 0 then
      Inc(Y, 1);   { the rule before this row }
    X := ABounds.X + 2;
    for C := 0 to FCols - 1 do
    begin
      FCells[R * FCols + C].Arrange(Rc(X, Y, FColW[C], FRowH[R]));
      Inc(X, FColW[C] + 3);
    end;
    Inc(Y, FRowH[R]);
  end;
end;

procedure TTableBlock.Render(const S: ISurface);
var
  X, Y, R, C, I, SepX: Integer;
  Border: TAttr;
begin
  if (FBounds.W < 1) or (FBounds.H < 1) or (FCols < 1) then
    Exit;
  Border := FTheme.Rule;
  X := FBounds.X;
  Y := FBounds.Y;
  S.PushClip(FBounds);
  PutText(S, X, Y, Horizontal('╭', '┬', '╮'), Border);
  Inc(Y, 1);
  for R := 0 to FRows - 1 do
  begin
    if R > 0 then
    begin
      PutText(S, X, Y, Horizontal('├', '┼', '┤'), Border);
      Inc(Y, 1);
    end;
    for C := 0 to FCols - 1 do
      FCells[R * FCols + C].Render(S);
    for I := 0 to FRowH[R] - 1 do
    begin
      PutCh(S, X, Y + I, '│', Border);
      SepX := X + 2;
      for C := 0 to FCols - 1 do
      begin
        Inc(SepX, FColW[C]);
        PutCh(S, SepX + 1, Y + I, '│', Border);
        Inc(SepX, 3);
      end;
    end;
    Inc(Y, FRowH[R]);
  end;
  PutText(S, X, Y, Horizontal('╰', '┴', '╯'), Border);
  S.PopClip;
end;

function TTableBlock.LayoutBuilds: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FCells) do
    Inc(Result, FCells[I].LayoutBuilds);
end;

end.
