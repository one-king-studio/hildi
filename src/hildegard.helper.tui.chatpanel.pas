unit hildegard.helper.tui.chatpanel;
{ The chat column: a bordered messages panel holding a TChatStream, a compose
  box that overlays it as it grows, a CTA strip above the compose, and a status
  line below.

  The compose overlays rather than reflows, so growing the input never moves the
  conversation. }

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
  TChatPanel = class(TWidget)
  private
    FTheme: TTheme;
    FMessages: TPanel;
    FStream: TChatStream;
    FCta: TPanel;
    FCtaText: TTextBlock;
    FCompose: TComposeBox;
    FStatus: TTextBlock;
    FStats: TTextBlock;
    FStatusText: string;
    FStatsText: string;
    procedure FitStatus;
  public
    constructor Create(const ATheme: TTheme; const AInfo, ACta: string);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Stream: TChatStream read FStream;
    property Compose: TComposeBox read FCompose;
    procedure SetStatus(const AText: string);
    { The right-aligned metrics line, sharing the status row. }
    procedure SetStats(const AText: string);
    procedure SetCta(const AText: string);
    { Disable input while a turn runs, keeping whatever was typed. }
    procedure SetComposeActive(AValue: Boolean);
  end;

implementation

const
  { The compose never takes more than this share of the panel height. }
  MaxComposePercent = 60;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
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

constructor TChatPanel.Create(const ATheme: TTheme; const AInfo, ACta: string);
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

  { The CTA/stats strip above the compose: filled, no border, inside the
    messages panel's borders. }
  FCtaText := TTextBlock.Create([], wmNone);
  FCtaText.SetText(ACta, ATheme.Muted);
  Style := DefaultBoxStyle;
  Style.Title := '';
  Style.Border := False;
  Style.Padding := 0;
  FCta := TPanel.Create(FCtaText, ATheme, Style);

  FCompose := TComposeBox.Create(ATheme, AInfo);

  FStatus := TTextBlock.Create([], wmNone);
  FStats := TTextBlock.Create([], wmNone);
  FStats.Align := taRight;
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

function TChatPanel.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TChatPanel.Arrange(const ABounds: TRect);
var
  MessagesH, ComposeH, MaxH, ComposeY: Integer;
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
  FStatus.Arrange(Rc(ABounds.X + 1, ABounds.Y + ABounds.H - 1, ABounds.W - 2, 1));
  FStats.Arrange(Rc(ABounds.X + 1, ABounds.Y + ABounds.H - 1, ABounds.W - 2, 1));
  FCompose.Arrange(Rc(ABounds.X, ComposeY, ABounds.W, ComposeH));
  { The CTA strip sits above the compose, inside the messages panel's borders
    and short of the scrollbar column, so those borders are not overwritten. }
  FCta.Arrange(Rc(ABounds.X + 1, ComposeY - 1, ABounds.W - 3, 1));
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
begin
  Result := FCompose.Advance(ANowMs);
  if FMessages.Advance(ANowMs) then
    Result := True;
end;

function TChatPanel.Animating: Boolean;
begin
  Result := FCompose.Animating or FMessages.Animating;
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

{ Keep the left status short of the right-aligned stats, so a long workspace
  path does not run into the metrics on a narrow terminal. }
procedure TChatPanel.FitStatus;
var
  RowW, StatsW: Integer;
begin
  if FBounds.W <= 0 then
    Exit;
  RowW := FBounds.W - 2;
  StatsW := StringWidth(UnicodeString(FStatsText));
  if StatsW >= RowW - 1 then
    FStatus.SetText('', FTheme.Muted)
  else
    FStatus.SetText(string(FitWidth(UnicodeString(FStatusText),
      RowW - StatsW - 2)), FTheme.Muted);
end;

procedure TChatPanel.SetCta(const AText: string);
begin
  FCtaText.SetText(AText, FTheme.Muted);
end;

procedure TChatPanel.SetComposeActive(AValue: Boolean);
begin
  FCompose.Edit.Active := AValue;
end;

end.
