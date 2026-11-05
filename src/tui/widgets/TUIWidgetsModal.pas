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
  { Spaces between CTA pairs. TApprovalModal uses three; there is no dot, which
    is the house style the operator asked to match. }
  FooterGap = 3;
  { Inline padding between the left border and the content. }
  ModalContentPad = 1;

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
    { The footer as explicit KEY/ACTION pairs, the shape TApprovalModal uses:
      a dim key, its action in normal text, then plain spaces before the next
      pair. No dot separator - the approval dialog is the house style and it uses
      spacing, not punctuation, to separate the groups. }
    FFooterKeys: TStringArray;
    FFooterActions: TStringArray;
    FContent: TWidget;
    FScroll: TScrollContainer;
    FScrollable: Boolean;
    { The footer's clickable segments: one per 'key action' group, with the
      screen X each was drawn at. Built during Render, because the position is
      only known once the frame is laid out. }
    { Where each pair was drawn, filled during Render. }
    FSegX: array of Integer;
    FSegW: array of Integer;
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
    function FooterWidth: Integer;
    function FooterX: Integer;
    { Called once the content width is known, so a subclass can re-wrap. }
    procedure ContentWidthChanged(AWidth: Integer); virtual;
    procedure ArrangeContent(const AInner: TRect); virtual;
    { Draw the content area. Default renders the content widget; a subclass that
      paints its own rows overrides this. Render calls it BETWEEN the frame and
      the footer, so nothing a subclass draws can land on the CTAs. }
    procedure RenderContent(const S: ISurface); virtual;
    { A footer segment was clicked. AKey is the segment's KEY, so a subclass maps
      'enter' and 'esc' to its own actions and ignores the rest. }
    procedure FooterClicked(const AKey: string); virtual;
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
    { How many CTA pairs the last SetFooter produced. Introspection, not
      decoration: a dialog's footer is split by the SAME rule the click path
      uses, so asserting the count per call site is the only way to catch a
      caller and the splitter disagreeing about the separator - the bug where
      clicking "esc cancel" in the skill dialog loaded the skill. }
    function FooterPairCount: Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function CopySelection(const S: ISurface): Boolean; override;
    procedure ScrollToTop;
  end;

implementation

constructor TModal.Create(const ATheme: TTheme; AContent: TWidget;
  AScrollable: Boolean);
begin
  inherited Create;
  FTheme := ATheme;
  FTitle := '';
  FFooterKeys := nil;
  FFooterActions := nil;
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
  { Plain TEXT, not FTheme.Title. Title is a blue accent (81 dark / 25 light) and
    the operator asked for normal text: the frame should look like a container,
    not like it is highlighting its own name. Bold keeps it readable as a heading
    without adding a colour. }
  Result := OnBg(WithStyle(FTheme.Text, [sfBold]), FTheme.RaisedBg);
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
var
  U, Norm, Seg: UnicodeString;
  I, N, P: Integer;

  procedure AddPair(const ASeg: UnicodeString);
  var
    Q: Integer;
  begin
    if ASeg = '' then
      Exit;
    Q := Pos(' ', ASeg);
    SetLength(FFooterKeys, Length(FFooterKeys) + 1);
    SetLength(FFooterActions, Length(FFooterActions) + 1);
    if Q > 0 then
    begin
      { A pair splits at its FIRST space: 'enter' plus ' accept'. }
      FFooterKeys[High(FFooterKeys)] := string(UTF8Encode(Copy(ASeg, 1, Q - 1)));
      FFooterActions[High(FFooterActions)] := string(UTF8Encode(Copy(ASeg, Q, MaxInt)));
    end
    else
    begin
      { A lone phrase has no binding to dim, so it is all action. It must still
        be clickable-by-key? No: an empty key cannot be clicked, by design. }
      FFooterKeys[High(FFooterKeys)] := '';
      FFooterActions[High(FFooterActions)] := string(UTF8Encode(ASeg));
    end;
  end;

