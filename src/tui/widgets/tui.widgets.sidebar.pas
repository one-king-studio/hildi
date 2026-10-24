unit tui.widgets.sidebar;
{ A floating list of a session's active subagents. Up/Down move the selection,
  Enter spies on the selected child (OnSelect), Escape is left to the host. It
  is not modal: the parent view stays visible behind it.

  The rows come from a TSubagentRoster; call Refresh when the roster changes. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme,
  hildegard.helper.harness.subagent;

type
  TSubagentSelectedEvent = procedure(const ASessionId: string) of object;

  TSidebar = class(TWidget)
  private
    FTheme: TTheme;
    FRoster: TSubagentRoster;
    FSelected: Integer;
    FOnSelect: TSubagentSelectedEvent;
    procedure Move(ADelta: Integer);
    function StatusGlyph(AStatus: TSubagentStatus): UnicodeString;
    function RowText(const AEntry: TSubagentEntry): string;
  public
    constructor Create(const ATheme: TTheme; ARoster: TSubagentRoster);
    { Rebuild from the roster; call when it changes. }
    procedure Refresh;
    function RowCount: Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Selected: Integer read FSelected;
    property OnSelect: TSubagentSelectedEvent read FOnSelect write FOnSelect;
  end;

implementation

constructor TSidebar.Create(const ATheme: TTheme; ARoster: TSubagentRoster);
begin
  inherited Create;
  FTheme := ATheme;
  FRoster := ARoster;
  FSelected := -1;
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

function TSidebar.RowText(const AEntry: TSubagentEntry): string;
begin
  Result := string(StatusGlyph(AEntry.Status)) + ' ' + AEntry.LabelText;
end;

function TSidebar.Measure(const AAvail: TSize): TSize;
var
  Entries: TSubagentEntryArray;
  I, W: Integer;
begin
  Result := Default(TSize);
  if FRoster = nil then
    Exit;
  Entries := FRoster.Entries;
  Result.H := Length(Entries);
  for I := 0 to High(Entries) do
  begin
    W := Length(RowText(Entries[I]));
    if W > Result.W then
      Result.W := W;
  end;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
end;

procedure TSidebar.Render(const S: ISurface);
var
  Entries: TSubagentEntryArray;
  I, J, X: Integer;
  Line: string;
  A: TAttr;
  C: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  S.FillRect(FBounds, FTheme.Panel);
  if FRoster = nil then
    Exit;
  Entries := FRoster.Entries;
  for I := 0 to High(Entries) do
  begin
    if I >= FBounds.H then
      Break;
    Line := RowText(Entries[I]);
    A := FTheme.Text;
    { Terminal rows are dimmed; the selected row uses the accent. }
    if SubagentStatusIsTerminal(Entries[I].Status) then
      A := FTheme.Muted;
    if I = FSelected then
      A := FTheme.Accent;
    for J := 1 to Length(Line) do
    begin
      X := FBounds.X + J - 1;
      if X >= FBounds.X + FBounds.W then
        Break;
      C := Default(TCell);
      C.Ch := UnicodeString(Line[J]);
      C.Attr := A;
      S.Put(X, FBounds.Y + I, C);
    end;
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
        Exit(True);
      end;
    kkDown:
      begin
        Move(1);
        Exit(True);
      end;
    kkHome:
      begin
        Refresh;
        FSelected := 0;
        Exit(True);
      end;
    kkEnd:
      begin
        if RowCount > 0 then
          FSelected := RowCount - 1;
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
  else
    ;
  end;
  Result := False;
end;

end.
