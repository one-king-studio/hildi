unit hildegard.helper.tui.chat;
{ The chat stream: a scrolling column of message blocks for the harness UI.

  A block is a raised user bubble, plain assistant text, a dimmed collapsible
  thought block, a sunken collapsible tool block, or the animated thinking
  indicator. Blocks are mutable, so a turn can stream into one in place.

  The stream bleeds one column into the panel's right border so the scrollbar
  occupies that border column: its track is not painted (the border reads as the
  track) and only the thumb shows. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.grapheme,
  hildegard.helper.tui.compact, hildegard.helper.tui.scroll,
  hildegard.helper.tui.theme, hildegard.helper.tui.markdownview;

type
  TChatKind = (ckUser, ckAssistant, ckError, ckThought, ckTool, ckThinking,
    ckTurn, ckAmbient, ckQueued);

const
  { The violet used for the queued/ambient border, matching inline code. }
  QueuedBorderFg = 140;

type
  { One block in the stream. Mutable, so a stream can append into it. Its
    measured height is memoized per width and invalidated when the text or the
    expansion changes, so a layout pass does not re-measure unchanged blocks. }
  TChatItem = class(TWidget)
  private
    FKind: TChatKind;
    FLabel: string;
    FBody: string;
    FText: TTextBlock;
    FMarkdown: TMarkdownView;   { assistant bodies only; nil otherwise }
    FExpanded: Boolean;
    FTheme: TTheme;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    FSpark: Integer;
    FLive: Boolean;
    { True once AppendText has fed the markdown view as a stream. The body must
      then only ever be finished (never re-SetSource), or the open tail would be
      committed early and the next chunk would start a spurious second block. }
    FLiveStarted: Boolean;
    FHeightValid: Boolean;
    FHeightWidth: Integer;
    FHeight: Integer;
    FMeasureCount: Integer;
    function Inset: Integer;
    function BodyAttr: TAttr;
    function EffectiveExpanded: Boolean;
    function DisplayBody: string;
    procedure Rebuild;
    procedure EnsureBody;
    procedure ArrangeBody(const ABounds: TRect);
    procedure BodyRows(AWidth: Integer; out ATextRows, ALines: Integer);
    function Boxed: Boolean;
    procedure InvalidateHeight;
    procedure SetExpanded(AValue: Boolean);
    procedure SetLive(AValue: Boolean);
  public
    constructor Create(AKind: TChatKind; const ALabel, AText: string;
      const ATheme: TTheme);
    destructor Destroy; override;
    { Replace or append the body text (streaming); both fire OnChange. }
    procedure SetText(const AText: string);
    procedure AppendText(const AText: string);
    { End a streamed body: the open markdown tail becomes its final block, so
      the last (still-open) block is parsed and styled. Idempotent; a no-op
      unless AppendText streamed this body. }
    procedure Finalize;
    function Text: string;
    { Build or free the rendered body (spans or markdown). A block off the
      viewport releases it; the memoized height survives, so the scroll extent
      is unchanged. }
    procedure Materialize;
    procedure Dematerialize;
    function Materialized: Boolean;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Kind: TChatKind read FKind;
    property Label_: string read FLabel write FLabel;
    { Collapsed or expanded; changing it invalidates the height and fires
      OnChange. }
    property Expanded: Boolean read FExpanded write SetExpanded;
    { A live block (streaming reasoning) shows the tail of its body and cannot
      be toggled; it becomes a normal block when the stream finishes. }
    property Live: Boolean read FLive write SetLive;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    { Diagnostic: how many times this block's body text has been laid out. A
      steady-state render/scroll must not increase it. }
    function LayoutBuilds: Integer;
    { Diagnostic: how many times this block was actually measured (not served
      from the height memo). }
    function MeasureCount: Integer;
  end;

  { A vertical stack of blocks, measured at the available width. It memoizes
    each block's height and the running offsets, rebuilt only when a block
    changes (its generation) or the width changes, so a scroll re-uses the
    layout instead of re-measuring every block. }
  TChatStack = class(TWidget)
  private
    FItems: array of TChatItem;
    FTheme: TTheme;
    FGap: Integer;
    FBottomInset: Integer;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    FGeneration: Integer;
    FAnimatingBlocks: Integer;    { blocks whose kind is ckThinking }
    FLayoutValid: Boolean;
    FLayoutWidth: Integer;
    FLayoutGeneration: Integer;
    FLayoutTotal: Integer;
    FLayoutRuns: Integer;         { how often the layout was rebuilt; diagnostic }
    FLayoutY: array of Integer;   { each block's top, relative to the stack }
    FLayoutH: array of Integer;   { each block's height }
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
    { The width an item is measured and arranged at: the stack's width less the
      one-column inset on each side. Measure and Arrange must agree, or the text
      layout cache thrashes between two widths. }
    function ItemWidth(AStackWidth: Integer): Integer;
    procedure BumpGeneration;
    procedure RefreshAnimation;
    procedure EnsureLayout(AItemWidth: Integer);
    procedure ItemChanged(Sender: TObject);
    procedure ItemToggled(Sender: TObject);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    procedure Clear;
    { How many blocks currently hold a rendered layout (the rest are windowed
      out). Diagnostic. }
    function MaterializedCount: Integer;
    { How many times the block layout was rebuilt. A steady-state measure/render
      cycle must not increase it. Diagnostic. }
    function LayoutRuns: Integer;
    { How many blocks are animating (the thinking indicator). Diagnostic. }
    function AnimatingCount: Integer;
    { Drop and free one block, e.g. the thinking indicator once text arrives. }
    procedure Remove(AItem: TChatItem);
    { Rows at the bottom of the viewport that something else covers (the compose
      overlay). The stack keeps room for them, so the last block still shows its
      two blank pad rows above the overlay. }
    property BottomInset: Integer read FBottomInset write FBottomInset;
    { Assign a callback to every block, including ones added earlier. }
    procedure SetOnToggle(AValue: TNotifyEvent);
    procedure SetOnChange(AValue: TNotifyEvent);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  { The scrolling stream of blocks, sticky to the bottom. }
  TChatStream = class(TWidget)
  private
    FStack: TChatStack;
    FScroll: TScrollContainer;
    FFollow: Boolean;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    FBottomInset: Integer;
    procedure SetOnToggle(AValue: TNotifyEvent);
    procedure SetOnChange(AValue: TNotifyEvent);
    procedure SetBottomInset(AValue: Integer);
    procedure ItemChanged(Sender: TObject);
    procedure ItemToggled(Sender: TObject);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Append a block and stick the view to it. }
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    procedure Clear;
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
    { The newest block, or nil when empty. }
    function Last: TChatItem;
    { Drop and free one block, e.g. the thinking indicator once text arrives. }
    procedure Remove(AItem: TChatItem);
    { Re-stick the view to the newest block. }
    procedure FollowBottom;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property OnToggle: TNotifyEvent read FOnToggle write SetOnToggle;
    { Fired when a block's text changes, so the host re-arranges. }
    property OnChange: TNotifyEvent read FOnChange write SetOnChange;
    { Rows at the bottom of the viewport covered by the compose overlay; the
      stream keeps room for them so the last block keeps its pad rows visible. }
    property BottomInset: Integer read FBottomInset write SetBottomInset;
  end;

{ The sparkle glyph for the thinking indicator at time ANowMs: a burst that
  cycles every 90 ms. Shared by the stream's indicator and the toolbar. }
function ThinkingSparkle(ANowMs: Int64): UnicodeString;

implementation

const
  { A collapsed thought or tool block shows this many body rows. }
  CollapsedLines = 3;
  { A live (streaming) block shows this many tail lines, plus a '...' when the
    body is longer. }
  LiveTailLines = 6;
  { Blocks beyond the viewport that keep their rendered layout, so a short
    scroll does not rebuild one. }
  WindowOverscan = 16;
  { Columns reserved at the right of a block title for the rule, the mark, and
    the border. }
  TitleChrome = 10;
  { Blank rows kept below the last block, so it does not sit flush against the
    compose overlay. }
  ContentBottomPad = 2;
  { The thinking sparkle advances every 90 ms (matching TChatItem.Advance). }
  ThinkingIntervalMs = 90;
  { The scrollbar track starts this many rows below the panel's top border, so
    it does not touch the rounded corner. }
  ScrollTrackTopGap = 1;
  Sparkles: array[0..12] of UnicodeString =
    ('∙', '•', '●', '◉', '❂', '✴', '✵', '✶', '✷', '✸', '✹', '✺', '❋');

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function Rep(const ACh: UnicodeString; ACount: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + ACh;
end;

function ThinkingSparkle(ANowMs: Int64): UnicodeString;
begin
  Result := Sparkles[(ANowMs div 90) mod Length(Sparkles)];
end;

{ A loop divider: a thin rule with the loop's stats right-aligned and one
  trailing rule, e.g. ` ─────────── 1.2k in · 310 out ─`. }
function TurnDivider(const AStats: UnicodeString; AWidth: Integer): UnicodeString;
var
  Fill: Integer;
begin
  Fill := AWidth - StringWidth(AStats) - 4;
  if Fill < 1 then
    Fill := 1;
  Result := ' ' + Rep('─', Fill) + ' ' + AStats + ' ─';
end;

{ TChatItem }

constructor TChatItem.Create(AKind: TChatKind; const ALabel, AText: string;
  const ATheme: TTheme);
begin
  inherited Create;
  FKind := AKind;
  FLabel := ALabel;
  FBody := AText;
  FTheme := ATheme;
  FExpanded := (AKind = ckUser) or (AKind = ckAssistant) or
    (AKind = ckError) or (AKind = ckThinking) or (AKind = ckQueued) or
    (AKind = ckAmbient);
  FLiveStarted := False;
  FHeightValid := False;
  FHeightWidth := 0;
  FHeight := 0;
  { The rendered body is built lazily by Materialize, so a large history does
    not hold every block's layout at once. }
end;

destructor TChatItem.Destroy;
begin
  FText.Free;
  FMarkdown.Free;
  inherited Destroy;
end;

function TChatItem.BodyAttr: TAttr;
begin
  case FKind of
    ckUser:
      Result := OnBg(FTheme.Text, FTheme.RaisedBg);
    ckTool:
      Result := OnBg(FTheme.Text, FTheme.SunkenBg);
    ckThought:
      Result := FTheme.Muted;
    ckAmbient, ckQueued:
      Result := OnBg(FTheme.Text, FTheme.RaisedBg);
    ckError:
      Result := FTheme.Error;
  else
    Result := FTheme.Text;
  end;
end;

{ Truncate a title to AMaxW columns, ending with an ellipsis. Cluster-aware. }
function TruncateTitle(const AText: UnicodeString; AMaxW: Integer): UnicodeString;
var
  C: TClusterArray;
  I, W, CW: Integer;
begin
  if AMaxW <= 0 then
    Exit('');
  if StringWidth(AText) <= AMaxW then
    Exit(AText);
  Result := '';
  W := 0;
  C := Clusters(AText);
  for I := 0 to High(C) do
  begin
    CW := ClusterWidth(C[I]);
    if W + CW > AMaxW - 1 then
      Break;
    Result := Result + C[I];
    Inc(W, CW);
  end;
  Result := Result + '…';
end;

function TChatItem.EffectiveExpanded: Boolean;
begin
  Result := FExpanded or FLive;
end;

function TChatItem.DisplayBody: string;
begin
  if FLive then
    Result := string(TailLines(UnicodeString(FBody), LiveTailLines))
  else
    Result := FBody;
end;

procedure TChatItem.Rebuild;
var
  One: TSpan;
begin
  EnsureBody;
  if FMarkdown <> nil then
  begin
    FMarkdown.SetSource(DisplayBody);
    Exit;
  end;
  One := Default(TSpan);
  One.Text := UnicodeString(DisplayBody);
  One.Attr := BodyAttr;
  FText.SetSpans([One]);
end;

{ Create the rendered body (spans or markdown) if it is not already present. }
procedure TChatItem.EnsureBody;
begin
  if (FText <> nil) or (FMarkdown <> nil) then
    Exit;
  if FKind = ckAssistant then
    FMarkdown := TMarkdownView.Create
  else
    FText := TTextBlock.Create([], wmWord);
end;

procedure TChatItem.Materialize;
begin
  if Materialized then
    Exit;
  EnsureBody;
  Rebuild;
end;

procedure TChatItem.Dematerialize;
begin
  { The rendered body is dropped; a later AppendText must rebuild the stream
    from the whole body, so clear the streaming flag too. }
  FLiveStarted := False;
  FreeAndNil(FText);
  FreeAndNil(FMarkdown);
end;

function TChatItem.Materialized: Boolean;
begin
  Result := (FText <> nil) or (FMarkdown <> nil);
end;

procedure TChatItem.InvalidateHeight;
begin
  FHeightValid := False;
end;

procedure TChatItem.SetExpanded(AValue: Boolean);
begin
  if AValue = FExpanded then
    Exit;
  FExpanded := AValue;
  InvalidateHeight;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatItem.SetLive(AValue: Boolean);
begin
  if AValue = FLive then
    Exit;
  FLive := AValue;
  InvalidateHeight;
  Rebuild;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatItem.SetText(const AText: string);
begin
  if AText = FBody then
    Exit;
  FBody := AText;
  FLiveStarted := False;
  InvalidateHeight;
  if FMarkdown <> nil then
    FMarkdown.SetSource(AText)
  else
    Rebuild;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatItem.AppendText(const AText: string);
begin
  if AText = '' then
    Exit;
  FBody := FBody + AText;
  InvalidateHeight;
  { Feed the markdown parser incrementally; it never re-parses a closed block.
    The view must be built in streaming mode from the first chunk, so build it
    (EnsureBody) and append the whole body so far - never Rebuild/SetSource,
    which would finish the parser and split the stream into two blocks. }
  EnsureBody;
  if FMarkdown <> nil then
  begin
    if FLiveStarted then
      FMarkdown.AppendSource(AText)
    else
    begin
      { Start (or restart) the stream from the whole body: reset any finished
        parser - e.g. after the view was released off-screen and rebuilt - and
        feed the body as an open stream, never finishing it. }
      FMarkdown.SetSource('');
      FLiveStarted := True;
      FMarkdown.AppendSource(FBody);
    end;
  end
  else
    Rebuild;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatItem.Finalize;
begin
  { Finish the open markdown tail so the last block is parsed and styled; a
    block built with SetText already finished its parser. }
  if (FMarkdown <> nil) and FLiveStarted then
  begin
    FLiveStarted := False;
    FMarkdown.FinishSource;
    InvalidateHeight;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

function TChatItem.Text: string;
begin
  Result := FBody;
end;

function TChatItem.LayoutBuilds: Integer;
begin
  if FText <> nil then
    Result := FText.LayoutBuilds
  else if FMarkdown <> nil then
    Result := FMarkdown.LayoutBuilds
  else
    Result := 0;
end;

function TChatItem.MeasureCount: Integer;
begin
  Result := FMeasureCount;
end;

function TChatItem.Inset: Integer;
begin
  if (FKind = ckUser) or ((FKind in [ckThought, ckTool]) and EffectiveExpanded) then
    Result := 4
  else if (FKind = ckAssistant) or (FKind = ckError) then
    Result := 1
  else
    Result := 0;
end;

function TChatItem.Boxed: Boolean;
begin
  Result := (FKind = ckUser) or (FKind = ckQueued) or (FKind = ckAmbient) or
    ((FKind in [ckThought, ckTool]) and EffectiveExpanded);
end;

procedure TChatItem.BodyRows(AWidth: Integer; out ATextRows, ALines: Integer);
var
  InnerW: Integer;
  Avail: TSize;
begin
  InnerW := AWidth - Inset;
  if InnerW < 1 then
    InnerW := 1;
  if FMarkdown <> nil then
  begin
    Avail := Default(TSize);
    Avail.W := InnerW;
    ALines := FMarkdown.Measure(Avail).H;
  end
  else
  begin
    FText.WrapWidth := InnerW;
    ALines := FText.Measure(Default(TSize)).H;
  end;
  if (not EffectiveExpanded) and (ALines > CollapsedLines) then
    ATextRows := CollapsedLines
  else
    ATextRows := ALines;
end;

function TChatItem.Measure(const AAvail: TSize): TSize;
var
  TextRows, Lines: Integer;
  WasMaterialized: Boolean;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  if AAvail.W < 1 then
    Exit;
  { Memoized per width; invalidated when the text or the expansion changes. }
  if FHeightValid and (FHeightWidth = AAvail.W) then
  begin
    Result.H := FHeight;
    Exit;
  end;
  Inc(FMeasureCount);
  { Measuring needs the rendered body. Build it if it was released, and release
    it again afterwards unless it was already held, so a layout pass does not
    retain every block's layout. }
  WasMaterialized := Materialized;
  Materialize;
  case FKind of
    ckUser, ckQueued, ckAmbient:
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows + 2;   { top border, body, heavy bottom }
      end;
    ckAssistant, ckError:
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows;
      end;
    ckThinking, ckTurn:
      Result.H := 1;
    ckThought, ckTool:
      if EffectiveExpanded then
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows + 2;   { top border, body, bottom border }
      end
      else
        Result.H := 1;              { collapsed rule line }
  end;
  if Result.H < 1 then
    Result.H := 1;
  FHeight := Result.H;
  FHeightWidth := AAvail.W;
  FHeightValid := True;
  if not WasMaterialized then
    Dematerialize;
end;

procedure TChatItem.ArrangeBody(const ABounds: TRect);
var
  TextRows, Lines, InnerW: Integer;
  BodyR: TRect;
begin
  if Boxed then
  begin
    InnerW := ABounds.W - 4;
    if InnerW < 1 then
      InnerW := 1;
    BodyRows(ABounds.W, TextRows, Lines);
    if TextRows > ABounds.H - 2 then
      TextRows := ABounds.H - 2;
    BodyR := Rc(ABounds.X + 2, ABounds.Y + 1, InnerW, TextRows);
  end
  else
    BodyR := Rc(ABounds.X + Inset, ABounds.Y, ABounds.W - Inset,
      ABounds.H);
  if FMarkdown <> nil then
    FMarkdown.Arrange(BodyR)
  else
    FText.Arrange(BodyR);
end;

procedure TChatItem.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  { A released block arranges its body when it is materialized in Render. }
  if Materialized then
    ArrangeBody(ABounds);
end;

procedure TChatItem.Render(const S: ISurface);
var
  L, R, T, B, TextRows, Lines, X, I, TitleMaxW: Integer;
  InnerW: Integer;
  Border, SurfaceAttr, TitleAttr: TAttr;
  Clip: TRect;
  Title, DispLabel: UnicodeString;
  RuleCh, MarkCh: UnicodeString;
begin
  if (FBounds.W < 1) or (FBounds.H < 1) then
    Exit;
  if not Materialized then
  begin
    Materialize;
    ArrangeBody(FBounds);
  end;

  case FKind of
    ckAssistant:
      begin
        FMarkdown.Render(S);
        Exit;
      end;
    ckError:
      begin
        FText.Render(S);
        Exit;
      end;
    ckAmbient:
      begin
        { A dimmed subagent-result marker; the title carries the child + status. }
        FText.Render(S);
        Exit;
      end;
    ckThinking:
      begin
        PutText(S, FBounds.X + 1, FBounds.Y, Sparkles[FSpark], FTheme.Accent);
        PutText(S, FBounds.X + 3, FBounds.Y, 'Thinking', FTheme.Muted);
        Exit;
      end;
    ckTurn:
      begin
        PutText(S, FBounds.X, FBounds.Y,
          TurnDivider(UnicodeString(FBody), FBounds.W), FTheme.Muted);
        Exit;
      end;
  else
    ;
  end;

  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  BodyRows(FBounds.W, TextRows, Lines);

  { Keep the title inside the block: a long reason is truncated with an
    ellipsis rather than pushing the rule and mark off the edge. }
  TitleMaxW := FBounds.W - TitleChrome;
  if TitleMaxW < 1 then
    TitleMaxW := 1;
  DispLabel := TruncateTitle(UnicodeString(FLabel), TitleMaxW);

  if (not EffectiveExpanded) and (FKind in [ckThought, ckTool]) then
  begin
    { Both collapse to a thin rule; a tool's is full contrast, so the reasons
      read as a story of the agent's decisions. }
    RuleCh := '─';
    MarkCh := '▼';
  end
  else
  begin
    RuleCh := '';
    MarkCh := '▲';
  end;

  { Collapsed rule line: ' ─ Label ───── ▼ ─', one leading space, running to the
    block's right edge (a space remains before the scrollbar column). }
  if RuleCh <> '' then
  begin
    Title := ' ' + RuleCh + ' ' + DispLabel + ' ';
    I := FBounds.W - StringWidth(Title) - 5;
    if I < 1 then
      I := 1;
    if FKind = ckTool then
      PutText(S, L, T, Title + Rep(RuleCh, I) + ' ' + MarkCh + ' ' + RuleCh,
        FTheme.Text)
    else
      PutText(S, L, T, Title + Rep(RuleCh, I) + ' ' + MarkCh + ' ' + RuleCh,
        FTheme.Muted);
    Exit;
  end;

  { Boxed kinds. }
  if FKind = ckUser then
  begin
    SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
    Border := OnBg(WithStyle(FTheme.Accent, [sfDim]), FTheme.RaisedBg);
  end
  else if (FKind = ckQueued) or (FKind = ckAmbient) then
  begin
    { A user box with a violet border (matching inline code), to mark a queued
      prompt or a subagent's ambient result. }
    SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
    Border := OnBg(FTheme.Text, FTheme.RaisedBg);
    Border.Fg := QueuedBorderFg;
    Border.Style := Border.Style + [sfDim];
  end
  else if FKind = ckTool then
  begin
    SurfaceAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
    Border := OnBg(FTheme.Border, FTheme.SunkenBg);
  end
  else
  begin
    SurfaceAttr := FTheme.Base;
    Border := FTheme.Border;
  end;

  S.FillRect(FBounds, SurfaceAttr);

  if FKind = ckUser then
  begin
    PutCh(S, L, T, '╭', Border);
    PutCh(S, R, T, '╮', Border);
    PutCh(S, L, B, '╰', Border);
    PutCh(S, R, B, '┘', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, T, '─', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, B, '═', Border);
    Clip := S.ClipRect;
    for I := T + 1 to B - 1 do
      if (I >= Clip.Y) and (I < Clip.Y + Clip.H) then
      begin
        PutCh(S, L, I, '│', Border);
        PutCh(S, R, I, '│', Border);
      end;
  end
  else if (FKind = ckQueued) or (FKind = ckAmbient) then
  begin
    { The user-box frame with a right-aligned title (Queued / the ambient
      label) and a violet border. }
    PutCh(S, L, T, '╭', Border);
    PutCh(S, R, T, '╮', Border);
    PutCh(S, L, B, '╰', Border);
    PutCh(S, R, B, '┘', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, T, '─', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, B, '═', Border);
    Clip := S.ClipRect;
    for I := T + 1 to B - 1 do
      if (I >= Clip.Y) and (I < Clip.Y + Clip.H) then
      begin
        PutCh(S, L, I, '│', Border);
        PutCh(S, R, I, '│', Border);
      end;
    Title := UnicodeString(FLabel) + ' ─';
    if StringWidth(Title) <= FBounds.W - 2 then
    begin
      TitleAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
      TitleAttr.Fg := QueuedBorderFg;
      PutText(S, R - 1 - StringWidth(Title), T, Title, TitleAttr);
    end;
  end
  else
  begin
    { ┌─ Label ───── ▲ ─┐ }
    InnerW := FBounds.W - 4;
    if InnerW < 1 then
      InnerW := 1;
    Title := '┌─ ' + DispLabel + ' ';
    I := FBounds.W - StringWidth(Title) - 5;
    if I < 1 then
      I := 1;
    PutText(S, L, T, Title + Rep('─', I) + ' ▲ ─┐', Border);
    PutCh(S, L, B, '└', Border);
    PutCh(S, R, B, '┘', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, B, '─', Border);
    Clip := S.ClipRect;
    for I := T + 1 to B - 1 do
      if (I >= Clip.Y) and (I < Clip.Y + Clip.H) then
      begin
        PutCh(S, L, I, '│', Border);
        PutCh(S, R, I, '│', Border);
      end;
  end;

  FText.Render(S);
end;

function TChatItem.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if not (FKind in [ckThought, ckTool]) then
    Exit;
  if FLive then
    Exit;   { a live block is not toggleable; it settles when the stream ends }
  if (E.Kind = ikMouse) and (E.Mouse.Button = mbLeft) and
    (E.Mouse.X >= FBounds.X) and (E.Mouse.Y >= FBounds.Y) and
    (E.Mouse.X < FBounds.X + FBounds.W) and (E.Mouse.Y < FBounds.Y + FBounds.H)
  then
  begin
    FExpanded := not FExpanded;
    InvalidateHeight;
    if Assigned(FOnToggle) then
      FOnToggle(Self);
    Exit(True);
  end;
end;

function TChatItem.Advance(const ANowMs: Int64): Boolean;
var
  NewSpark: Integer;
begin
  if FKind <> ckThinking then
    Exit(False);
  NewSpark := (ANowMs div 90) mod Length(Sparkles);
  Result := NewSpark <> FSpark;
  FSpark := NewSpark;
end;

function TChatItem.Animating: Boolean;
begin
  Result := FKind = ckThinking;
end;

{ TChatStack }

constructor TChatStack.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FGap := 1;
  FGeneration := 0;
  FLayoutValid := False;
end;

destructor TChatStack.Destroy;
var
  I: Integer;
begin
  ClearAnimation;
  for I := 0 to High(FItems) do
    FItems[I].Free;
  inherited Destroy;
end;

function TChatStack.Count: Integer;
begin
  Result := Length(FItems);
end;

function TChatStack.ItemAt(AIndex: Integer): TChatItem;
begin
  Result := FItems[AIndex];
end;

function TChatStack.ItemWidth(AStackWidth: Integer): Integer;
begin
  Result := AStackWidth - 2;
  if Result < 1 then
    Result := 1;
end;

function TChatStack.Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
begin
  SetLength(FItems, Length(FItems) + 1);
  Result := TChatItem.Create(AKind, ALabel, AText, FTheme);
  Result.OnToggle := ItemToggled;
  Result.OnChange := ItemChanged;
  FItems[High(FItems)] := Result;
  if AKind = ckThinking then
  begin
    Inc(FAnimatingBlocks);
    RefreshAnimation;
  end;
  BumpGeneration;
end;

procedure TChatStack.Clear;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  FItems := nil;
  FAnimatingBlocks := 0;
  RefreshAnimation;
  BumpGeneration;
end;

procedure TChatStack.Remove(AItem: TChatItem);
var
  I, J: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I] = AItem then
    begin
      if AItem.Kind = ckThinking then
        Dec(FAnimatingBlocks);
      FItems[I].Free;
      for J := I to High(FItems) - 1 do
        FItems[J] := FItems[J + 1];
      SetLength(FItems, Length(FItems) - 1);
      RefreshAnimation;
      BumpGeneration;
      Exit;
    end;
end;

procedure TChatStack.SetOnToggle(AValue: TNotifyEvent);
var
  I: Integer;
begin
  FOnToggle := AValue;
  for I := 0 to High(FItems) do
    FItems[I].OnToggle := ItemToggled;
end;

procedure TChatStack.SetOnChange(AValue: TNotifyEvent);
var
  I: Integer;
begin
  FOnChange := AValue;
  for I := 0 to High(FItems) do
    FItems[I].OnChange := ItemChanged;
end;

procedure TChatStack.BumpGeneration;
begin
  Inc(FGeneration);
  FLayoutValid := False;
end;

procedure TChatStack.ItemChanged(Sender: TObject);
begin
  { A block's text or expansion changed: its memoized height is stale. }
  BumpGeneration;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatStack.ItemToggled(Sender: TObject);
begin
  BumpGeneration;
  if Assigned(FOnToggle) then
    FOnToggle(Self);
end;

{ Rebuild the block offset/height arrays when the item width or the content
  changed. The height memo is keyed per width, so Measure and Arrange MUST pass
  the same item width or this re-measures every block on every frame (see
  docs/guidelines/tui-rendering.md). }
procedure TChatStack.EnsureLayout(AItemWidth: Integer);
var
  I, Y: Integer;
  Sz: TSize;
begin
  if FLayoutValid and (FLayoutWidth = AItemWidth) and
    (FLayoutGeneration = FGeneration) and (Length(FLayoutY) = Count) then
    Exit;
  Inc(FLayoutRuns);
  SetLength(FLayoutY, Count);
  SetLength(FLayoutH, Count);
  Sz := Default(TSize);
  Sz.W := AItemWidth;
  Y := 0;
  for I := 0 to Count - 1 do
  begin
    FLayoutY[I] := Y;
    FLayoutH[I] := ItemAt(I).Measure(Sz).H;
    Inc(Y, FLayoutH[I] + FGap);
  end;
  if Count > 0 then
    Dec(Y, FGap);
  FLayoutTotal := Y;
  FLayoutWidth := AItemWidth;
  FLayoutGeneration := FGeneration;
  FLayoutValid := True;
end;

function TChatStack.Measure(const AAvail: TSize): TSize;
var
  W: Integer;
begin
  Result := Default(TSize);
  { Reserve the scrollbar column and report the width the stack will be arranged
    at: the scroll container arranges its child at the width the child reported,
    so Arrange's bounds equal this width and the per-width height memo never
    misses. Reporting our own arranged bounds instead would pin the stack to its
    first width and it would never follow a resize. }
  W := AAvail.W - 1;
  if W < 1 then
    W := 1;
  Result.W := W;
  EnsureLayout(ItemWidth(W));
  Result.H := FLayoutTotal + ContentBottomPad + FBottomInset;
end;

procedure TChatStack.Arrange(const ABounds: TRect);
var
  I, ItemW: Integer;
begin
  inherited Arrange(ABounds);
  ItemW := ItemWidth(ABounds.W);
  EnsureLayout(ItemW);
  for I := 0 to Count - 1 do
    { Inset by one column on each side: the panel shows
      border | space | content | space | scrollbar | border. }
    ItemAt(I).Arrange(Rc(ABounds.X + 1, ABounds.Y + FLayoutY[I], ItemW,
      FLayoutH[I]));
end;

function TChatStack.MaterializedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if ItemAt(I).Materialized then
      Inc(Result);
end;

function TChatStack.LayoutRuns: Integer;
begin
  Result := FLayoutRuns;
end;

procedure TChatStack.Render(const S: ISurface);
var
  I, Top, Bottom, First, Last, ItemW: Integer;
  Clip: TRect;
  Item: TChatItem;
begin
  S.PushClip(FBounds);
  Clip := S.ClipRect;
  EnsureLayout(ItemWidth(FBounds.W));
  Top := Clip.Y - FBounds.Y;
  Bottom := Clip.Y + Clip.H - FBounds.Y;
  { The layout is ordered, so the first block past the clip ends the scan and
    only the visible blocks are drawn. }
  First := -1;
  Last := -1;
  for I := 0 to Count - 1 do
  begin
    if FLayoutY[I] >= Bottom then
      Break;
    if FLayoutY[I] + FLayoutH[I] > Top then
    begin
      if First < 0 then
        First := I;
      Last := I;
    end;
  end;
  { Materialize the visible range plus an overscan and release the rest, so a
    long session does not hold every block's rendered layout. The overscan keeps
    a block that just left the viewport from rebuilding on a short scroll. }
  if First >= 0 then
  begin
    if First - WindowOverscan > 0 then
      Dec(First, WindowOverscan)
    else
      First := 0;
    if Last + WindowOverscan < Count - 1 then
      Inc(Last, WindowOverscan)
    else
      Last := Count - 1;
  end;
  ItemW := ItemWidth(FBounds.W);
  for I := 0 to Count - 1 do
  begin
    Item := ItemAt(I);
    if (First < 0) or (I < First) or (I > Last) then
      Item.Dematerialize
    else if not Item.Materialized then
    begin
      { The block was released when Arrange ran, so materialize it now and give
        its body bounds. Already-materialized blocks were arranged by Arrange. }
      Item.Materialize;
      Item.Arrange(Rc(FBounds.X + 1, FBounds.Y + FLayoutY[I], ItemW,
        FLayoutH[I]));
    end;
  end;
  for I := 0 to Count - 1 do
  begin
    if FLayoutY[I] >= Bottom then
      Break;
    if FLayoutY[I] + FLayoutH[I] > Top then
      ItemAt(I).Render(S);
  end;
  S.PopClip;
end;

function TChatStack.HandleEvent(const E: TInputEvent): Boolean;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if ItemAt(I).HandleEvent(E) then
      Exit(True);
  Result := False;
end;

function TChatStack.Advance(const ANowMs: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  { Only the thinking indicator animates; skip the whole list when none does. }
  if FAnimatingBlocks = 0 then
    Exit;
  for I := 0 to Count - 1 do
    if ItemAt(I).Advance(ANowMs) then
      Result := True;
end;

function TChatStack.Animating: Boolean;
begin
  Result := FAnimatingBlocks > 0;
end;

procedure TChatStack.RefreshAnimation;
begin
  { Register the stack's own animation with the process clock while any block
    animates, so the app keeps ticking for it (and no faster). }
  if FAnimatingBlocks > 0 then
    SetAnimation(ThinkingIntervalMs)
  else
    ClearAnimation;
end;

function TChatStack.AnimatingCount: Integer;
begin
  Result := FAnimatingBlocks;
end;

{ TChatStream }

constructor TChatStream.Create(const ATheme: TTheme);
begin
  inherited Create;
  FFollow := True;
  FStack := TChatStack.Create(ATheme);
  FScroll := TScrollContainer.Create(FStack, smAuto, smNever);
  { The scrollbar sits in the messages panel's right border column, so its track
    must not be painted: the border reads as the track and only the thumb
    shows. }
  FScroll.TrackVisible := False;
  { The track starts below the rounded corner; the bottom is set from the
    compose overlay's inset so the thumb never runs under it. }
  FScroll.TrackTop := ScrollTrackTopGap;
  { Intercept block changes and toggles ourselves, so the host only sees the
    notification and the stream owns the scroll behaviour. }
  FStack.SetOnChange(ItemChanged);
  FStack.SetOnToggle(ItemToggled);
end;

destructor TChatStream.Destroy;
begin
  FScroll.Free;
  inherited Destroy;
end;

function TChatStream.Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
begin
  Result := FStack.Add(AKind, ALabel, AText);
  FFollow := True;
end;

procedure TChatStream.Clear;
begin
  FStack.Clear;
  FFollow := True;
  FScroll.ScrollY := 0;
end;

procedure TChatStream.Remove(AItem: TChatItem);
begin
  FStack.Remove(AItem);
end;

function TChatStream.Count: Integer;
begin
  Result := FStack.Count;
end;

function TChatStream.ItemAt(AIndex: Integer): TChatItem;
begin
  Result := FStack.ItemAt(AIndex);
end;

function TChatStream.Last: TChatItem;
begin
  if FStack.Count = 0 then
    Exit(nil);
  Result := FStack.ItemAt(FStack.Count - 1);
end;

procedure TChatStream.FollowBottom;
begin
  FFollow := True;
  FScroll.ScrollY := High(Integer);
end;

procedure TChatStream.SetOnToggle(AValue: TNotifyEvent);
begin
  FOnToggle := AValue;
end;

procedure TChatStream.ItemToggled(Sender: TObject);
begin
  { A toggle changes one block's height, not the conversation. Stop following so
    the re-arrange keeps the scroll where it is: the block's top stays on the
    same row, and its body grows or shrinks around that row. }
  FFollow := False;
  if Assigned(FOnToggle) then
    FOnToggle(Self);
end;

procedure TChatStream.SetOnChange(AValue: TNotifyEvent);
begin
  FOnChange := AValue;
end;

procedure TChatStream.SetBottomInset(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  FBottomInset := AValue;
  FStack.BottomInset := AValue;
  { The covered rows also shorten the scrollbar track, so a small thumb stays
    above the overlay instead of sliding under it. }
  FScroll.TrackBottom := AValue;
end;

procedure TChatStream.ItemChanged(Sender: TObject);
begin
  { Content grew: keep following, but do not yank a reader who scrolled away. }
  if FFollow then
    FScroll.ScrollY := High(Integer);
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TChatStream.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TChatStream.Arrange(const ABounds: TRect);
var
  B: TRect;
begin
  inherited Arrange(ABounds);
  { Bleed one column into the messages panel's right border so the scrollbar
    lands in that border column (the panel has no padding, so the column just
    past the content is the border). }
  B := ABounds;
  Inc(B.W);
  FScroll.Arrange(B);
  if FFollow then
    FScroll.ScrollY := High(Integer);
end;

procedure TChatStream.Render(const S: ISurface);
begin
  FScroll.Render(S);
end;

function TChatStream.HandleEvent(const E: TInputEvent): Boolean;
var
  Before: Integer;
  Scrollish: Boolean;
begin
  Before := FScroll.ScrollY;
  Result := FScroll.HandleEvent(E);
  Scrollish := (E.Kind = ikKey) or
    ((E.Kind = ikMouse) and
    ((E.Mouse.Button = mbWheelUp) or (E.Mouse.Button = mbWheelDown)));
  { A click that reached a block toggled it, which pins the view; only a real
    scroll interaction re-evaluates whether we are following the bottom. }
  if Result and (Scrollish or (FScroll.ScrollY <> Before)) then
    FFollow := FScroll.ScrollY >= FScroll.MaxScrollY;
end;

function TChatStream.Advance(const ANowMs: Int64): Boolean;
begin
  Result := FStack.Advance(ANowMs);
end;

function TChatStream.Animating: Boolean;
begin
  Result := FStack.Animating;
end;

end.
