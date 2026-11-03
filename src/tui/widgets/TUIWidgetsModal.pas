unit TUIWidgetsModal;
{ A reusable scrollable modal: a framed dialog whose CONTENT scrolls as one,
  with a fixed footer row that the content cannot push away.

  Every dialog in this toolkit had grown its own copy of the frame drawing, its
  own body area and its own idea of what "at most 80% of the screen" means. The
  skill dialog needed the whole content - fields AND markdown - to scroll
  together under ONE scrollbar, and doing that per-dialog would have been a
  fourth copy.

  So: a subclass supplies a single content widget and a footer string. This unit
  owns the frame, the height cap, the scroll container and the footer row.

  A subclass does not draw its frame, arrange its content, or handle scrolling -
  it builds content and reports a footer. That is the whole contract. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIGrapheme,
  TUIWidgetsText, TUIWidgetsScroll;

const
  { A dialog takes at most this share of the screen, so the transcript stays
    visible behind it and the operator knows it is an overlay. }
  ModalMaxHeightPercent = 80;
  { Top border, the footer row, the bottom border. }
  ModalChromeRows = 3;
  ModalMinWidth = 24;
  { The footer text is inset from the frame by this much on the right. }
  ModalFooterPad = 1;
  { Content is inset from the frame by this much on each side. }
  ModalContentPad = 1;

type
  TScrollModal = class(TWidget)
  private
    FTheme: TTheme;
    FTitle: string;
    { The one scrollable region. It owns the content widget. }
    FScroll: TScrollContainer;
    FContent: TWidget;
    FFooter: TSpanArray;
    function FrameBg: TAttr;
    function BorderAttr: TAttr;
    function TitleAttr: TAttr;
    function FooterKeyAttr: TAttr;
    function FooterActionAttr: TAttr;
  protected
    { The theme, for a subclass that draws inside the content area. }
    property Theme: TTheme read FTheme;
    { Called after Arrange, with the width the content was given, so a subclass
      can rebuild content that depends on width. Empty by default. }
    procedure ContentWidthChanged(AWidth: Integer); virtual;
  public
    { AContent is owned by the modal: it is handed to the scroll container, which
      frees it. }
    constructor Create(const ATheme: TTheme; AContent: TWidget);
    destructor Destroy; override;

    { What the top border says. }
    procedure SetTitle(const AText: string);
    { The footer CTA: two-tone, split on ' · ' by the shared HintSpans walker. }
    procedure SetFooter(const AText: string);
    { Re-read the footer from a subclass, after its state changed. }
    procedure RefreshFooter;

    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    { The scrollable region, for a subclass that needs to reset the offset. }
    procedure ScrollToTop;
  end;

implementation

constructor TScrollModal.Create(const ATheme: TTheme; AContent: TWidget);
begin
  inherited Create;
  FTheme := ATheme;
  FContent := AContent;
  if FContent <> nil then
    FScroll := TScrollContainer.Create(FContent, smAuto, smNever)
  else
    FScroll := nil;
  FTitle := '';
  FFooter := nil;
end;

destructor TScrollModal.Destroy;
begin
  { FScroll owns FContent. }
  FScroll.Free;
  inherited Destroy;
end;

function TScrollModal.FrameBg: TAttr;
begin
  Result := OnBg(FTheme.Text, FTheme.RaisedBg);
end;

function TScrollModal.BorderAttr: TAttr;
begin
  Result := OnBg(FTheme.Border, FTheme.RaisedBg);
end;

function TScrollModal.TitleAttr: TAttr;
begin
  Result := OnBg(FTheme.Accent, FTheme.RaisedBg);
end;

function TScrollModal.FooterKeyAttr: TAttr;
begin
  { The keybinding is chrome, so it sits a tone back; it carries the modal's own
    background because PaintSpans only sets the foreground. }
  Result := OnBg(FTheme.Muted, FTheme.RaisedBg);
end;

function TScrollModal.FooterActionAttr: TAttr;
begin
  Result := OnBg(FTheme.Text, FTheme.RaisedBg);
end;

procedure TScrollModal.ContentWidthChanged(AWidth: Integer);
begin
  { Nothing by default. A subclass that wraps content to width overrides this;
    Arrange calls it once the real width is known. }
  if AWidth < 0 then
    ;
end;

procedure TScrollModal.SetTitle(const AText: string);
begin
  FTitle := AText;
end;

procedure TScrollModal.SetFooter(const AText: string);
begin
  FFooter := HintSpans(UnicodeString(AText), FooterKeyAttr, FooterActionAttr);
end;

procedure TScrollModal.RefreshFooter;
begin
  { Nothing to rebuild unless a subclass set text it wants re-split. Kept as a
    hook so a subclass can call it after changing its own state. }
end;

procedure TScrollModal.ScrollToTop;
begin
  if FScroll <> nil then
    FScroll.ScrollTo(0, 0);
end;

function TScrollModal.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W - 6;
  if Result.W < ModalMinWidth then
    Result.W := AAvail.W;
  { Capped, so the transcript shows behind it. The content scrolls inside. }
  Result.H := (AAvail.H * ModalMaxHeightPercent) div 100;
  if Result.H < ModalChromeRows + 3 then
    Result.H := AAvail.H;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TScrollModal.Arrange(const ABounds: TRect);
var
  InnerW, ContentH, ContentY: Integer;
  R: TRect;
begin
  inherited Arrange(ABounds);
  if FScroll = nil then
    Exit;
  InnerW := ABounds.W - 2 * ModalContentPad - 1;
  if InnerW < 1 then
    InnerW := 1;
  ContentY := ABounds.Y + 1;                    { below the top border }
  { The footer row is the inner row above the bottom border, and the content
    stops above it so the CTAs are never scrolled away. }
  ContentH := (ABounds.Y + ABounds.H - 1) - 1 - ContentY;
  if ContentH < 1 then
    ContentH := 1;
  R := Default(TRect);
  R.X := ABounds.X + ModalContentPad + 1;
  R.Y := ContentY;
  R.W := InnerW;
  R.H := ContentH;
  FScroll.Arrange(R);
  ContentWidthChanged(InnerW);
end;

procedure TScrollModal.Render(const S: ISurface);
var
  L, R, T, B, I, FX: Integer;
  Title: string;
begin
  if (FBounds.W < 8) or (FBounds.H < ModalChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  S.FillRect(FBounds, FrameBg);

  PutCh(S, L, T, '╭', BorderAttr);
  PutCh(S, R, T, '╮', BorderAttr);
  PutCh(S, L, B, '╰', BorderAttr);
  PutCh(S, R, B, '╯', BorderAttr);
  for I := L + 1 to R - 1 do
  begin
    PutCh(S, I, T, '─', BorderAttr);
    PutCh(S, I, B, '─', BorderAttr);
  end;
  for I := T + 1 to B - 1 do
  begin
    PutCh(S, L, I, '│', BorderAttr);
    PutCh(S, R, I, '│', BorderAttr);
  end;

  if FTitle <> '' then
  begin
    Title := ' ' + FTitle + ' ';
    PutText(S, L + 2, T, UnicodeString(Title), TitleAttr);
  end;

  { The whole content, under one scrollbar. }
  if FScroll <> nil then
    FScroll.Render(S);

  { The footer, right-aligned on its own row, always visible. }
  if Length(FFooter) > 0 then
  begin
    FX := R - ModalFooterPad - SpansWidth(FFooter);
    if FX < L + 2 then
      FX := L + 2;
    PaintSpans(S, FX, B - 1, FFooter);
  end;
end;

function TScrollModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  { Scrolling belongs to the container: it owns the clamp, the scrollbar and the
    wheel. A subclass handles its own keys FIRST and falls back to this. }
  Result := False;
  if FScroll <> nil then
    Result := FScroll.HandleEvent(E);
end;

end.
