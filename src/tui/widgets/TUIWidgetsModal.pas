unit TUIWidgetsModal;
{ The modal every dialog here shares.

  TModal owns what all four dialogs had been re-implementing: the border, the
  title, the 80% height cap, and a footer drawn ON the bottom border - the house
  idiom, since THistoryModal paints its CTA over the border rather than on a row
  above it.

  SCROLLING IS A PARAMETER, not a subclass. Pass a content widget and the modal
  wraps it in one scroll container, so a dialog whose content overflows scrolls
  as a whole under a single scrollbar while the footer stays in the frame. Pass
  no content, and a subclass arranges its own rows inside the frame - which is
  what the history, sessions and approval dialogs do.

  A subclass supplies a title, a footer string and optionally one content
  widget. It never draws a frame, arranges the scroll region, or handles
  scrolling. }

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
    visible behind it and it reads as an overlay. }
  ModalMaxHeightPercent = 80;
  { Top border and bottom border. }
  ModalChromeRows = 2;
  { The FIXED footer: a divider row and the CTA row, both above the bottom
    border. Content scrolls above them and can never cover them - which is the
    point of a footer. }
  ModalFooterRows = 2;
  ModalMinWidth = 24;
  { The footer is inset from the right corner by this much. }
  ModalFooterPad = 1;

