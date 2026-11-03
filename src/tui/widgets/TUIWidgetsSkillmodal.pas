unit TUIWidgetsSkillmodal;
{ The skill detail dialog: one skill's name, description, metadata, and full
  SKILL.md body - the body rendered as MARKDOWN, and the whole thing scrollable.

  The FRAME is not here. TSkillModal descends from TModal, which owns the border,
  the title, the 80% height cap and the FIXED CTA footer with its divider. This
  unit supplies only the CONTENT: the field block and the markdown body, stacked
  inside the modal's single scroll container so they scroll together.

  It BROWSES and reports; it does not load. The operator pressing "enter use"
  closes the dialog and hands the key back to the host, exactly as THistoryModal
  reports a turn id and lets the host undo. That keeps the widget free of the
  registry, the driver and the approval gate.

  Rows are handed in already resolved as a plain record of strings: HildiSkills
  uses HildiAgent, and the Process Split forbids HildiHarnessApp (and anything it
  draws with) from reaching the agent. Taking TSkill here would break the split,
  which TSplitBoundaryTest enforces. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIGrapheme,
  TUIWidgetsText, TUIWidgetsModal, TUIWidgetsMarkdownView, TUIWidgetsScroll,
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
  { One column of inline padding inside a value's sunken pane, so text never
    touches the darker background's edge. }
  SkillValuePad = 1;

type
  { The CONTENT of the skill dialog: the field block and the markdown body,
    stacked. It is what TModal scrolls.

    It is a widget rather than draw calls inside the modal because TModal takes
    ONE content widget and gives it a single scroll region. Splitting the fields
    and the body into two independently-scrolled areas is what the operator
    explicitly did not want. }
  TSkillContent = class(TWidget)
  private
    FTheme: TTheme;
    FDetail: TSkillDetail;
    FMarkdown: TMarkdownView;
    { Pre-built rows. Built in Arrange at the width they will be drawn at, so
      the height reserved and the rows painted come from ONE source - the bug the
      palette had when Measure and Render disagreed. }
    FLines: TStringArray;
    FKinds: array of Byte;      // 0 caption, 1 value, 2 gap
    FBuildWidth: Integer;
    FBodyTop: Integer;
    FBodyH: Integer;
    procedure Build(AWidth: Integer);
    function MetaRows: Integer;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    procedure SetDetail(const ADetail: TSkillDetail);
    procedure ScrollTop;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TSkillModal = class(TModal)
  private
    FContent: TSkillContent;
    FOnLoad: TSkillLoadEvent;
    function CanLoad: Boolean;
    procedure RefreshFooter;
  public
    constructor Create(const ATheme: TTheme);
    procedure SetDetail(const ADetail: TSkillDetail);
    { Echoed back when the operator activates the load CTA. }
    function DetailKey: string;
    property OnLoad: TSkillLoadEvent read FOnLoad write FOnLoad;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

{ A rect constructor. Local because each TUI unit carries its own; importing a
  unit for four lines is not worth it. }
function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ --- TSkillContent ------------------------------------------------------- }

constructor TSkillContent.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FMarkdown := TMarkdownView.Create;
  FBuildWidth := -1;
end;

destructor TSkillContent.Destroy;
begin
  FMarkdown.Free;
  inherited Destroy;
end;

procedure TSkillContent.SetDetail(const ADetail: TSkillDetail);
begin
  FDetail := ADetail;
  FMarkdown.SetSource(FDetail.Body);
  FMarkdown.FinishSource;
  { A new skill opens at the TOP: carrying the previous scroll would land the
    operator mid-way through a document they have not read. }
  FBuildWidth := -1;
end;

procedure TSkillContent.ScrollTop;
begin
  FBuildWidth := -1;
end;

procedure TSkillContent.Build(AWidth: Integer);
var
  Doc: TMdDocument;
  Rendered: TMdLineArray;

  procedure AddGap;
  begin
    SetLength(FLines, Length(FLines) + 1);
    FLines[High(FLines)] := '';
    SetLength(FKinds, Length(FKinds) + 1);
    FKinds[High(FKinds)] := 2;
  end;

  { A caption row, then the value WRAPPED as markdown so `code` and **emphasis**
    read as such rather than as their source. }
  procedure AddField(const ACaption, AValue: string);
  var
    K: Integer;
  begin
    if AValue = '' then
      Exit;
    if Length(FLines) > 0 then
      AddGap;
    SetLength(FLines, Length(FLines) + 1);
    FLines[High(FLines)] := ACaption;
    SetLength(FKinds, Length(FKinds) + 1);
    FKinds[High(FKinds)] := 0;
    Doc := ParseTree(AValue);
    try
      Rendered := RenderTree(Doc, AWidth - 2 * SkillValuePad);
    finally
      Doc.Free;
    end;
    for K := 0 to High(Rendered) do
    begin
      SetLength(FLines, Length(FLines) + 1);
      FLines[High(FLines)] := Rendered[K];
      SetLength(FKinds, Length(FKinds) + 1);
      FKinds[High(FKinds)] := 1;
    end;
  end;

  procedure AddList(const ACaption: string; const AValues: TStringArray);
  var
    K: Integer;
  begin
    if Length(AValues) = 0 then
      Exit;
    if Length(FLines) > 0 then
      AddGap;
    SetLength(FLines, Length(FLines) + 1);
    FLines[High(FLines)] := ACaption;
    SetLength(FKinds, Length(FKinds) + 1);
    FKinds[High(FKinds)] := 0;
    for K := 0 to High(AValues) do
    begin
      SetLength(FLines, Length(FLines) + 1);
      FLines[High(FLines)] := AValues[K];
      SetLength(FKinds, Length(FKinds) + 1);
      FKinds[High(FKinds)] := 1;
    end;
  end;

begin
  if AWidth = FBuildWidth then
    Exit;
  FBuildWidth := AWidth;
  FLines := nil;
  FKinds := nil;

  AddField('Description', FDetail.Description);
  AddField('License', FDetail.License);
  AddField('Compatibility', FDetail.Compatibility);
  { Labelled as not enforced: it is displayed and never consulted. }
  AddField('Allowed tools (not enforced)', FDetail.AllowedTools);
  AddField('Directory', FDetail.Location);
  AddList('Files', FDetail.Resources);
  { The prompt caption: the body below it is the skill's instructions, and naming
    them is what tells the operator the markdown is the thing that gets loaded. }
  SetLength(FLines, Length(FLines) + 1);
  FLines[High(FLines)] := 'Prompt';
  SetLength(FKinds, Length(FKinds) + 1);
  FKinds[High(FKinds)] := 0;
end;

function TSkillContent.MetaRows: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FKinds) do
    if FKinds[I] <> 0 then
      Inc(Result);   // value rows and gaps both take a row