begin
  FFooterKeys := nil;
  FFooterActions := nil;
  if AText = '' then
    Exit;

  { TWO separators are accepted: a run of two or more spaces, and the middle dot.
    This is the rule HintSpans already uses for DRAWING the footer, and the two
    must agree - they did not. Every CTA call site was swept to spaces in
    a4b7494, but this splitter still handled only the dot, so in production each
    footer collapsed to ONE segment: it drew correctly through HintSpans and
    reported the wrong CTA on a click. Found by TestTUIModal.

    Normalise first, into a separator that cannot occur in a hint. }
  { AText is a UTF-8 AnsiString: the source is compiled as UTF-8 and every call
    site passes a literal. Decode it explicitly rather than assigning straight
    into a UnicodeString, which would treat the UTF-8 bytes as Latin-1 and turn
    the middle dot into two characters that match nothing. }
  U := UTF8Decode(RawByteString(AText));
  N := Length(U);
  Norm := '';
  I := 1;
  while I <= N do
  begin
    if (U[I] = ' ') and (I < N) and (U[I + 1] = ' ') then
    begin
      Norm := Norm + #1;
      while (I <= N) and (U[I] = ' ') do
        Inc(I);
    end
    else if U[I] = WideChar($00B7) then
    begin
      Norm := Norm + #1;
      Inc(I);
    end
    else
    begin
      Norm := Norm + U[I];
      Inc(I);
    end;
  end;

  Seg := '';
  for I := 1 to Length(Norm) do
    if Norm[I] = #1 then
    begin
      AddPair(Trim(Seg));
      Seg := '';
    end
    else
      Seg := Seg + Norm[I];
  AddPair(Trim(Seg));
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

function TModal.FooterPairCount: Integer;
begin
  Result := Length(FFooterKeys);
end;

function TModal.InnerRect: TRect;
begin
  Result := Default(TRect);
  if (FBounds.W < 2) or (FBounds.H < 3) then
    Exit;
  { The content rect runs to the RIGHT BORDER column rather than one short of
    it: the scroll container puts its bar at its own right edge, and the operator
    wants the bar ON the border. The left edge is inset so text never touches the
    left border. }
  Result.X := FBounds.X + 1 + ModalContentPad;
  Result.Y := FBounds.Y + 1;
  Result.W := FBounds.W - 1 - ModalContentPad;
  { The footer is FIXED: its rows are reserved here, so the scrolled content
    ends above them rather than running underneath. }
  Result.H := FBounds.H - ModalChromeRows;
  if Length(FFooterKeys) > 0 then
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

{ The total width of the footer: each pair's key and action, plus the gaps
  between pairs. Used to right-align it and to lay it out in Render, so the two
  cannot disagree. }
function TModal.FooterWidth: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FFooterKeys) do
  begin
    if I > 0 then
      Inc(Result, FooterGap);
    Inc(Result, Length(FFooterKeys[I]) + Length(FFooterActions[I]));
  end;
end;

function TModal.FooterX: Integer;
var
  Right: Integer;
begin
  Right := FBounds.X + FBounds.W - 1 - ModalFooterPad;
  Result := Right - FooterWidth;
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
  begin
    { The bar starts one row below the top border, clear of the rounded corner,
      and stops one row above the footer divider. TrackTop/TrackBottom exist for
      exactly this - the chat panel uses them for the compose overlay. }
    FScroll.TrackTop := 1;
    FScroll.TrackBottom := 1;
    { No track: the bar sits ON the border column, and a painted track would
      overwrite the box-drawing rule. Only the thumb shows. The property's own
      comment says to set this when the bar sits on a border. }
    FScroll.TrackVisible := False;
    FScroll.Arrange(AInner);
  end
  else if FContent <> nil then
    FContent.Arrange(AInner);
end;

procedure TModal.RenderContent(const S: ISurface);
begin
  if FScroll <> nil then
    FScroll.Render(S)
  else if FContent <> nil then
    FContent.Render(S);
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
  L, R, I, DivY, FX, W: Integer;
