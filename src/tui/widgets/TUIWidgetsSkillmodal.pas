unit TUIWidgetsSkillmodal;
{ The skill detail dialog: one skill's name, description, metadata, and full
  body, with a CTA to load it when it is not already in context.

  It BROWSES and reports; it does not load. The operator pressing "load" closes
  the dialog and hands the key back to the host, exactly as THistoryModal
  reports a turn id and lets the host undo. That keeps the widget free of the
  registry, the driver and the approval gate.

  Rows are handed in already resolved as a plain record of strings. That is not
  only tidiness: HildiSkills uses HildiAgent, and the Process Split forbids
  HildiHarnessApp (and therefore anything it draws with) from reaching the
  agent. Taking TSkill here would break the split, which TSplitBoundaryTest
  enforces. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIGrapheme,
  TUIWidgetsText, TUIWidgetsMarkdownView, TUIWidgetsScroll,
  MarkdownTree, MarkdownRender;

type
  { One skill as the dialog shows it. The host fills this from the registry; the
    dialog never queries anything. Optional fields stay '' or empty so a skill
    with no licence omits the row rather than showing an empty label. }
  TSkillDetail = record
    Key: string;            // the registry key, echoed back on load
    Name: string;           // the spec name, which is what the operator knows
    Description: string;
    License: string;
    Compatibility: string;
    AllowedTools: string;   // DISPLAYED, never enforced - the spec marks it
                            // experimental and honouring it would let a
                            // downloaded skill widen its own permissions
    Location: string;
    Resources: TStringArray;
    Body: string;           // the SKILL.md body, frontmatter stripped
    Loaded: Boolean;        // in context: the CTA reads "loaded" and is inert
  end;

  TSkillLoadEvent = procedure(const AKey: string) of object;

const
  SkillModalChromeRows = 5;   // top border, title, hint row, bottom border, pad
  { The dialog takes at most this share of the screen height, so it never fills
    the frame and the transcript stays visible behind it. }
  SkillModalMaxHeightPercent = 80;
  SkillModalMinWidth = 30;

type
  TSkillModal = class(TWidget)
  private
    FTheme: TTheme;
    FDetail: TSkillDetail;
    FOnLoad: TSkillLoadEvent;
    { The body is STYLED markdown inside a scroll container. TMarkdownView is the
      same widget the file viewer uses, so this dialog renders markdown properly -
      headings, emphasis, code, lists - AND scrolls, instead of painting
      pre-rendered plain lines with a hand-rolled scroll offset. }
    FMarkdown: TMarkdownView;
    FBody: TScrollContainer;
    { Where the body starts, so Render knows what the container covers. }
    FBodyTop: Integer;
    { The metadata block, PRE-WRAPPED in Arrange and drawn by Render. Building it
      once means the height Arrange reserves and the rows Render paints cannot
      disagree - the bug the palette had when Measure and Render disagreed. }
    FMetaLines: TStringArray;
    FMetaIsValue: array of Boolean;
    procedure BuildMeta(AWidth: Integer);
    function CanLoad: Boolean;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure SetDetail(const ADetail: TSkillDetail);
    { Echoed back when the operator activates the load CTA. }
    function DetailKey: string;
    property OnLoad: TSkillLoadEvent read FOnLoad write FOnLoad;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

{ A rect constructor. Local because each TUI unit carries its own; there is no
  shared one and importing a unit for four lines is not worth it. }
function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

constructor TSkillModal.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FMarkdown := TMarkdownView.Create;
  FBody := TScrollContainer.Create(FMarkdown, smAuto, smNever);
end;

destructor TSkillModal.Destroy;
begin
  { FBody owns FMarkdown. }
  FBody.Free;
  inherited Destroy;
end;

procedure TSkillModal.SetDetail(const ADetail: TSkillDetail);
begin
  FDetail := ADetail;
  { A new skill opens at the TOP: carrying the previous scroll would land the
    operator mid-way through a document they have not read. }
  FMarkdown.SetSource(FDetail.Body);
  FMarkdown.FinishSource;
  FBody.ScrollTo(0, 0);
end;

function TSkillModal.DetailKey: string;
begin
  Result := FDetail.Key;
end;

{ Wrap the metadata block to AWidth. Each value is word-wrapped, so a long
  description occupies the rows it actually needs - the earlier single-line
  PutText ran under the right border. }
procedure TSkillModal.BuildMeta(AWidth: Integer);
var
  Doc: TMdDocument;
  Rendered: TMdLineArray;
  I: Integer;

  procedure AddLine(const AText: string; AIsValue: Boolean);
  var
    Lines: TMdLineArray;
    K: Integer;
  begin
    if AText = '' then
      Exit;
    Rendered := nil;
    Doc := ParseTree(AText);
    try
      Lines := RenderTree(Doc, AWidth);
    finally
      Doc.Free;
    end;
    for K := 0 to High(Lines) do
    begin
      SetLength(FMetaLines, Length(FMetaLines) + 1);
      FMetaLines[High(FMetaLines)] := Lines[K];
      SetLength(FMetaIsValue, Length(FMetaIsValue) + 1);
      FMetaIsValue[High(FMetaIsValue)] := AIsValue;
    end;
  end;

begin
  FMetaLines := nil;
  FMetaIsValue := nil;
  { Captions are drawn as plain chrome rows; values are WRAPPED markdown, so a
    value containing `code` or **emphasis** reads as such rather than as its
    source. }
  if FDetail.Description <> '' then
  begin
    AddLine('Description', False);
    AddLine(FDetail.Description, True);
  end;
  if FDetail.License <> '' then
  begin
    AddLine('License', False);
    AddLine(FDetail.License, True);
  end;
  if FDetail.Compatibility <> '' then
  begin
    AddLine('Compatibility', False);
    AddLine(FDetail.Compatibility, True);
  end;
  if FDetail.AllowedTools <> '' then
  begin
    { Labelled as not enforced: it is displayed and never consulted. }
    AddLine('Allowed tools (not enforced)', False);
    AddLine(FDetail.AllowedTools, True);
  end;
  if FDetail.Location <> '' then
  begin
    AddLine('Directory', False);
    AddLine(FDetail.Location, True);
  end;
  if Length(FDetail.Resources) > 0 then
  begin
    AddLine('Files', False);
    for I := 0 to High(FDetail.Resources) do
      AddLine(FDetail.Resources[I], True);
  end;
  { I is used above; keep the compiler honest about the loop variable. }
  if I < 0 then
    ;
end;

procedure TSkillModal.Arrange(const ABounds: TRect);
var
  InnerW, Y, I, MetaH, BodyH: Integer;
  R: TRect;
begin
  inherited Arrange(ABounds);
  InnerW := ABounds.W - 4;
  if InnerW < 1 then
    InnerW := 1;

  { The metadata lines are drawn as plain text in Render, one row each, so the
    body starts below them. Counted here because Render needs to know where the
    container sits. }
  { Counted from the FIELDS, matching what Render draws: two rows per optional
    pair (caption + value), and the Files list takes one row plus one per entry. }
  { Built HERE, at the width it will be drawn at, so the rows Arrange reserves
    and the rows Render paints come from one source. }
  BuildMeta(InnerW);
  MetaH := Length(FMetaLines);
  Y := ABounds.Y + 1 + MetaH;
  FBodyTop := Y;

  BodyH := ABounds.Y + ABounds.H - SkillModalChromeRows - Y;
  if BodyH < 1 then
    BodyH := 1;
  R := Default(TRect);
  R.X := ABounds.X + 2;
  R.Y := Y;
  R.W := InnerW;
  R.H := BodyH;
  FBody.Arrange(R);
end;

function TSkillModal.CanLoad: Boolean;
begin
  { Nothing to do when it is already in context, and a skill with no key cannot
    be addressed. }
  Result := (not FDetail.Loaded) and (FDetail.Key <> '');
end;

function TSkillModal.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W - 6;
  if Result.W < SkillModalMinWidth then
    Result.W := AAvail.W;
  { At most 80% of the height, so the dialog never fills the frame: the
    transcript showing behind it is what says "modal". The body scrolls inside
    whatever is left. }
  Result.H := (AAvail.H * SkillModalMaxHeightPercent) div 100;
  if Result.H < SkillModalChromeRows + 3 then
    Result.H := AAvail.H;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TSkillModal.Render(const S: ISurface);
var
  L, R, T, B, Y, I, N, CtaX: Integer;
  Bg, BorderAttr, TitleAttr, LabelAttr, ValueAttr, BodyAttr: TAttr;
  Title, Cta: string;
  Spans: TSpanArray;
  BodyTop: Integer;
begin
  if (FBounds.W < 12) or (FBounds.H < SkillModalChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  { The modal is the RAISED tone; its field values and the markdown body sit one
    step darker on SUNKEN. Markdown blocks are drawn with sfScreenBg, so they
    take whatever is behind them - which is why the body needs a real fill rather
    than just darker text. Fenced code keeps its own CodeBackdrop, already one
    step darker again, so it still reads as a distinct surface. }
  Bg := OnBg(FTheme.Text, FTheme.RaisedBg);
  BorderAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  TitleAttr := OnBg(FTheme.Accent, FTheme.RaisedBg);
  LabelAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  ValueAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
  BodyAttr := OnBg(FTheme.Text, FTheme.SunkenBg);

  S.FillRect(FBounds, Bg);
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

  Title := ' skill: ' + FDetail.Name + ' ';
  PutText(S, L + 2, T, UnicodeString(Title), TitleAttr);

  Y := T + 1;
  { The metadata block, drawn from the lines BuildMeta wrapped. CAPTIONS are
    modal-tone chrome; VALUES get the sunken surface, one step darker, so the
    shape of "field / value" is legible without a border per field. The fill
    runs the width of each value row, not the whole dialog: only the content is
    inset, the modal frame stays raised. }
  for I := 0 to High(FMetaLines) do
  begin
    if Y >= B - 1 then
      Break;
    if FMetaIsValue[I] then
    begin
      S.FillRect(Rc(L + 2, Y, R - L - 3, 1), OnBg(FTheme.Text, FTheme.SunkenBg));
      PutText(S, L + 2, Y, UnicodeString(FMetaLines[I]), ValueAttr);
    end
    else
      PutText(S, L + 2, Y, UnicodeString(FMetaLines[I]), LabelAttr);
    Inc(Y);
  end;
  Inc(Y);

  { The body is the STYLED markdown view inside its scroll container, arranged
    in Arrange and drawn here. It renders headings, emphasis, code and lists
    properly and handles its own scrolling, so there is no line-splitting or
    offset arithmetic left in this unit. }
  FBody.Render(S);

  { The action row, always on the bottom border's inner row so a long body cannot
    push it away. Right-aligned to match the panel's hint row, and TWO-TONE
    through the shared splitter: the keybinding dim, the action lighter. A bare
    "loaded  esc cancel" has no key on the first segment, so HintSpans draws it
    all-action - which is right, there is no binding there. }
  if CanLoad then
    Cta := 'enter use · esc cancel'
  else if FDetail.Loaded then
    Cta := 'loaded · esc cancel'
  else
    Cta := 'esc cancel';
  { Both attrs carry the dialog's own background: PaintSpans sets only the
    foreground, so a bare colour left the row on whatever background the fill
    gave it and the CTA read as a stripe - the same bug the panel's hint row had. }
  Spans := HintSpans(UnicodeString(Cta),
    OnBg(FTheme.Muted, FTheme.RaisedBg),
    OnBg(FTheme.Text, FTheme.RaisedBg));
  CtaX := R - 1 - SpansWidth(Spans);
  if CtaX < L + 2 then
    CtaX := L + 2;
  PaintSpans(S, CtaX, B - 1, Spans);
end;

function TSkillModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
  case E.Key.Kind of
    kkEscape:
      begin
        { Dismiss changes nothing: the skill stays as it was. }
        Visible := False;
        Result := True;
      end;
    { Scrolling belongs to the container: it owns the clamp, the scrollbar and
      the wheel. Anything it does not consume is not ours. }
    kkUp, kkDown, kkPageUp, kkPageDown, kkHome, kkEnd:
      Result := FBody.HandleEvent(E);
    kkEnter:
      if CanLoad then
      begin
        Visible := False;
        if Assigned(FOnLoad) then
          FOnLoad(FDetail.Key);
        Result := True;
      end;
  else
    ;
  end;
end;

end.