type
  { The modal every dialog here shares. It owns the border, the title, the 80%
    height cap, and a footer drawn ON the bottom border - the house idiom, since
    THistoryModal paints its CTA over the border rather than on a row above it.

    SCROLLING IS A PARAMETER, not a subclass: pass AScrollable and the content is
    wrapped in one scroll container, so a dialog whose content overflows scrolls
    as a whole under one scrollbar while the footer stays in the frame. Pass
    False, or no content at all, and the subclass arranges its own rows inside
    the frame - which is what the history, sessions and approval dialogs do.

    A subclass supplies a title, a footer string and optionally one content
    widget. It never draws a frame or handles scrolling. }
  TModal = class(TWidget)
  private
    FTheme: TTheme;
    FTitle: string;
    FFooter: TSpanArray;
    FContent: TWidget;
    FScroll: TScrollContainer;
    FScrollable: Boolean;
  protected
    function FrameBg: TAttr; virtual;
    function BorderAttr: TAttr; virtual;
    function TitleAttr: TAttr; virtual;
    function FooterKeyAttr: TAttr; virtual;
    function FooterActionAttr: TAttr; virtual;
    { The theme, for a subclass drawing inside the frame. }
    property Theme: TTheme read FTheme;
    { The inner area: inside the border, above the bottom border row. }
    function InnerRect: TRect;
    { Draw the frame and the title. Call FIRST in a subclass's Render. }
    procedure PaintFrame(const S: ISurface);
    function FooterX: Integer;
    { Called once the content width is known, so a subclass can re-wrap. }
    procedure ContentWidthChanged(AWidth: Integer); virtual;
    procedure ArrangeContent(const AInner: TRect); virtual;
  public
    { AContent is OWNED by the modal when given. AScrollable wraps it in one
      scroll container; without it the content is arranged directly. }
    constructor Create(const ATheme: TTheme; AContent: TWidget = nil;
      AScrollable: Boolean = True);
    destructor Destroy; override;
    procedure SetTitle(const AText: string);
    { The footer CTA: two-tone, split on ' middle-dot ' by the shared HintSpans
      walker. Empty means no footer and a plain bottom border. }
    procedure SetFooter(const AText: string);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    procedure ScrollToTop;
  end;

implementation

constructor TModal.Create(const ATheme: TTheme; AContent: TWidget;
  AScrollable: Boolean);
begin
  inherited Create;
  FTheme := ATheme;
  FTitle := '';
  FFooter := nil;
  FContent := AContent;
  FScrollable := AScrollable;
  if (FContent <> nil) and FScrollable then
    FScroll := TScrollContainer.Create(FContent, smAuto, smNever)
  else
    FScroll := nil;
end;

destructor TModal.Destroy;
begin
  { The container owns the content; without one, the modal does. }
  if FScroll <> nil then
    FScroll.Free
  else
    FContent.Free;
  inherited Destroy;
end;

function TModal.FrameBg: TAttr;
begin
  Result := OnBg(FTheme.Text, FTheme.RaisedBg);
end;

function TModal.BorderAttr: TAttr;
begin
  Result := OnBg(FTheme.Border, FTheme.RaisedBg);
end;

function TModal.TitleAttr: TAttr;
begin
  { TITLE, not Accent: every dialog here titles with Title. Accent is the
    focus/selection colour and made a heading read as an active control. }
  Result := OnBg(FTheme.Title, FTheme.RaisedBg);
end;

function TModal.FooterKeyAttr: TAttr;
begin
  { The keybinding is chrome, so it sits a tone back. It carries the frame's own
    background because PaintSpans sets only the foreground. }
  Result := OnBg(FTheme.Muted, FTheme.RaisedBg);
end;

function TModal.FooterActionAttr: TAttr;
begin
  Result := OnBg(FTheme.Text, FTheme.RaisedBg);
end;

procedure TModal.SetTitle(const AText: string);
begin
  FTitle := AText;
end;

procedure TModal.SetFooter(const AText: string);
begin
  FFooter := HintSpans(UnicodeString(AText), FooterKeyAttr, FooterActionAttr);
end;

procedure TModal.ContentWidthChanged(AWidth: Integer);
begin
  { Nothing by default: a subclass whose content re-wraps overrides this. }
  if AWidth < 0 then
    ;
end;

procedure TModal.ScrollToTop;
begin
  if FScroll <> nil then
    FScroll.ScrollTo(0, 0);
end;

function TModal.InnerRect: TRect;
begin
  Result := Default(TRect);
  if (FBounds.W < 2) or (FBounds.H < 3) then
    Exit;
  Result.X := FBounds.X + 1;
  Result.Y := FBounds.Y + 1;
  Result.W := FBounds.W - 2;
  { The footer is FIXED: its rows are reserved here, so the scrolled content
    ends above them rather than running underneath. }
  Result.H := FBounds.H - ModalChromeRows;
  if Length(FFooter) > 0 then
    Dec(Result.H, ModalFooterRows);
end;

function TModal.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W - 6;
  if Result.W < ModalMinWidth then
    Result.W := AAvail.W;
  { Capped, so the transcript shows behind it. }
  Result.H := (AAvail.H * ModalMaxHeightPercent) div 100;
  if Result.H < ModalChromeRows + 3 then
    Result.H := AAvail.H;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

function TModal.FooterX: Integer;
var
  Right: Integer;
begin
  Right := FBounds.X + FBounds.W - 1 - ModalFooterPad;
  Result := Right - SpansWidth(FFooter);
  if Result < FBounds.X + 2 then
    Result := FBounds.X + 2;
end;

procedure TModal.PaintFrame(const S: ISurface);
var
  L, R, T, B, I: Integer;
  Attr: TAttr;
  Title: string;
begin
  if (FBounds.W < 6) or (FBounds.H < ModalChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  Attr := BorderAttr;

  S.FillRect(FBounds, FrameBg);

  PutCh(S, L, T, '╭', Attr);
  PutCh(S, R, T, '╮', Attr);
  PutCh(S, L, B, '╰', Attr);
  PutCh(S, R, B, '╯', Attr);
  for I := L + 1 to R - 1 do
  begin
    PutCh(S, I, T, '─', Attr);
    { A HEAVY bottom edge, as TApprovalModal draws it. Every other dialog here
      used a single line, which is why the dialogs did not look like one family:
      the approval dialog's double rule is what makes it read as a committed
      action rather than an ordinary panel. }
    PutCh(S, I, B, '═', Attr);
  end;
  for I := T + 1 to B - 1 do
  begin
    PutCh(S, L, I, '│', Attr);
    PutCh(S, R, I, '│', Attr);
  end;

  if FTitle <> '' then
  begin
    Title := ' ' + FTitle + ' ';
    PutText(S, L + 2, T, UnicodeString(Title), TitleAttr);
  end;
end;

procedure TModal.ArrangeContent(const AInner: TRect);
begin
  if FScroll <> nil then
    FScroll.Arrange(AInner)
  else if FContent <> nil then
    FContent.Arrange(AInner);
end;

procedure TModal.Arrange(const ABounds: TRect);
var
  Inner: TRect;
begin
  inherited Arrange(ABounds);
  Inner := InnerRect;
  if (Inner.W < 1) or (Inner.H < 1) then
    Exit;
  { The content runs the full inner height: the footer lives on the border row,
    so it costs no inner space and content can never push the CTAs away. }
  ArrangeContent(Inner);
  ContentWidthChanged(Inner.W);
end;

procedure TModal.Render(const S: ISurface);
var
  L, R, I, DivY: Integer;
begin
  PaintFrame(S);
  if FScroll <> nil then
    FScroll.Render(S)
  else if FContent <> nil then
    FContent.Render(S);
  { The FIXED footer, as TApprovalModal lays it out: a DIVIDER row, then the CTA
    row, both above the bottom border. The divider is what separates the scrolling
    content from the actions - without it the CTAs read as the last line of
    content rather than as chrome that is always there. }
  if (Length(FFooter) > 0) and
    (FBounds.H >= ModalChromeRows + ModalFooterRows) then
  begin
    DivY := FBounds.Y + FBounds.H - 1 - ModalFooterRows;
    L := FBounds.X;
    R := FBounds.X + FBounds.W - 1;
    PutCh(S, L, DivY, '├', BorderAttr);
    PutCh(S, R, DivY, '┤', BorderAttr);
    for I := L + 1 to R - 1 do
      PutCh(S, I, DivY, '─', BorderAttr);
    PaintSpans(S, FooterX, DivY + 1, FFooter);
  end;
end;

function TModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  { Scrolling belongs to the container: it owns the clamp, the scrollbar and the
    wheel. A subclass handles its own keys first and falls back to this. }
  Result := False;
  if FScroll <> nil then
    Result := FScroll.HandleEvent(E);
end;

end.