begin
  PaintFrame(S);
  RenderContent(S);
  { The FIXED footer, as TApprovalModal lays it out: a DIVIDER row, then the CTA
    row, both above the bottom border. The divider is what separates the scrolling
    content from the actions - without it the CTAs read as the last line of
    content rather than as chrome that is always there. }
  if (Length(FFooterKeys) > 0) and
    (FBounds.H >= ModalChromeRows + ModalFooterRows) then
  begin
    DivY := FBounds.Y + FBounds.H - 1 - ModalFooterRows;
    L := FBounds.X;
    R := FBounds.X + FBounds.W - 1;
    PutCh(S, L, DivY, '├', BorderAttr);
    PutCh(S, R, DivY, '┤', BorderAttr);
    for I := L + 1 to R - 1 do
      PutCh(S, I, DivY, '─', BorderAttr);

    { Each pair: the key dim, its action in normal text, then plain SPACES before
      the next pair - exactly how TApprovalModal lays out 'enter' + ' accept'. No
      dot: spacing separates the groups, which is the house style the operator
      asked to match. The X each pair started at is remembered for hit-testing. }
    FX := FooterX;
    FSegX := nil;
    FSegW := nil;
    for I := 0 to High(FFooterKeys) do
    begin
      if I > 0 then
        Inc(FX, FooterGap);
      SetLength(FSegX, Length(FSegX) + 1);
      SetLength(FSegW, Length(FSegW) + 1);
      FSegX[High(FSegX)] := FX;
      W := 0;
      if FFooterKeys[I] <> '' then
      begin
        PutText(S, FX, DivY + 1, UnicodeString(FFooterKeys[I]), FooterKeyAttr);
        Inc(FX, Length(FFooterKeys[I]));
        Inc(W, Length(FFooterKeys[I]));
      end;
      PutText(S, FX, DivY + 1, UnicodeString(FFooterActions[I]),
        FooterActionAttr);
      Inc(FX, Length(FFooterActions[I]));
      Inc(W, Length(FFooterActions[I]));
      FSegW[High(FSegW)] := W;
    end;
  end;
end;

procedure TModal.FooterClicked(const AKey: string);
begin
  { Nothing by default: a subclass maps the key to its own action. }
  if AKey = '' then
    ;
end;

function TModal.HandleEvent(const E: TInputEvent): Boolean;
var
  I, FY: Integer;
begin
  { Scrolling belongs to the container: it owns the clamp, the scrollbar and the
    wheel. A subclass handles its own keys first and falls back to this. }
  Result := False;
  { A click on the FIXED footer. Checked before the scroller, since the footer is
    chrome outside the scroll region and must win. }
  if (E.Kind = ikMouse) and (E.Mouse.Button = mbLeft) and
    (Length(FFooterKeys) > 0) then
  begin
    FY := FBounds.Y + FBounds.H - 1 - ModalFooterRows + 1;
    if E.Mouse.Y = FY then
      for I := 0 to High(FSegX) do
        if (E.Mouse.X >= FSegX[I]) and (E.Mouse.X < FSegX[I] + FSegW[I]) then
        begin
          { The click reports the pair's KEY, so a subclass maps 'enter' or 'esc'
            to its own action. A pair with no key cannot be clicked. }
          if FFooterKeys[I] <> '' then
            FooterClicked(FFooterKeys[I]);
          Exit(True);
        end;
  end;
  if FScroll <> nil then
    Result := FScroll.HandleEvent(E)
  else if FContent <> nil then
    { A NON-scrollable modal has no scroller between it and its content, and this
      arm was missing: events went nowhere. Found by the forwarding gate. }
    Result := FContent.HandleEvent(E);
end;

function TModal.CopySelection(const S: ISurface): Boolean;
begin
  { The frame is chrome; the copyable text is in the content. Without this the
    copy walk stopped at the dialog - every modal was a copy dead end, which is
    exactly the class of bug the forwarding gate exists to catch. }
  if FScroll <> nil then
    Result := FScroll.CopySelection(S)
  else if FContent <> nil then
    Result := FContent.CopySelection(S)
  else
    Result := False;
end;

end.