end;

function TSkillContent.Measure(const AAvail: TSize): TSize;
var
  Sz: TSize;
begin
  Result := Default(TSize);
  if AAvail.W < 1 then
    Exit;
  Result.W := AAvail.W;
  Build(AAvail.W);
  Sz := Default(TSize);
  Sz.W := AAvail.W;
  Result.H := Length(FLines) + FMarkdown.Measure(Sz).H;
end;

procedure TSkillContent.Arrange(const ABounds: TRect);
var
  R: TRect;
  Sz: TSize;
  BodyY, BodyH: Integer;
begin
  inherited Arrange(ABounds);
  Build(ABounds.W);
  BodyY := ABounds.Y + Length(FLines);
  Sz := Default(TSize);
  Sz.W := ABounds.W;
  BodyH := FMarkdown.Measure(Sz).H;
  if BodyH < 1 then
    BodyH := 1;
  FBodyTop := BodyY;
  FBodyH := BodyH;
  R := Default(TRect);
  R.X := ABounds.X;
  R.Y := BodyY;
  R.W := ABounds.W;
  R.H := BodyH;
  FMarkdown.Arrange(R);
end;

procedure TSkillContent.Render(const S: ISurface);
var
  I, X, Y, W: Integer;
  CaptionAttr, ValueAttr, PaneAttr: TAttr;
  Line: UnicodeString;
