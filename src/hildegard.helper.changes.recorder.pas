unit hildegard.helper.changes.recorder;
{ The first real consumer of the change log: it hears what a tool call changed and
  writes it down.

  Before this, TFileChangeSet was built, summarised into the tool result, and
  freed. Nothing was persisted, so "what did this call do?" was answerable only
  from the one-line note and "who touched this file last?" not at all.

  The recorder is deliberately thin: it converts the in-memory set into records
  with hashes and appends them. It does not decide policy, does not prune, and
  does not block a write - the CAS check belongs to the writer, not to the
  observer. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.hash, hildegard.helper.workspace.changes,
  changes.types, changes.store, changes.text, changes.log;

type
  TChangeRecorder = class
  private
    FStore: IChangeStore;
    FWorkspaceId: Integer;
    FSessionId: string;
    FTurnId: Integer;
    FTurns: Integer;
    FRecords: Integer;
  public
    { AStore may be nil, in which case every call is a no-op: a session with no
      database records nothing, which is the honest behaviour rather than a
      failure. }
    constructor Create(const AStore: IChangeStore; AWorkspaceId: Integer;
      const ASessionId: string);
    { The loop reports each turn's id here, so a change is attributed to the turn
      it happened in - which is what the retention window and the changed-files
      view group by. }
    procedure SetTurn(ATurnId: Int64);
    { Matches TCommandChangesEvent: one call's set. }
    procedure Observe(const AChanges: TFileChangeSet);
    { True when a set would produce at least one record - a caller can use this
      to skip the work of building one. }
    function Wants: Boolean;
    property RecordsWritten: Integer read FRecords;
    property TurnsSeen: Integer read FTurns;
    property TurnId: Integer read FTurnId;
  end;

implementation

constructor TChangeRecorder.Create(const AStore: IChangeStore;
  AWorkspaceId: Integer; const ASessionId: string);
begin
  inherited Create;
  FStore := AStore;
  FWorkspaceId := AWorkspaceId;
  FSessionId := ASessionId;
  FRecords := 0;
  FTurns := 0;
  FTurnId := 0;
end;

procedure TChangeRecorder.SetTurn(ATurnId: Int64);
begin
  FTurnId := Integer(ATurnId);
end;

function TChangeRecorder.Wants: Boolean;
begin
  Result := FStore <> nil;
end;

procedure TChangeRecorder.Observe(const AChanges: TFileChangeSet);
var
  I: Integer;
  C: TFileChange;
  R: TChangeRecord;
  Id: Integer;
  Err: string;
  Kind: TChangeKind;
  Patch: string;
  Capped: Boolean;
begin
  if (FStore = nil) or (AChanges = nil) then
    Exit;
  Inc(FTurns);
  for I := 0 to AChanges.Count - 1 do
  begin
    C := AChanges[I];
    R := Default(TChangeRecord);
    R.WorkspaceId := FWorkspaceId;
    R.SessionId := FSessionId;
    R.TurnId := FTurnId;
    R.MessageId := 0;
    R.Path := C.Path;
    case C.Kind of
      fcCreated: Kind := ckCreated;
      fcDeleted: Kind := ckDeleted;
    else
      Kind := ckModified;
    end;
    R.Kind := Kind;
    { Both hashes, because they are what makes the record usable: the CAS check
      needs before, and a replay verifies against after. A side that was not
      captured still has a size, and the hash is left empty rather than faked. }
    if C.BeforeCaptured then
      R.BeforeHash := Sha256Hex(C.Before);
    if C.Captured then
      R.AfterHash := Sha256Hex(C.After);
    R.BeforeSize := C.BeforeSize;
    R.AfterSize := C.AfterSize;
    { The patch is what makes the record a change rather than a label: replay
      applies these in order, so an empty patch stops Reconstruct at that hop.
      It is built here, at the only moment both texts are in hand - the tool
      already had them, and nothing downstream can reconstruct the before-side
      from a hash. A side that was never captured has no patch, honestly. }
    R.Patch := '';
    R.PatchBytes := 0;
    R.Capped := False;
    { Initialised because the no-patch branch below never passes it as an out
      parameter, and an uninitialised local here would mark a record capped at
      random. }
    Capped := False;
    Patch := '';
    if C.Captured and (C.Kind = fcCreated) then
      { A creation's before-text is empty by definition. }
      Patch := DiffText('', C.After, DefaultPatchCapBytes, Capped)
    else if C.BeforeCaptured and (C.Kind = fcDeleted) then
      { A deletion's after-text is empty by definition. }
      Patch := DiffText(C.Before, '', DefaultPatchCapBytes, Capped)
    else if C.BeforeCaptured and C.Captured then
      Patch := DiffText(C.Before, C.After, DefaultPatchCapBytes, Capped)
    else
      Patch := '';
    R.Patch := Patch;
    R.PatchBytes := Length(Patch);
    R.Capped := Capped;
    R.Source := csTier;
    R.CreatedAt := 0;
    if not FStore.Append(R, Id, Err) then
      Continue;   // a failed append must not fail the tool call
    Inc(FRecords);
  end;
end;

end.
