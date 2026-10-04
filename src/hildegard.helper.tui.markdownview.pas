unit hildegard.helper.tui.markdownview;
{ Draws a parsed markdown block array as a vertical stack of styled text.

  One TTextBlock per finalised block, plus one reused block for the open tail.
  A finalised block's text block is created once and never rebuilt, so a stream
  only re-measures and re-clusters the tail - flattening the whole document into
  a single TTextBlock would re-cluster everything on every chunk. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  hildegard.helper.markdown,
  hildegard.helper.tui.base, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.surface,
  hildegard.helper.tui.grapheme;

type
  TSpanList = array of TSpan;

  { A heading underline drawn beneath the heading text. }
  TBlockRule = record
    Glyph: UnicodeString;   { '' when the block has no underline }
    Width: Integer;         { preferred width (the heading text width) }
  end;

  TMarkdownView = class(TWidget)
  private
    FParser: TMarkdownParser;
    FTheme: TMdTheme;
    FBlocks: array of TTextBlock;   { one per finalised block; a rule is a dummy }
    FKinds: array of TMdBlockKind;
    FRules: array of TBlockRule;
    FTail: TTextBlock;              { the open tail, or nil }
    FTailText: UnicodeString;
    function GetBlockCount: Integer;
    function Combine(const ABase: TAttr;
      const AStyles: TMdInlineStyles): TAttr;
    function ConvertSpans(const ABlock: TMdBlock;
      const ABase: TAttr): TSpanList;
    function MakeBlock(const ABlock: TMdBlock): TTextBlock;
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

function TMarkdownView.BlockLayoutBuilds(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex <= High(FBlocks)) then
    Result := FBlocks[AIndex].LayoutBuilds
  else
    Result := -1;
end;

function TMarkdownView.LayoutBuilds: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FBlocks) do
    Inc(Result, FBlocks[I].LayoutBuilds);
  if FTail <> nil then
    Inc(Result, FTail.LayoutBuilds);
end;

function TMarkdownView.Combine(const ABase: TAttr;
  const AStyles: TMdInlineStyles): TAttr;
var
  Span: TAttr;
begin
  Result := ABase;
  if AStyles = [] then
    Exit;
  Span := StyleFor(AStyles, FTheme);
  Result.Style := Result.Style + Span.Style;
  if (misCode in AStyles) or (misLink in AStyles) then
    Result.Fg := Span.Fg;
end;

function TMarkdownView.ConvertSpans(const ABlock: TMdBlock;
  const ABase: TAttr): TSpanList;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ABlock.Spans));
  for I := 0 to High(ABlock.Spans) do
  begin
    Result[I] := Default(TSpan);
    Result[I].Text := ABlock.Spans[I].Text;
    Result[I].Attr := Combine(ABase, ABlock.Spans[I].Styles);
  end;
end;

function TMarkdownView.MakeBlock(const ABlock: TMdBlock): TTextBlock;
var
  Spans: TSpanList;
  Prefix: UnicodeString;
begin
  Result := TTextBlock.Create([], wmWord);
  case ABlock.Kind of
    mbRule:
      { The view draws the rule itself; this only claims one row. }
      Result.SetText(' ', FTheme.Rule);
    mbCodeFence:
      begin
        SetLength(Spans, 1);
        Spans[0] := Default(TSpan);
        Spans[0].Text := CodeText(ABlock);
        Spans[0].Attr := FTheme.CodeBackdrop;
        Result.SetSpans(Spans);
      end;
    mbQuote:
      Result.SetSpans(PrependSpan(ConvertSpans(ABlock, FTheme.Quote),
        '│ ', FTheme.Quote));
    mbListItem:
      begin
        if ABlock.Ordered then
          Prefix := UnicodeString(IntToStr(ABlock.Ordinal)) + '. '
        else
          Prefix := '• ';
        Result.SetSpans(PrependSpan(ConvertSpans(ABlock, FTheme.Paragraph),
          Prefix, FTheme.ListBullet));
      end;
    mbHeading:
      Result.SetSpans(ConvertSpans(ABlock,
        BlockAttr(mbHeading, ABlock.Level, FTheme)));
  else
    Result.SetSpans(ConvertSpans(ABlock, FTheme.Paragraph));
  end;
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
    FKinds[I] := B.Kind;
    FBlocks[I] := MakeBlock(B);
    FRules[I] := Default(TBlockRule);
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
  I, H: Integer;
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
    FBlocks[I].WrapWidth := AAvail.W;
    Inc(H, FBlocks[I].Measure(Default(TSize)).H);
    if FRules[I].Glyph <> '' then
      Inc(H, 1);   { the heading underline row }
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
  I, Y, RowH: Integer;
begin
  inherited Arrange(ABounds);
  Y := ABounds.Y;
  for I := 0 to High(FBlocks) do
  begin
    if I > 0 then
      Inc(Y, GapBetween(I - 1, I));
    FBlocks[I].WrapWidth := ABounds.W;
    RowH := FBlocks[I].Measure(Default(TSize)).H;
    FBlocks[I].Arrange(Rc(ABounds.X, Y, ABounds.W, RowH));
    Inc(Y, RowH);
    if FRules[I].Glyph <> '' then
      Inc(Y, 1);   { the heading underline row }
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
    else
    begin
      if FKinds[I] = mbCodeFence then
        S.FillRect(FBlocks[I].Bounds, FTheme.CodeBackdrop);
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

end.