begin
  if (FBounds.W < 4) or (FBounds.H < 1) then
    Exit;
  X := FBounds.X;
  W := FBounds.W;
  CaptionAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  ValueAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
  PaneAttr := OnBg(FTheme.Text, FTheme.SunkenBg);

  Y := FBounds.Y;
  for I := 0 to High(FLines) do
  begin
    if Y >= FBounds.Y + FBounds.H then
      Break;
    case FKinds[I] of
      0:
        { A caption is chrome on the modal's own tone. }
        PutText(S, X, Y, UnicodeString(FLines[I]), CaptionAttr);
      1:
        begin
          { A value gets the SUNKEN pane across the FULL width, with one column
            of inline padding so the text never touches the darker edge. Filling
            only the text's own width is what made earlier values look like
            coloured text rather than a field. }
          S.FillRect(Rc(X, Y, W, 1), PaneAttr);
          Line := UnicodeString(FLines[I]);
          PutText(S, X + SkillValuePad, Y, Line, ValueAttr);
        end;
      2:
        ;   // a gap row: counted, never drawn
    end;
    Inc(Y);
  end;

  { The BODY on the same sunken tone across its whole area, so the markdown reads
    as the prompt FIELD. Markdown blocks draw with sfScreenBg, so they inherit
    this fill; fenced code keeps its own CodeBackdrop one step darker again. }
  if FBodyH > 0 then
    S.FillRect(Rc(FBounds.X, FBodyTop, FBounds.W, FBodyH), PaneAttr);
  FMarkdown.Render(S);
end;

function TSkillContent.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := FMarkdown.HandleEvent(E);
end;

{ --- TSkillModal --------------------------------------------------------- }

constructor TSkillModal.Create(const ATheme: TTheme);
begin
  FContent := TSkillContent.Create(ATheme);
  { Scrollable: the field block and the body scroll together under ONE bar, and
    TModal keeps the CTA footer fixed below them. }
  inherited Create(ATheme, FContent, True);
  FOnLoad := nil;
end;

procedure TSkillModal.SetDetail(const ADetail: TSkillDetail);
begin
  FContent.SetDetail(ADetail);
  SetTitle('skill: ' + ADetail.Name);
  RefreshFooter;
end;

function TSkillModal.DetailKey: string;
begin
  Result := FContent.FDetail.Key;
end;

function TSkillModal.CanLoad: Boolean;
begin
  { Nothing to do when it is already in context, and a skill with no key cannot
    be addressed. }
  Result := (not FContent.FDetail.Loaded) and (FContent.FDetail.Key <> '');
end;

procedure TSkillModal.RefreshFooter;
begin
  { Two-tone via the modal's footer splitter. The separator is the dot, NOT two
    spaces: HintSpans joins on it, and two spaces renders the whole line flat. }
  if CanLoad then
    SetFooter('enter use · esc cancel')
  else if FContent.FDetail.Loaded then
    SetFooter('loaded · esc cancel')
  else
    SetFooter('esc cancel');
end;

function TSkillModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind = ikKey then
    case E.Key.Kind of
      kkEscape:
        begin
          { Dismiss changes nothing: the skill stays as it was. }
          Visible := False;
          Exit(True);
        end;
      kkEnter:
        if CanLoad then
        begin
          Visible := False;
          if Assigned(FOnLoad) then
            FOnLoad(FContent.FDetail.Key);
          Exit(True);
        end;
    else
      ;
    end;
  { Everything else - arrows, page keys, the wheel - goes to the scroller. }
  Result := inherited HandleEvent(E);
end;

end.
