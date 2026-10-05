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
  hildegard.helper.tui.compose;

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
    FStatus: TTextBlock;
    FStats: TTextBlock;
    FStatusText: string;
    FStatsText: string;
    FHeaderLeft: string;
    FHeaderRight: string;
    FStateKind: TPanelState;
    FStateLabel: string;
    FStateSpans: array[0..1] of TSpan;
    FSpark: UnicodeString;
    procedure RenderState;
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
    { The left part of the status row (the workspace). }
    procedure SetStatus(const AText: string);
    { The right-aligned metrics line, sharing the status row. }
    procedure SetStats(const AText: string);
    { The messages panel's top border: the session id at the left, the session
      stats at the right. }
    procedure SetHeader(const ALeft, ARight: string);
    property HeaderLeft: string read FHeaderLeft;
    property HeaderRight: string read FHeaderRight;
    { The left of the toolbar: what the run is doing. }
    procedure SetState(AKind: TPanelState; const ALabel: string);
    { The right of the toolbar: the interaction hints. }
    procedure SetHints(const AText: string);
    { Disable input while a turn runs, keeping whatever was typed. }
    procedure SetComposeActive(AValue: Boolean);
    { The compose's primary-action CTA (send / cancel / none). }
    procedure SetCta(AKind: TCtaKind);
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
  FMessages.Free;
  FCta.Free;
  FCompose.Free;
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
  MessagesH, ComposeH, MaxH, ComposeY, ChromeW, ChromeX: Integer;
begin
  inherited Arrange(ABounds);
  MessagesH := ABounds.H - 1;   { the status line }
  if MessagesH < 1 then
    MessagesH := 1;

  { The compose is an overlay: it grows upward over the messages panel, which
    keeps its full size, so the message content and its scroll do not reflow. }
  ComposeH := FCompose.NeededHeight(ABounds.W);
  MaxH := (ABounds.H * MaxComposePercent) div 100;
  if ComposeH > MaxH then
    ComposeH := MaxH;
  if ComposeH < 4 then
    ComposeH := 4;
  ComposeY := ABounds.Y + MessagesH - ComposeH;
  if ComposeY < ABounds.Y then
    ComposeY := ABounds.Y;

  { Tell the stream how many of its rows the CTA and compose cover, so the last
    block still keeps its two blank pad rows visible above them. The messages
    panel has a one-row border, so its inner area ends one row above the
    panel's bottom edge. }
  FStream.BottomInset := ABounds.Y + MessagesH - ComposeY;

  FMessages.Arrange(Rc(ABounds.X, ABounds.Y, ABounds.W, MessagesH));
  FCompose.Arrange(Rc(ABounds.X, ComposeY, ABounds.W, ComposeH));
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
begin
  FMessages.Render(S);
  FCta.Render(S);
  FCompose.Render(S);
  FStatus.Render(S);
  FStats.Render(S);
end;

function TChatPanel.HandleEvent(const E: TInputEvent): Boolean;
begin
  if FCompose.HandleEvent(E) then
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

procedure TChatPanel.SetCta(AKind: TCtaKind);
begin
  FCompose.Cta := AKind;
end;

end.
