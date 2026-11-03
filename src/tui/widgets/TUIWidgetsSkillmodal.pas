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
  TUITheme, TUIGrapheme;

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
  SkillModalMinWidth = 30;

type
  TSkillModal = class(TWidget)
  private
    FTheme: TTheme;
    FDetail: TSkillDetail;
    FScroll: Integer;
    FOnLoad: TSkillLoadEvent;
    { The body is the only unbounded part; the metadata rows are fixed. A long
      SKILL.md must scroll rather than push the CTAs off the screen. }
    function BodyRows: Integer;
    function VisibleBodyRows: Integer;
    function MaxScroll: Integer;
    procedure ScrollBy(ADelta: Integer);
    function CanLoad: Boolean;
  public
    constructor Create(const ATheme: TTheme);
    procedure SetDetail(const ADetail: TSkillDetail);
    { Echoed back when the operator activates the load CTA. }
    function DetailKey: string;
    property OnLoad: TSkillLoadEvent read FOnLoad write FOnLoad;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

constructor TSkillModal.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FScroll := 0;
end;

procedure TSkillModal.SetDetail(const ADetail: TSkillDetail);
begin
  FDetail := ADetail;
  { A new skill opens at the top; carrying the previous scroll would land the
    operator mid-way through a document they have not read. }
  FScroll := 0;
end;

function TSkillModal.DetailKey: string;
begin
  Result := FDetail.Key;
end;

function TSkillModal.BodyRows: Integer;
var
  S: TStringArray;
begin
  if FDetail.Body = '' then
    Exit(0);
  S := FDetail.Body.Split([#10]);
  Result := Length(S);
end;

function TSkillModal.VisibleBodyRows: Integer;
begin
  Result := FBounds.H - SkillModalChromeRows;
  if Result < 1 then
    Result := 1;
end;

function TSkillModal.MaxScroll: Integer;
begin
  Result := BodyRows - VisibleBodyRows;
  if Result < 0 then
    Result := 0;
end;

procedure TSkillModal.ScrollBy(ADelta: Integer);
begin
  Inc(FScroll, ADelta);
  if FScroll < 0 then
    FScroll := 0;
  if FScroll > MaxScroll then
    FScroll := MaxScroll;
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
  Result.H := AAvail.H - 4;
  if Result.H < SkillModalChromeRows + 3 then
    Result.H := AAvail.H;
end;

procedure TSkillModal.Render(const S: ISurface);
var
  L, R, T, B, Y, I, N: Integer;
  Bg, BorderAttr, TitleAttr, LabelAttr, ValueAttr, BodyAttr: TAttr;
  Lines: TStringArray;
  Line, Title, Cta: string;
  BodyTop: Integer;
begin
  if (FBounds.W < 12) or (FBounds.H < SkillModalChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  Bg := OnBg(FTheme.Panel, FTheme.RaisedBg);
  BorderAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  TitleAttr := OnBg(FTheme.Accent, FTheme.RaisedBg);
  LabelAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  ValueAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  BodyAttr := OnBg(FTheme.Text, FTheme.RaisedBg);

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
  { Optional rows are OMITTED, not blanked: an empty "License:" label tells the
    operator nothing and reads as a bug. }
  if FDetail.Description <> '' then
  begin
    PutText(S, L + 2, Y, UnicodeString('Description'), LabelAttr);
    PutText(S, L + 2, Y + 1, UnicodeString(FDetail.Description), ValueAttr);
    Inc(Y, 2);
  end;
  if FDetail.License <> '' then
  begin
    PutText(S, L + 2, Y, UnicodeString('License'), LabelAttr);
    PutText(S, L + 2, Y + 1, UnicodeString(FDetail.License), ValueAttr);
    Inc(Y, 2);
  end;
  if FDetail.Compatibility <> '' then
  begin
    PutText(S, L + 2, Y, UnicodeString('Compatibility'), LabelAttr);
    PutText(S, L + 2, Y + 1, UnicodeString(FDetail.Compatibility), ValueAttr);
    Inc(Y, 2);
  end;
  if FDetail.AllowedTools <> '' then
  begin
    { Shown with a caveat, because it is displayed but never enforced. }
    PutText(S, L + 2, Y, UnicodeString('Allowed tools (not enforced)'),
      LabelAttr);
    PutText(S, L + 2, Y + 1, UnicodeString(FDetail.AllowedTools), ValueAttr);
    Inc(Y, 2);
  end;
  if Length(FDetail.Resources) > 0 then
  begin
    PutText(S, L + 2, Y, UnicodeString('Files'), LabelAttr);
    Inc(Y);
    for I := 0 to High(FDetail.Resources) do
    begin
      if Y >= B - 1 then
        Break;
      PutText(S, L + 4, Y, UnicodeString(FDetail.Resources[I]), ValueAttr);
      Inc(Y);
    end;
  end;

  { The body, clipped to what is left and scrolled. }
  BodyTop := Y + 1;
  if (FDetail.Body <> '') and (BodyTop < B - 1) then
  begin
    Lines := FDetail.Body.Split([#10]);
    N := 0;
    I := FScroll;
    while (I <= High(Lines)) and (BodyTop + N < B - 1) do
    begin
      Line := Lines[I];
      PutText(S, L + 2, BodyTop + N, UnicodeString(Line), BodyAttr);
      Inc(I);
      Inc(N);
    end;
  end;

  { The CTA row, always on the bottom border's inner row so a long body cannot
    push it away. }
  if CanLoad then
    Cta := ' enter: load   esc: dismiss '
  else if FDetail.Loaded then
    Cta := ' loaded   esc: dismiss '
  else
    Cta := ' esc: dismiss ';
  PutText(S, L + 2, B - 1, UnicodeString(Cta), LabelAttr);
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
    kkUp: begin ScrollBy(-1); Result := True; end;
    kkDown: begin ScrollBy(1); Result := True; end;
    kkPageUp: begin ScrollBy(-VisibleBodyRows); Result := True; end;
    kkPageDown: begin ScrollBy(VisibleBodyRows); Result := True; end;
    kkHome: begin FScroll := 0; Result := True; end;
    kkEnd: begin FScroll := MaxScroll; Result := True; end;
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
