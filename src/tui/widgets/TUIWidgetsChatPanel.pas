unit TUIWidgetsChatPanel;
{ The chat column: a bordered messages panel holding a TChatStream, a compose
  box that overlays it as it grows, a toolbar strip above the compose, and a
  two-part status line below.

  The compose overlays rather than reflows, so growing the input never moves the
  conversation. The toolbar and the status line are each left/right split: the
  run state and the workspace on the left, the interaction hints and the metrics
  on the right. Both are inset by inline padding so their content does not touch
  the panel edges. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIWidgetsText, TUIWidgetsPanel,
  TUITheme, TUIWidgetsChat,
  TUIGrapheme, TUIClock,
  TUIWidgetsCompose, TUIWidgetsPalette,
  TUIWidgetsActions;

{ The start-of-session mark: drawn centred in an empty transcript. Braille block
  art, so it reads as a logo on a terminal that has no images. One string per
  ROW, so a badly-wide row cannot shift the centring of the others.

  The mark is drawn in TWO tones, decided CELL BY CELL from EmptyLogoWordMask:
  the circle emblem is the frame, not the name, so it stays muted, while the
  letters take the ordinary text colour, a step brighter. A single split column
  cannot do this - the swash sweeps UNDER the circle, so a column cuts through
  the middle of a letter. The mask follows the drawing instead. }
const
  { Which cells of EmptyLogo are the WORD and which are the CIRCLE.
    '1' = letter (painted brighter), '0' = circle (muted), '.' = blank.
    Derived from a mask image of the art with the circle removed, aligned
    dot-for-dot against the logo - so the tone follows the DRAWING rather
    than a column, and the swash that sweeps under the circle keeps its
    own tone cell by cell. }
  EmptyLogoWordMask: array[0..6] of UnicodeString = (
    '......0000000000...........................',
    '...00000.1111100000......11111.....11......',
    '.0000..1111.11000000...111011.....111......',
    '.000...110.111.00011..111111.....111.111...',
    '.00....11111....0011..11111..111111..11....',
    '.00....1111111..111..1111.11111111.1111....',
    '....1111111.1111111111111111110.11111111...');

  EmptyLogo: array[0..6] of UnicodeString = (
    '⠀⠀⠀⠀⠀⠀⣀⣤⣤⣤⠤⢤⣤⣤⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀',
    '⠀⠀⠀⣠⣶⡿⠛⠉⠀⣠⣴⡶⣤⡀⢿⣿⣷⣤⡀⠀⠀⠀⠀⠀⠀⢀⣴⠶⣶⡄⠀⠀⠀⠀⠀⣴⡄⠀⠀⠀⠀⠀⠀',
    '⠀⢠⣾⣿⠏⠀⠀⢀⣾⣿⠋⠀⢸⡇⠸⣿⣿⣿⣿⡄⠀⠀⠀⢀⣴⡟⠁⣼⡿⠀⠀⠀⠀⠀⣼⡿⠁⠀⠀⠀⠀⠀⠀',
    '⠀⣾⣿⠋⠀⠀⠀⣸⣿⠃⠀⢀⡾⠁⠀⢻⣿⡏⢰⣶⠀⠀⢀⣾⠏⢀⣾⠏⠀⠀⠀⠀⠀⣼⡿⠁⠀⠠⣶⡆⠀⠀⠀',
    '⠀⢿⡏⠀⠀⠀⠀⣿⡏⢀⡴⠋⠀⠀⠀⠀⠙⢃⣤⡄⠀⠀⣾⣟⣴⠟⠁⠀⠀⣀⣠⡤⣼⡿⠁⠀⠀⣤⡤⠀⠀⠀⠀',
    '⠀⠈⠃⠀⠀⠀⠀⣿⡗⢋⣴⡿⢻⡆⠀⠀⣠⣿⡏⠀⠀⣠⣿⡟⠁⠀⢀⣤⡾⢋⣠⡾⣿⡇⠀⢀⣼⣿⠁⠀⠀⠀⠀',
    '⠀⠀⠀⠀⢀⠤⠊⠙⠷⠾⠋⠀⠈⠳⠶⠛⠉⠙⠻⠒⠛⠉⠘⠛⠷⠚⠋⠙⠛⠋⠁⠀⠙⠓⠚⠋⠈⠛⠦⠤⠀⠀⠀');

  { The resting line under the mark. There used to be a two-line EmptyHints
    array here; the recent-session list replaced it, and each row now names the
    key that opens it, so a separate "press Enter to start" hint would only
    repeat the composer's own affordance. }
  EmptyHintStart = 'Start typing your prompt below';
  EmptyHintOr = 'Or start typing your prompt below';
  EmptyHintRecent = 'Continue recent session';

{ What the agent is doing while it REASONS.

  "Thinking" alone is dull for something that can run for a minute, so the label
  rotates. It rotates only while psThinking - a tool run, an approval or an error
  says exactly what it is and must not be decorated.

  Held here rather than in the app so the panel owns its own vocabulary, and so a
  test can drive the rotation without a turn. }
const
  ReasoningWords: array[0..4] of string =
    ('Thinking', 'Reasoning', 'Working it out', 'Considering', 'Pondering');
  { How often the label changes. Slower than the sparkle (90 ms): the spark is
    motion, the word is a caption, and a caption that flickers is unreadable. }
  ReasoningWordIntervalMs = 2600;

type
  { What the run is doing, shown at the left of the toolbar. psThinking and
    psTool animate the sparkle; the others are static icons. }
  TPanelState = (psReady, psThinking, psTool, psApproval, psError, psInterrupt);

  { A recent-session row was activated. AIndex is 0-based and matches the
    ctrl+0..ctrl+9 chord shown beside it on the empty screen. }
  TRecentOpenEvent = procedure(AIndex: Integer) of object;

  TChatPanel = class(TWidget)
  private
    FTheme: TTheme;
    FMessages: TPanel;
    FStream: TChatStream;
    FCta: TPanel;
    FCtaRow: TContainer;
    FStateBlock: TTextBlock;
    FHintsBlock: TTextBlock;
    FCompose: TComposeBox;
    { The alternate bottom panel for a read-only mode (spying): a CTA strip that
      replaces the compose. Nil until SetActionsMode(True). }
    FActions: TActionsBar;
    FActionsMode: Boolean;
    FPalette: TCommandPalette;
    FPaletteActive: Boolean;
    { Recent (unattached) sessions offered on the empty screen, most recent
      first. Titles only - the host owns the ids and does the switching. Index
      0..9 map to ctrl+0..ctrl+9. }
    FRecentTitles: array of string;
    FOnOpenRecent: TRecentOpenEvent;
    FStatus: TTextBlock;
    FStats: TTextBlock;
    FStatusText: string;
    FStatsText: string;
    FHeaderLeft: string;
    FHeaderRight: string;
    FPageCount: Integer;
    FPageIndex: Integer;
    FStateKind: TPanelState;
    FReasoningFromMs: Int64;   { when this reasoning run started; -1 = not reasoning }
    FStateLabel: string;
    { The hint text as SET, before any fitting: FitToolbar clamps it to the row,
      so the raw string must be kept to re-fit when the pane widens again. }
    FHintsText: string;
    { Display cells the state label may occupy. 0 = unbounded (not yet arranged).
      RenderState applies it, so there is ONE path that paints the label and it
      cannot disagree with the budget FitToolbar computed. }
    FStateLabelMax: Integer;
    FStateSpans: array[0..1] of TSpan;
    FSpark: UnicodeString;
    procedure RenderState;
    procedure RefreshAnimation;
    procedure FitStatus;
    { Clamp the state label so the interaction hints keep their place on the
      shared toolbar row. Called from Arrange, because the row's width is only
      known then. }
    procedure FitToolbar;
    { Paint FHintsText as two-tone spans: the KEYBINDING is chrome and stays dim,
      the ACTION it performs is the part worth reading and is brighter. Called
      from both SetHints and FitToolbar so there is one painter. }
    procedure PaintHints;
  public
    constructor Create(const ATheme: TTheme; const AInfo, AHints: string);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Stream: TChatStream read FStream;
    property Compose: TComposeBox read FCompose;
    { The typeahead command palette shown above the composer. }
    property Palette: TCommandPalette read FPalette;
    { Show or hide the palette above the composer. }
    procedure SetPaletteActive(AValue: Boolean);
    function PaletteActive: Boolean;
    { The left part of the status row (the workspace). }
    procedure SetStatus(const AText: string);
    { The right-aligned metrics line, sharing the status row. }
    procedure SetStats(const AText: string);
    { The messages panel's top border: the session id at the left, the session
      stats at the right. }
    procedure SetHeader(const ALeft, ARight: string);
    procedure RenderEmptyMark(const S: ISurface);
    property HeaderLeft: string read FHeaderLeft;
    property HeaderRight: string read FHeaderRight;
    { A multi-page (checkpointed) session: the messages panel's left border is
      split into one segment per page, the current page drawn heavy. A single
      page (the default) leaves the border uniform. }
    procedure SetPage(ACount, AIndex: Integer);
    { Update only the active page (the heavy segment) as the view scrolls. }
    procedure SetPageIndex(AIndex: Integer);
    { The messages panel's bounds, so the host can map a click on the left-border
      paginator to a page. }
    function MessagesBounds: TRect;
    { The compose's bounds, so a host can put a panel IN the composer's place
      (the subagent list) instead of floating it over the transcript. }
    function ComposeBounds: TRect;
    { The left of the toolbar: what the run is doing. }
    procedure SetState(AKind: TPanelState; const ALabel: string);
    { The right of the toolbar: the interaction hints. }
    procedure SetHints(const AText: string);
    { Disable input while a turn runs, keeping whatever was typed. }
    procedure SetComposeActive(AValue: Boolean);
    { The compose's primary-action CTA (send / cancel / none). }
    procedure SetCta(AKind: TCtaKind);
    { The recent-session list drawn under the mark. Empty means the empty screen
      shows the prompt hint alone. }
    procedure SetRecentSessions(const ATitles: array of string);
    property OnOpenRecent: TRecentOpenEvent read FOnOpenRecent
      write FOnOpenRecent;
    { Swap the compose for a CTA actions bar (a read-only view like the spy), or
      back. The bar's hints and action handler are set on the bar itself. }
    procedure SetActionsMode(AValue: Boolean);
    function ActionsMode: Boolean;
    property Actions: TActionsBar read FActions;
  end;

implementation

const
  { The compose never takes more than this share of the panel height. }
  MaxComposePercent = 60;
  { Inline padding for the toolbar and the status row, so their content does not
    touch the panel edges. }
  ChromePad = 2;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function StateIcon(AKind: TPanelState): UnicodeString;
begin
  case AKind of
    psReady:
      Result := '✓';
    psApproval:
      Result := '?';
    psError:
      Result := '✗';
    psInterrupt:
      Result := '!';
  else
    Result := '';   // the animated states show the sparkle instead
  end;
end;

function StateAttr(const ATheme: TTheme; AKind: TPanelState): TAttr;
begin
  case AKind of
    psReady:
      Result := ATheme.Success;
    psApproval, psInterrupt:
      Result := ATheme.Warn;
    psError:
      Result := ATheme.Error;
  else
    Result := ATheme.Accent;
  end;
end;

function StateAnimated(AKind: TPanelState): Boolean;
begin
  Result := AKind in [psThinking, psTool];
end;

{ The state sparkle advances every 90 ms (matching ThinkingSparkle). }
const
  StateSparkleIntervalMs = 90;

{ The first whole clusters of AText that fit in AMax display columns. }
function FitWidth(const AText: UnicodeString; AMax: Integer): UnicodeString;
var
  Cs: TClusterArray;
  I, W, CW: Integer;
begin
  Result := '';
  if AMax <= 0 then
    Exit;
  W := 0;
  Cs := Clusters(AText);
  for I := 0 to High(Cs) do
  begin
    CW := ClusterWidth(Cs[I]);
    if W + CW > AMax then
      Break;
    Result := Result + Cs[I];
    Inc(W, CW);
  end;
end;

constructor TChatPanel.Create(const ATheme: TTheme; const AInfo, AHints: string);
var
  Style: TBoxStyle;
begin
  inherited Create;
  FTheme := ATheme;

  FStream := TChatStream.Create(ATheme);

  { The messages panel: rounded, bordered, no padding, so the stream can bleed
    its scrollbar into the right border column. }
  Style := DefaultBoxStyle;
  Style.Title := '';
  Style.Rounded := True;
  Style.Padding := 0;
  FMessages := TPanel.Create(FStream, ATheme, Style);

  { The toolbar: the run state on the left, the hints on the right, split by a
    two-column grid (auto | fill). The right cell is full width, so the hints
    block right-aligns within it. }
  FStateBlock := TTextBlock.Create([], wmNone);
  FHintsBlock := TTextBlock.Create([], wmNone);
  FHintsBlock.Align := taRight;
  FCtaRow := TContainer.Create([Auto, Fill(1)], [Auto]);
  FCtaRow.Add(FStateBlock, 0, 0);
  FCtaRow.Add(FHintsBlock, 1, 0);
  Style := DefaultBoxStyle;
  Style.Title := '';
  Style.Border := False;
  Style.Padding := 0;
  FCta := TPanel.Create(FCtaRow, ATheme, Style);

  FCompose := TComposeBox.Create(ATheme, AInfo);

  FActions := TActionsBar.Create(ATheme);
  FActions.Visible := False;
  FActionsMode := False;

  FPalette := TCommandPalette.Create(ATheme);
  FPaletteActive := False;

  FStatus := TTextBlock.Create([], wmNone);
  FStats := TTextBlock.Create([], wmNone);
  FStats.Align := taRight;

  FStateKind := psReady;
  FStateLabel := 'ready';
  FSpark := ThinkingSparkle(0);
  RenderState;
  SetHints(AHints);
end;

destructor TChatPanel.Destroy;
begin
  ClearAnimation;
  FMessages.Free;
  FCta.Free;
  FActions.Free;
  FCompose.Free;
  FPalette.Free;
  FStatus.Free;
  FStats.Free;
  inherited Destroy;
end;

procedure TChatPanel.RenderState;
var
  Caption: UnicodeString;
begin
  if StateAnimated(FStateKind) then
    FStateSpans[0].Text := FSpark
  else
    FStateSpans[0].Text := StateIcon(FStateKind);
  FStateSpans[0].Attr := StateAttr(FTheme, FStateKind);
  { FitToolbar may have budgeted less than the label needs; applying it HERE
    rather than in the fitter keeps one path that paints the label, so the two
    cannot disagree about what is on screen. }
  Caption := UnicodeString(FStateLabel);
  if FStateLabelMax > 0 then
    Caption := FitWidth(Caption, FStateLabelMax);
  FStateSpans[1].Text := UnicodeString(' ') + Caption;
  FStateSpans[1].Attr := FTheme.Muted;
  FStateBlock.SetSpans(FStateSpans);
end;

function TChatPanel.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TChatPanel.Arrange(const ABounds: TRect);
var
  MessagesH, ComposeH, MaxH, ComposeY, ChromeW, ChromeX, PalH: Integer;
  PalSize, Avail2: TSize;
begin
  inherited Arrange(ABounds);
  MessagesH := ABounds.H - 1;   { the status line }
  if MessagesH < 1 then
    MessagesH := 1;

  { The compose is an overlay: it grows upward over the messages panel, which
    keeps its full size, so the message content and its scroll do not reflow.
    In actions mode a fixed-height CTA bar takes the compose's slot. }
  if FActionsMode then
  begin
    Avail2 := Default(TSize);
    Avail2.W := ABounds.W;
    Avail2.H := ABounds.H;
    ComposeH := FActions.Measure(Avail2).H;
  end
  else
  begin
    ComposeH := FCompose.NeededHeight(ABounds.W);
    MaxH := (ABounds.H * MaxComposePercent) div 100;
    if ComposeH > MaxH then
      ComposeH := MaxH;
    if ComposeH < 4 then
      ComposeH := 4;
  end;
  ComposeY := ABounds.Y + MessagesH - ComposeH;
  if ComposeY < ABounds.Y then
    ComposeY := ABounds.Y;

  { Tell the stream how many of its rows the CTA and compose cover, so the last
    block still keeps its two blank pad rows visible above them. The messages
    panel has a one-row border, so its inner area ends one row above the
    panel's bottom edge. }
  FStream.BottomInset := ABounds.Y + MessagesH - ComposeY;

  FMessages.Arrange(Rc(ABounds.X, ABounds.Y, ABounds.W, MessagesH));
  { The palette sits above the composer, overlaying the messages too. It is not
    full width: it hugs its content (the palette measures itself). }
  { The palette is a full-width tray spanning the messages panel's inner width
    (inside its border), sliding out from the composer. }
  if FPaletteActive then
  begin
    PalSize := Default(TSize);
    PalSize.W := ABounds.W - 2;   { the messages panel border }
    PalSize.H := ABounds.H;
    PalH := FPalette.Measure(PalSize).H;
    FPalette.Visible := True;
    FPalette.Arrange(Rc(ABounds.X + 1, ComposeY - PalH, ABounds.W - 2, PalH));
    FStream.BottomInset := ABounds.Y + MessagesH - (ComposeY - PalH);
  end
  else
    FPalette.Visible := False;
  FCompose.Arrange(Rc(ABounds.X, ComposeY, ABounds.W, ComposeH));
  FActions.Arrange(Rc(ABounds.X, ComposeY, ABounds.W, ComposeH));
  { The toolbar and the status row share the same inset, so their content lines
    up and neither touches the panel edge. }
  ChromeX := ABounds.X + ChromePad;
  ChromeW := ABounds.W - 2 * ChromePad;
  if ChromeW < 1 then
    ChromeW := 1;
  FCta.Arrange(Rc(ChromeX, ComposeY - 1, ChromeW, 1));
  FStatus.Arrange(Rc(ChromeX, ABounds.Y + ABounds.H - 1, ChromeW, 1));
  FStats.Arrange(Rc(ChromeX, ABounds.Y + ABounds.H - 1, ChromeW, 1));
  { The row's width is only known now, so the label/hint split is decided here
    rather than in SetState or SetHints. It must run BEFORE the toolbar is
    arranged: the container resolves its Auto/Fill tracks from each child's
    MEASURED width, so clamping the label afterwards changes the text but leaves
    the hints column still squeezed to whatever the wide label left. }
  FitToolbar;
  FCta.Arrange(Rc(ChromeX, ComposeY - 1, ChromeW, 1));
  FitStatus;
end;

{ The empty-transcript mark: the logo centred horizontally, then the hints below
  it. Widths are measured in DISPLAY CELLS, because a braille blank is one cell
  and centring by string length drifts on any line holding a wide glyph. }
procedure TChatPanel.RenderEmptyMark(const S: ISurface);
var
  B: TRect;
  Top, I, W, X: Integer;
  N, Avail, TotalH, TableW: Integer;
  Line, Mask, Run: UnicodeString;
  C, InRun: Integer;
  RunWord: Boolean;

  { True when this cell is part of the WORD rather than the circle. A missing or
    short mask row falls back to muted, so a mismatched mask can never paint art
    brighter than intended. }
  function IsWord(const AMask: UnicodeString; AIndex: Integer): Boolean;
  begin
    Result := (AIndex >= 1) and (AIndex <= Length(AMask)) and
      (AMask[AIndex] = '1');
  end;

  { One centred line, in the given role. Skipped when it cannot fit, so a narrow
    pane loses a line rather than drawing a clipped one. }
  procedure Centre(const AText: UnicodeString; const AAttr: TAttr);
  var
    W2: Integer;
  begin
    W2 := StringWidth(AText);
    if (W2 = 0) or (W2 > B.W - 2) then
      Exit;
    PutText(S, B.X + 1 + ((B.W - 2) - W2) div 2, Top, AText, AAttr);
    Inc(Top);
  end;

  { A recent-session row: the key at the left of the block, the title beside it.
    The pair is centred TOGETHER as one string so the keys form a column only if
    the titles happen to match - centring each half separately would make the
    keys jitter line to line. }
  { The widest recent title, so every row has the same left column and the keys
    form a true right edge. Computed once per render, not per row - a per-row
    width would make each row's key sit at its own vertical. }
  function RecentTableWidth: Integer;
  var
    J, W3: Integer;
  begin
    Result := 0;
    for J := 0 to N - 1 do
    begin
      W3 := StringWidth(UnicodeString(FRecentTitles[J]));
      if W3 > Result then
        Result := W3;
    end;
  end;

  { A recent-session row, as two columns with no rules: the title LEFT, the
    chord RIGHT and dimmed. Clamped to the pane, with the chord reserved first -
    it is the fixed part, and losing the key would leave a row that looks
    selectable but says nothing about how. }
  procedure RecentRow(AIndex: Integer; ATableW: Integer);
  var
    Key, Title, Pad: UnicodeString;
    W2, X2, KeyW, TitleW: Integer;
  begin
    Key := 'ctrl+' + UnicodeString(IntToStr(AIndex));
    KeyW := StringWidth(Key);
    Title := UnicodeString(FRecentTitles[AIndex]);
    { Left column gets the table width, less the key column and a gutter. }
    if ATableW > B.W - 8 - KeyW then
      ATableW := B.W - 8 - KeyW;
    TitleW := ATableW;
    if TitleW < 8 then
      Exit;
    if StringWidth(Title) > TitleW then
      Title := FitWidth(Title, TitleW);
    W2 := ATableW + 2 + KeyW;
    X2 := B.X + 1 + ((B.W - 2) - W2) div 2;
    if X2 < B.X + 1 then
      X2 := B.X + 1;
    PutText(S, X2, Top, Title, FTheme.Text);
    { Pad to the right edge so the chord is right-aligned against the column,
      not merely following the title at whatever length it happens to be. }
    Pad := '';
    while StringWidth(Pad) < (ATableW - StringWidth(Title)) + 2 do
      Pad := Pad + ' ';
    PutText(S, X2 + StringWidth(Title), Top, Pad, FTheme.Muted);
    PutText(S, X2 + StringWidth(Title) + StringWidth(Pad), Top, Key,
      FTheme.Muted);
    Inc(Top);
  end;

begin
  B := FMessages.Bounds;
  { HOW MANY RECENT ROWS FIT. The block is the mark, a blank, the heading, one
    row per session, a blank, and the closing hint - and the hint must ALWAYS be
    drawn, because it is the instruction that tells the operator what to do when
    the list is not what they want. So the list gives way, not the hint: clamp N
    to the space left after everything else. }
  { USABLE HEIGHT, not pane height. The compose is an OVERLAY: it covers the
    bottom rows of the messages panel, and FStream.BottomInset says how many.
    Ignoring it drew the closing hint on the rows the composer then painted
    over - the instruction was there, and invisible. }
  Avail := B.H - 2 - FStream.BottomInset;
  if Avail < Length(EmptyLogo) then
    Avail := Length(EmptyLogo);
  N := Length(FRecentTitles);
  if N > 0 then
  begin
    { heading + blank + hint = 3 rows that are not session rows. }
    if N > Avail - (Length(EmptyLogo) + 1) - 3 then
      N := Avail - (Length(EmptyLogo) + 1) - 3;
    if N < 0 then
      N := 0;
  end;
  TotalH := Length(EmptyLogo) + 1;
  if N > 0 then
    Inc(TotalH, N + 3)
  else
    Inc(TotalH, 1);
  Top := B.Y + 1 + (Avail - TotalH) div 2;
  if Top < B.Y + 1 then
    Top := B.Y + 1;
  for I := 0 to High(EmptyLogo) do
  begin
    Line := EmptyLogo[I];
    W := StringWidth(Line);
    if W > B.W - 2 then
      Continue;   { too wide for this pane: skip the row rather than clip it }
    X := B.X + 1 + ((B.W - 2) - W) div 2;
    if I <= High(EmptyLogoWordMask) then
      Mask := EmptyLogoWordMask[I]
    else
      Mask := '';
    { TWO-TONE, CELL BY CELL. The circle emblem is the frame, not the name, so it
      stays MUTED; the letters take the ordinary text colour, a step brighter.
      Driving this from a MASK rather than a split column matters because the
      swash sweeps UNDER the circle: a column would cut through the middle of a
      letter, while the mask follows the drawing itself.

      Consecutive cells of the same tone are emitted as ONE PutText, so a run of
      letters is a single write rather than one per cell. }
    C := 1;
    while C <= Length(Line) do
    begin
      RunWord := IsWord(Mask, C);
      Run := '';
      InRun := C;
      while (C <= Length(Line)) and (IsWord(Mask, C) = RunWord) do
      begin
        Run := Run + Line[C];
        Inc(C);
      end;
      if Run <> '' then
      begin
        if RunWord then
          PutText(S, X, Top + I, Run, FTheme.Text)
        else
          PutText(S, X, Top + I, Run, FTheme.Muted);
        Inc(X, StringWidth(Run));
      end;
      if C = InRun then
        Break;   { defensive: never spin if the run consumed nothing }
    end;
  end;
  Inc(Top, Length(EmptyLogo) + 1);

  { The recent sessions, if the host supplied any. The heading says what the
    keys DO, because a bare list of titles under a logo would not explain itself. }
  if N > 0 then
  begin
    Centre(UnicodeString(EmptyHintRecent), FTheme.Muted);
    TableW := RecentTableWidth;
    for I := 0 to N - 1 do
      RecentRow(I, TableW);
    Inc(Top);
    Centre(UnicodeString(EmptyHintOr), FTheme.Muted);
  end
  else
    Centre(UnicodeString(EmptyHintStart), FTheme.Muted);
end;

procedure TChatPanel.Render(const S: ISurface);
var
  B: TRect;
  Top, Bot, H, I, Y0, Y1: Integer;
  Heavy: UnicodeString;
begin
  FMessages.Render(S);
  { A FRESH session shows the mark and the first-run hints, centred in the empty
    transcript. Drawn here rather than seeded into the stream as rows: it is
    decoration, so it must not become part of the conversation or scroll with it,
    and it disappears the moment the first block arrives. }
  if (FStream.Count = 0) and (FMessages.Bounds.W >= 24) and
    (FMessages.Bounds.H >= Length(EmptyLogo) + 3) then
    RenderEmptyMark(S);
  { The left border doubles as a page gauge: one segment per page, the current
    page heavy. Only drawn for a multi-page session. }
  if (FPageCount > 1) and (FMessages.Bounds.W >= 2) and
    (FMessages.Bounds.H >= 2) then
  begin
    B := FMessages.Bounds;
    Top := B.Y + 1;
    Bot := B.Y + B.H - 2;
    H := Bot - Top + 1;
    if H >= FPageCount then
    begin
      Heavy := UnicodeString(WideChar($2503));   { ┃ }
      for I := 0 to FPageCount - 1 do
      begin
        Y0 := Top + (H * I) div FPageCount;
        Y1 := Top + (H * (I + 1)) div FPageCount - 1;
        if I = FPageIndex then
          while Y0 <= Y1 do
          begin
            PutCh(S, B.X, Y0, Heavy, FTheme.Border);
            Inc(Y0);
          end;
      end;
    end;
  end;
  FCta.Render(S);
  { Only the active bottom panel is drawn: the actions bar would otherwise paint
    an empty frame over the compose box (the panel renders its children
    directly, without the Visible check a TContainer would apply). }
  if FActionsMode then
    FActions.Render(S)
  else
    FCompose.Render(S);
  if FPaletteActive then
    FPalette.Render(S);
  FStatus.Render(S);
  FStats.Render(S);
end;

procedure TChatPanel.SetPage(ACount, AIndex: Integer);
begin
  if ACount < 1 then
    ACount := 1;
  FPageCount := ACount;
  FPageIndex := AIndex;
  if FPageIndex < 0 then
    FPageIndex := 0;
  if FPageIndex > ACount - 1 then
    FPageIndex := ACount - 1;
end;

function TChatPanel.MessagesBounds: TRect;
begin
  Result := FMessages.Bounds;
end;

function TChatPanel.ComposeBounds: TRect;
begin
  Result := FCompose.Bounds;
end;

procedure TChatPanel.SetPageIndex(AIndex: Integer);
begin
  FPageIndex := AIndex;
  if FPageIndex < 0 then
    FPageIndex := 0;
  if FPageIndex > FPageCount - 1 then
    FPageIndex := FPageCount - 1;
end;

function TChatPanel.HandleEvent(const E: TInputEvent): Boolean;
var
  Idx: Integer;
begin
  { When the palette is up, it takes the keys first (Up/Down/Enter/Escape). }
  if FPaletteActive and FPalette.HandleEvent(E) then
    Exit(True);
  { ctrl+0..ctrl+9 open a recent session - but ONLY while the transcript is
    empty. Once a conversation exists those keys are not offered on screen, so
    swallowing them here would make the panel act on something it never showed. }
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    (Length(E.Key.Ch) = 1) and (E.Key.Ch[1] >= '0') and (E.Key.Ch[1] <= '9') then
  begin
    Idx := Ord(E.Key.Ch[1]) - Ord('0');
    if (FStream.Count = 0) and (Idx < Length(FRecentTitles)) and
      Assigned(FOnOpenRecent) then
    begin
      FOnOpenRecent(Idx);
      Exit(True);
    end;
  end;
  if FActionsMode then
  begin
    if FActions.HandleEvent(E) then
      Exit(True);
  end
  else if FCompose.HandleEvent(E) then
    Exit(True);
  if FMessages.HandleEvent(E) then
    Exit(True);
  if FStatus.HandleEvent(E) then
    Exit(True);
  Result := False;
end;

function TChatPanel.Advance(const ANowMs: Int64): Boolean;
var
  NewSpark: UnicodeString;
  Idx: Integer;
  Delta: Int64;
begin
  Result := FCompose.Advance(ANowMs);
  if FMessages.Advance(ANowMs) then
    Result := True;
  if StateAnimated(FStateKind) then
  begin
    NewSpark := ThinkingSparkle(ANowMs);
    if NewSpark <> FSpark then
    begin
      FSpark := NewSpark;
      RenderState;
      Result := True;
    end;
  end;
  { While the agent REASONS, the caption rotates. Only psThinking: a tool run,
    an approval or an error states a fact and must not be decorated. The word is
    derived from the clock, not from a counter ticked per frame, so a missed frame
    cannot desynchronise it - and SetState resets the origin, so every turn starts
    on "Thinking". }
  if (FStateKind = psThinking) and (FReasoningFromMs >= 0) then
  begin
    { CLAMP AT ZERO. SetState stamps the origin from the real clock, so a caller
      that advances with a smaller value - a test driving Advance(0), or a
      surface with its own epoch - makes the delta negative, and a negative `div`
      then `mod` yields a NEGATIVE index. That was an ERangeError, not a wrong
      word: the array read went out of bounds. }
    Delta := ANowMs - FReasoningFromMs;
    if Delta < 0 then
      Delta := 0;
    Idx := (Delta div ReasoningWordIntervalMs) mod Length(ReasoningWords);
    if ReasoningWords[Idx] <> FStateLabel then
    begin
      FStateLabel := ReasoningWords[Idx];
      RenderState;
      Result := True;
    end;
  end;
end;

function TChatPanel.Animating: Boolean;
begin
  Result := FCompose.Animating or FMessages.Animating or
    StateAnimated(FStateKind);
end;

procedure TChatPanel.SetStatus(const AText: string);
begin
  FStatusText := AText;
  FStatus.SetText(AText, FTheme.Muted);
  FitStatus;
end;

procedure TChatPanel.SetStats(const AText: string);
begin
  FStatsText := AText;
  FStats.SetText(AText, FTheme.Muted);
  FitStatus;
end;

procedure TChatPanel.SetHeader(const ALeft, ARight: string);
var
  Style: TBoxStyle;
begin
  FHeaderLeft := ALeft;
  FHeaderRight := ARight;
  Style := FMessages.Style;
  Style.Title := ALeft;
  Style.TitleRight := ARight;
  FMessages.Style := Style;
end;

procedure TChatPanel.SetState(AKind: TPanelState; const ALabel: string);
begin
  FStateKind := AKind;
  FStateLabel := ALabel;
  { Every entry into a state starts its own rotation, so "Thinking" is the first
    word every time rather than wherever the last turn left off. -1 means "not a
    reasoning state, do not rotate". }
  if AKind = psThinking then
    FReasoningFromMs := MonotonicMs
  else
    FReasoningFromMs := -1;
  RenderState;
  RefreshAnimation;
end;

procedure TChatPanel.RefreshAnimation;
begin
  { The state sparkle animates while a turn is thinking or a tool runs; register
    it at the sparkle's rate so the app ticks for it (and no faster). }
  if StateAnimated(FStateKind) then
    SetAnimation(StateSparkleIntervalMs)
  else
    ClearAnimation;
end;

procedure TChatPanel.SetHints(const AText: string);
begin
  { Keep the RAW text: the fitter clamps it to whatever room is left after the
    state label, and the caller re-supplies the full hint whenever the roster or
    the nudge changes. }
  FHintsText := AText;
  PaintHints;
end;

{ Paint the hints two-tone.

  A keybinding is CHROME - the operator learns it once - so it stays dim and
  lowercase, matching how it is written everywhere else in the interface. The
  action it performs is the part that answers "what can I do here", so it takes
  the ordinary text colour.

  Segments are "key action", separated by " · ". A segment with no space (a lone
  "/checkpoint to continue" nudge) is drawn as all-action: there is no binding to
  dim, and guessing one would mis-colour half a sentence. }
procedure TChatPanel.PaintHints;
begin
  { The walk itself lives in TUIWidgetsText.HintSpans, because the subagent list
    shows key hints too. One copy, so the two surfaces cannot drift into different
    house styles - which is exactly how the toolbar and the empty mark ended up
    spelling the same key two ways. }
  if FHintsText = '' then
  begin
    FHintsBlock.SetText('', FTheme.Muted);
    Exit;
  end;
  FHintsBlock.SetSpans(HintSpans(UnicodeString(FHintsText), FTheme.Muted,
    FTheme.Text));
end;

{ Keep the left status short of the right-aligned stats, so a long workspace
  path does not run into the metrics on a narrow terminal. }
procedure TChatPanel.FitStatus;
var
  RowW, StatsW: Integer;
begin
  if FBounds.W <= 0 then
    Exit;
  RowW := FBounds.W - 2 * ChromePad;
  if RowW < 1 then
    RowW := 1;
  StatsW := StringWidth(UnicodeString(FStatsText));
  if StatsW >= RowW - 1 then
    FStatus.SetText('', FTheme.Muted)
  else
    FStatus.SetText(string(FitWidth(UnicodeString(FStatusText),
      RowW - StatsW - 2)), FTheme.Muted);
end;

{ The toolbar holds the state label (left, Auto) and the interaction hints
  (right, Fill). An Auto track measures its content and takes that width even when
  the row cannot hold it, so a long label silently squeezes the hints - and a text
  block CLIPS rather than overflows, so the operator sees a hint cut mid-word
  rather than an obvious break.

  That collision got much easier to hit once the label started naming its subject
  ("Editing src/tui/widgets/TUIWidgetsChatPanel.pas"). The hints are key reminders
  the operator needs WHILE a long operation runs, which is exactly when the label
  is longest, so the label yields.

  The hint is budgeted FIRST - it is the fixed, known-length part - and the label
  takes what remains. At the extreme the label is dropped entirely rather than
  clipped to a meaningless fragment. }
procedure TChatPanel.FitToolbar;
var
  RowW, IconW, HintsW, LabelAvail: Integer;
begin
  if FBounds.W <= 0 then
    Exit;
  RowW := FBounds.W - 2 * ChromePad;
  if RowW < 1 then
    RowW := 1;
  { The sparkle or the state icon occupies one cell, plus one for the space
    before the label. }
  IconW := 2;
  HintsW := StringWidth(UnicodeString(FHintsText));
  if HintsW > 0 then
    Inc(HintsW);   { the column gap between the label and the hints }
  if HintsW > RowW then
  begin
    { The hints alone do not fit. Keep the LABEL and let the hints clip: a long
      state is the rarer case, and a label cut to two characters says nothing.
      Painted through PaintHints, not SetText, so the two-tone survives. }
    PaintHints;
    Exit;
  end;
  LabelAvail := RowW - IconW - HintsW;
  { Record the budget and repaint through the ONE path that paints the label, so
    the fitter and the renderer cannot disagree about what is on screen. }
  if LabelAvail <= 0 then
    FStateLabelMax := 0    { no room: the hints win, the label is dropped }
  else
    FStateLabelMax := LabelAvail;
  RenderState;
end;

procedure TChatPanel.SetComposeActive(AValue: Boolean);
begin
  FCompose.Edit.Active := AValue;
end;

procedure TChatPanel.SetPaletteActive(AValue: Boolean);
begin
  FPaletteActive := AValue;
end;

function TChatPanel.PaletteActive: Boolean;
begin
  Result := FPaletteActive;
end;

procedure TChatPanel.SetCta(AKind: TCtaKind);
begin
  FCompose.Cta := AKind;
end;

{ The recent-session list shown under the mark. The panel keeps only TITLES:
  the host owns the session rows and performs the switch, so the widget cannot
  open a session it does not have the store for. }
procedure TChatPanel.SetRecentSessions(const ATitles: array of string);
var
  I, N: Integer;
begin
  N := Length(ATitles);
  if N > 10 then
    N := 10;   { ctrl+0..ctrl+9 is the whole vocabulary }
  SetLength(FRecentTitles, N);
  for I := 0 to N - 1 do
    FRecentTitles[I] := ATitles[I];
end;

procedure TChatPanel.SetActionsMode(AValue: Boolean);
begin
  FActionsMode := AValue;
  FActions.Visible := AValue;
  FCompose.Visible := not AValue;
end;

function TChatPanel.ActionsMode: Boolean;
begin
  Result := FActionsMode;
end;

end.
