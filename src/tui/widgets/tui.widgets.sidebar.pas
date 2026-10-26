unit tui.widgets.sidebar;
{ The subagent list, drawn in the COMPOSER's place and in the composer's own
  chrome: the same heavy-topped rounded box, the same raised background, the
  same lower-left info line and lower-right CTAs. Two things differ on purpose:

  - the border is AMBER (FTheme.Warn) rather than the accent, so the operator
    sees at a glance that this is not the prompt. The dashboard uses the same
    amber for a CLAIMED lane heading: "work in flight, not yours to type into";
  - where the prompt carries text, the list carries one row per child.

  Each row is the child's label (or short session id) plus its current turn
  title, so the list says what each agent is DOING, not just that it exists.

  Up/Down move the selection and the host loads the selected child into the chat
  stream (OnSelect). There is no prompt here, so the view is read-only. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, tui.base, tui.input,
  tui.surface, tui.widget,
  tui.grapheme, tui.theme,
  hildegard.helper.harness.subagent;

type
  TSubagentSelectedEvent = procedure(const ASessionId: string) of object;
  { An action key pressed while the list has focus: 'a' abort, 'r' release,
    'p' promote. The CTAs live in this box, so the keys must too. }
  TSubagentActionEvent = procedure(const AAction: Char) of object;

  TSidebar = class(TWidget)
  private
    FTheme: TTheme;
    FRoster: TSubagentRoster;
    FSelected: Integer;
    FOnSelect: TSubagentSelectedEvent;
    FOnAction: TSubagentActionEvent;
    FInfo: string;             // lower-left, as the compose shows the model
    FHints: string;            // lower-right CTAs
    FTurnTitles: TStringList;  // session id -> its current turn title
    procedure Move(ADelta: Integer);
    function StatusGlyph(AStatus: TSubagentStatus): UnicodeString;
    { The label, or a short session id when there is no label - a row must always
      be identifiable, and an empty label made every row look the same. }
    function DisplayName(const AEntry: TSubagentEntry): string;
    function RowText(const AEntry: TSubagentEntry; AWidth: Integer): UnicodeString;
  public
    constructor Create(const ATheme: TTheme; ARoster: TSubagentRoster);
    destructor Destroy; override;
    { Rebuild from the roster; call when the roster changes. }
    procedure Refresh;
    function RowCount: Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Selected: Integer read FSelected;
    property OnSelect: TSubagentSelectedEvent read FOnSelect write FOnSelect;
    { An action key pressed in the list: 'a' abort, 'r' release, 'p' promote.
      The CTAs live in this box, so the box must also read the keys. }
    property OnAction: TSubagentActionEvent read FOnAction write FOnAction;
    { The lower-left line: the session's model, exactly as the compose shows it. }
    procedure SetInfo(const AText: string);
    { The lower-right key hints. }
    procedure SetHints(const AText: string);
    { A child's current turn title, shown beside its name. '' clears it. }
    procedure SetTurnTitle(const ASessionId, ATitle: string);
  end;

implementation

constructor TSidebar.Create(const ATheme: TTheme; ARoster: TSubagentRoster);
begin
  inherited Create;
  FTheme := ATheme;
  FRoster := ARoster;
  FSelected := -1;
  FInfo := '';
  FHints := 'enter spy';
  FTurnTitles := TStringList.Create;
end;

destructor TSidebar.Destroy;
begin
  FTurnTitles.Free;
  inherited Destroy;
end;

procedure TSidebar.SetInfo(const AText: string);
begin
  FInfo := AText;
end;

procedure TSidebar.SetHints(const AText: string);
begin
  FHints := AText;
end;

procedure TSidebar.SetTurnTitle(const ASessionId, ATitle: string);
var
  I: Integer;
begin
  if ASessionId = '' then
    Exit;
  I := FTurnTitles.IndexOfName(ASessionId);
  if I >= 0 then
  begin
    if ATitle = '' then
      FTurnTitles.Delete(I)
    else
      FTurnTitles[I] := ASessionId + '=' + ATitle;
  end
  else if ATitle <> '' then
    FTurnTitles.Add(ASessionId + '=' + ATitle);
end;

procedure TSidebar.Refresh;
var
  N: Integer;
begin
  N := 0;
  if FRoster <> nil then
    N := FRoster.Count;
  if N = 0 then
    FSelected := -1
  else if (FSelected < 0) or (FSelected >= N) then
    FSelected := 0;
end;

function TSidebar.RowCount: Integer;
begin
  if FRoster = nil then
    Result := 0
  else
    Result := FRoster.Count;
end;

procedure TSidebar.Move(ADelta: Integer);
var
  N: Integer;
begin
  N := RowCount;
  if N = 0 then
  begin
    FSelected := -1;
    Exit;
  end;
  if FSelected < 0 then
  begin
    FSelected := 0;
    Exit;
  end;
  Inc(FSelected, ADelta);
  if FSelected < 0 then
    FSelected := 0;
  if FSelected > N - 1 then
    FSelected := N - 1;
end;

function TSidebar.StatusGlyph(AStatus: TSubagentStatus): UnicodeString;
begin
  case AStatus of
    ssSpawned:   Result := '·';
    ssRunning:   Result := '▶';
    ssCompleted: Result := '✓';
    ssFailed:    Result := '✗';
    ssAborted:   Result := '⊘';
    ssReleased:  Result := '→';
    ssGone:      Result := '∅';
  end;
end;

function TSidebar.DisplayName(const AEntry: TSubagentEntry): string;
begin
  if AEntry.LabelText <> '' then
    Result := AEntry.LabelText
  else if Length(AEntry.SessionId) > 8 then
    Result := Copy(AEntry.SessionId, 1, 8)
  else
    Result := AEntry.SessionId;
end;

function TSidebar.RowText(const AEntry: TSubagentEntry;
  AWidth: Integer): UnicodeString;
var
  Title: string;
  Line: UnicodeString;
  I: Integer;
begin
  { Which turn is this child on? The title is the point of the row: a list of
    bare labels says who exists, not what anyone is doing. }
  Title := '';
  I := FTurnTitles.IndexOfName(AEntry.SessionId);
  if I >= 0 then
    Title := FTurnTitles.ValueFromIndex[I];

  { `<label> - <title>`, the same separator the sessions list and the header
    use. One format wherever a session identifies itself: an operator should not
    have to learn a second one for this list.

    Built as UnicodeString throughout: mixing an AnsiString accumulator with a
    UnicodeString literal is an implicit conversion, which -Sew rejects. }
  Line := StatusGlyph(AEntry.Status) + ' ' + UnicodeString(DisplayName(AEntry));
  if Title <> '' then
    Line := Line + ' - ' + UnicodeString(Title);

  Result := Line;

  { Truncate with an ellipsis rather than cutting silently: a row that is simply
    short is indistinguishable from one that was clipped. }
  if (AWidth > 1) and (Length(Result) > AWidth) then
    Result := Copy(Result, 1, AWidth - 1) + '…';
end;

function TSidebar.Measure(const AAvail: TSize): TSize;
var
  Entries: TSubagentEntryArray;
  I, W: Integer;
begin
  { The list reports its INTRINSIC size - one row per child, as wide as the
    widest row - even though the host stretches it to the composer's box. A
    widget whose Measure simply returns AAvail can never be smaller than what it
    is given, which makes the method meaningless and hides a wrong layout. }
  Result := Default(TSize);
  if FRoster = nil then
    Exit;
  Entries := FRoster.Entries;
  Result.H := Length(Entries);
  for I := 0 to High(Entries) do
  begin
    W := StringWidth(RowText(Entries[I], MaxInt));
    if W > Result.W then
      Result.W := W;
  end;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
end;

procedure TSidebar.Render(const S: ISurface);
var
  L, R, T, B, X, Y, I, InnerW: Integer;
  Hints: UnicodeString;
  Entries: TSubagentEntryArray;
  SurfaceAttr, Border, RowAttr: TAttr;
  Line: UnicodeString;
  Key, Act: UnicodeString;
begin
  if (FBounds.W < 4) or (FBounds.H < 4) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  { The composer's own chrome, with an amber border instead of the accent. Same
    box, same background, same heavy top rule - so it reads as the same surface,
    in a state that says "read only". }
  SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border := OnBg(WithStyle(FTheme.Warn, [sfDim]), FTheme.RaisedBg);

  S.FillRect(FBounds, SurfaceAttr);

  { Heavy top, single bottom, light sides - identical to the compose. }
  PutCh(S, L, T, '╭', Border);
  PutCh(S, R, T, '╮', Border);
  PutCh(S, L, B, '╰', Border);
  PutCh(S, R, B, '╯', Border);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '═', Border);
    PutCh(S, X, B, '─', Border);
  end;
  for Y := T + 1 to B - 1 do
  begin
    PutCh(S, L, Y, '│', Border);
    PutCh(S, R, Y, '│', Border);
  end;

  InnerW := (R - 1) - (L + 2) + 1;

  { Rows live between the top border and the info/CTA line. }
  if FRoster <> nil then
    Entries := FRoster.Entries
  else
    SetLength(Entries, 0);

  Y := T + 1;
  for I := 0 to High(Entries) do
  begin
    if Y > B - 2 then
      Break;
    Line := RowText(Entries[I], InnerW);
    if I = FSelected then
      RowAttr := OnBg(WithStyle(FTheme.Warn, [sfBold]), FTheme.RaisedBg)
    else if SubagentStatusIsTerminal(Entries[I].Status) then
      RowAttr := OnBg(FTheme.Muted, FTheme.RaisedBg)
    else
      RowAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
    if I = FSelected then
      PutText(S, L + 1, Y, '▌', RowAttr);
    PutText(S, L + 2, Y, Line, RowAttr);
    Inc(Y);
  end;

  if Length(Entries) = 0 then
    PutText(S, L + 2, T + 1, 'no subagents',
      OnBg(FTheme.Muted, FTheme.RaisedBg));

  { Info line at the lower left: the session's model, as the compose shows it. }
  PutText(S, L + 2, B - 1, UnicodeString(FInfo),
    OnBg(FTheme.Muted, FTheme.RaisedBg));

  { CTAs at the lower right. The text comes from FHints - the whole point of the
    setter. It used to test FHints for emptiness and then draw a HARDCODED
    "enter spy", so the box said "enter spy" even while a child was selected and
    the real CTAs were set. Right-aligned as one string, in the amber, which is
    the compose's own convention. }
  if FHints <> '' then
  begin
    Hints := UnicodeString(FHints);
    X := R - 1 - StringWidth(Hints);
    if X > L + 3 + StringWidth(UnicodeString(FInfo)) then
      PutText(S, X, B - 1, Hints, OnBg(FTheme.Warn, FTheme.RaisedBg));
  end;
end;

function TSidebar.HandleEvent(const E: TInputEvent): Boolean;
var
  Entries: TSubagentEntryArray;
begin
  if E.Kind <> ikKey then
    Exit(False);
  case E.Key.Kind of
    kkUp:
      begin
        Move(-1);
        { Moving the selection LOADS that child into the stream: the list is a
          picker, and a picker that needs Enter to preview is a picker you have
          to operate twice. }
        if Assigned(FOnSelect) and (FSelected >= 0) and (FRoster <> nil) then
        begin
          Entries := FRoster.Entries;
          if FSelected <= High(Entries) then
            FOnSelect(Entries[FSelected].SessionId);
        end;
        Exit(True);
      end;
    kkDown:
      begin
        Move(1);
        if Assigned(FOnSelect) and (FSelected >= 0) and (FRoster <> nil) then
        begin
          Entries := FRoster.Entries;
          if FSelected <= High(Entries) then
            FOnSelect(Entries[FSelected].SessionId);
        end;
        Exit(True);
      end;
    kkHome:
      begin
        Refresh;
        FSelected := 0;
        if Assigned(FOnSelect) and (FRoster <> nil) then
        begin
          Entries := FRoster.Entries;
          if Length(Entries) > 0 then
            FOnSelect(Entries[0].SessionId);
        end;
        Exit(True);
      end;
    kkEnd:
      begin
        if RowCount > 0 then
          FSelected := RowCount - 1;
        if Assigned(FOnSelect) and (FRoster <> nil) and (FSelected >= 0) then
        begin
          Entries := FRoster.Entries;
          if FSelected <= High(Entries) then
            FOnSelect(Entries[FSelected].SessionId);
        end;
        Exit(True);
      end;
    kkEnter:
      begin
        if (FSelected >= 0) and (FRoster <> nil) then
        begin
          Entries := FRoster.Entries;
          if (FSelected <= High(Entries)) and Assigned(FOnSelect) then
            FOnSelect(Entries[FSelected].SessionId);
          Exit(True);
        end;
      end;
    kkChar:
      begin
        { The CTAs are CHORDED (ctrl+a/r/p), not bare letters. Bare 'a' and 'r'
          are one stray keystroke from aborting or releasing a child that is
          mid-work - and this list has focus while a child streams, which is
          exactly when the operator is most likely to be typing at something
          else. A chord costs one extra key and removes the accident entirely.

          Only the three chords are claimed; everything else falls through, so
          no ordinary keypress is swallowed. Ctrl+C and Ctrl+D are deliberately
          NOT used here: the shell owns them for quit and mode toggle. }
        if Assigned(FOnAction) and (Length(E.Key.Ch) = 1) and
          (moCtrl in E.Key.Mods) and
          (E.Key.Ch[1] in ['a', 'r', 'p']) then
        begin
          { Ch is a UnicodeString; the callback takes a Char, so convert
            explicitly - an implicit WideChar->Char narrowing is what -Sew
            rejects, and these are ASCII keys either way. }
          FOnAction(Char(E.Key.Ch[1]));
          Exit(True);
        end;
      end;
  else
    ;
  end;
  Result := False;
end;

end.
