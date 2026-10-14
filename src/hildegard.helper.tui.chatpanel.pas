unit hildegard.helper.tui.chatpanel;
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
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.panel,
  hildegard.helper.tui.theme, hildegard.helper.tui.chat,
  hildegard.helper.tui.grapheme,
  hildegard.helper.tui.compose, hildegard.helper.tui.palette,
  hildegard.helper.tui.actions;

type
  { What the run is doing, shown at the left of the toolbar. psThinking and
    psTool animate the sparkle; the others are static icons. }
  TPanelState = (psReady, psThinking, psTool, psApproval, psError, psInterrupt);

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
    FStatus: TTextBlock;
    FStats: TTextBlock;
    FStatusText: string;
    FStatsText: string;
    FHeaderLeft: string;
    FHeaderRight: string;
    FPageCount: Integer;
    FPageIndex: Integer;
    FStateKind: TPanelState;
    FStateLabel: string;
    FStateSpans: array[0..1] of TSpan;
    FSpark: UnicodeString;
    procedure RenderState;
    procedure RefreshAnimation;
    procedure FitStatus;
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
    { The left of the toolbar: what the run is doing. }
    procedure SetState(AKind: TPanelState; const ALabel: string);
    { The right of the toolbar: the interaction hints. }
    procedure SetHints(const AText: string);
    { Disable input while a turn runs, keeping whatever was typed. }
    procedure SetComposeActive(AValue: Boolean);
    { The compose's primary-action CTA (send / cancel / none). }
    procedure SetCta(AKind: TCtaKind);
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
begin
  if StateAnimated(FStateKind) then
    FStateSpans[0].Text := FSpark
  else
    FStateSpans[0].Text := StateIcon(FStateKind);
  FStateSpans[0].Attr := StateAttr(FTheme, FStateKind);
  FStateSpans[1].Text := UnicodeString(' ' + FStateLabel);
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
  FitStatus;
end;

procedure TChatPanel.Render(const S: ISurface);
var
  B: TRect;
  Top, Bot, H, I, Y0, Y1: Integer;
  Heavy: UnicodeString;
begin
  FMessages.Render(S);
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

procedure TChatPanel.SetPageIndex(AIndex: Integer);
begin
  FPageIndex := AIndex;
  if FPageIndex < 0 then
    FPageIndex := 0;
  if FPageIndex > FPageCount - 1 then
    FPageIndex := FPageCount - 1;
end;

function TChatPanel.HandleEvent(const E: TInputEvent): Boolean;
begin
  { When the palette is up, it takes the keys first (Up/Down/Enter/Escape). }
  if FPaletteActive and FPalette.HandleEvent(E) then
    Exit(True);
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
  FHintsBlock.SetText(AText, FTheme.Muted);
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
