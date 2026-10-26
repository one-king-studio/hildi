unit changes.store;
{ Persistence for the change log, supplied by the consumer.

  The library never opens a database. The harness's SQLite store implements this
  interface; TMemoryChangeStore here makes the whole library testable with no
  database at all, and lets it be lifted into another project. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  changes.types;

type
  IChangeStore = interface
    ['{6F1D2E4C-8A3B-4C5D-9E7F-0A1B2C3D4E5F}']
    { Append one transition, assigning its Id. }
    function Append(const ARecord: TChangeRecord; out AId: Integer;
      out AError: string): Boolean;
    { A path's changes in ascending id order, from AFromId (0 => the start),
      at most ALimit (0 => all). }
    function ForPath(AWorkspaceId: Integer; const APath: string;
      AFromId, ALimit: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    { The newest change for a path. AFound is False when there is none, which is
      not an error: it is a path nobody has recorded. }
    function Latest(AWorkspaceId: Integer; const APath: string;
      out ARow: TChangeRecord; out AFound: Boolean;
      out AError: string): Boolean;
    { Every change after AFromId whose path is one of APaths, ascending. Used by
      the board's staleness rule and an activity view. }
    function Touching(AWorkspaceId: Integer; const APaths: TStringArrayLite;
      AFromId: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    { Every change recorded for one turn, ascending id (write order). A turn
      that changed nothing and a turn id that never existed are the same answer
      here - no rows, and not an error - because the caller renders "nothing
      changed" the same way either way. }
    function ForTurn(AWorkspaceId, ATurnId: Integer;
      out ARows: TChangeRecordArray; out AError: string): Boolean;
    { Every change recorded by any of ASessionIds, ascending id.

      A delegating turn's work is recorded under its CHILD session's turn, so
      ForTurn(parentTurn) cannot see it. Reverting a decision therefore needs the
      parent's rows plus its children's - which is what this answers, one query
      for the whole lineage rather than one per session. }
    function ForSessions(AWorkspaceId: Integer;
      const ASessionIds: TStringArrayLite; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    { Anchor a row to the tool-result message that caused it, AFTER the fact.

      The row is written while the tool is still running, so its message id is
      not knowable yet - the tool-result row does not exist. Stamping it later is
      what lets a diff sit under the tool block that produced it.

      A row that is no longer there (pruned between the write and the anchor) is
      a no-op returning True: it is a normal race, not a failure. }
    function SetMessageId(AWorkspaceId, AChangeId, AMessageId: Integer;
      out AError: string): Boolean;
    { Mark every row belonging to a turn as no longer in effect, or (with
      ARevertedAt = 0) back in effect.

      An undone turn is soft-deleted: the turn row is marked tsUndone and its
      messages stop being composed into the context. Its change rows must be
      marked too, or the history dialog would offer a turn whose files are
      already back at the pre-turn state - and reverting it again would be
      refused by the CAS with a confusing conflict rather than "already undone".

      The timestamp is a parameter rather than read here so that a redo can
      CLEAR the mark (pass 0): a redone turn's files are in effect again. One
      member doing both keeps the two directions from disagreeing about what the
      column means.

      Idempotent in both directions. }
    function MarkReverted(AWorkspaceId, ATurnId: Integer; ARevertedAt: Int64;
      out AError: string): Boolean;
    { The newest keyframe at or before AChangeId for a path. }
    function KeyframeBefore(AWorkspaceId: Integer; const APath: string;
      AChangeId: Integer; out AFrame: TKeyframe; out AFound: Boolean;
      out AError: string): Boolean;
    function PutKeyframe(const AFrame: TKeyframe; out AError: string): Boolean;
    { Drop everything before AKeepFromId, keeping the newest keyframe at or
      before that point so the oldest surviving change is still reconstructable. }
    function Prune(AWorkspaceId, AKeepFromId: Integer;
      out AError: string): Boolean;
    { Retention in the unit the operator reasons about: keep the newest
      AKeepTurns distinct turns and drop everything older. Done in the store
      because the answer is a MIN(turn_id) the store can compute, not an array
      the caller has to read first. }
    function PruneByTurns(AWorkspaceId, AKeepTurns: Integer;
      out AError: string): Boolean;
    { Ids are per-workspace-monotonic; a consumer that stores globally can ignore
      this and use its own. }
    function NextId: Integer;
  end;

  { An in-memory store. Complete, so every rule in changes.log can be tested
    without a database; also useful for a consumer that wants no persistence. }
  TMemoryChangeStore = class(TInterfacedObject, IChangeStore)
  private
    FRecords: TChangeRecordArray;
    FKeyframes: array of TKeyframe;
    FLastKeyframeId: Integer;
    function GetCount: Integer;
    function GetRecord(AIndex: Integer): TChangeRecord;
  public
    destructor Destroy; override;
    function Append(const ARecord: TChangeRecord; out AId: Integer;
      out AError: string): Boolean;
    function ForPath(AWorkspaceId: Integer; const APath: string;
      AFromId, ALimit: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    function Latest(AWorkspaceId: Integer; const APath: string;
      out ARow: TChangeRecord; out AFound: Boolean;
      out AError: string): Boolean;
    function Touching(AWorkspaceId: Integer; const APaths: TStringArrayLite;
      AFromId: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    function ForTurn(AWorkspaceId, ATurnId: Integer;
      out ARows: TChangeRecordArray; out AError: string): Boolean;
    function ForSessions(AWorkspaceId: Integer;
      const ASessionIds: TStringArrayLite; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    function SetMessageId(AWorkspaceId, AChangeId, AMessageId: Integer;
      out AError: string): Boolean;
    function MarkReverted(AWorkspaceId, ATurnId: Integer; ARevertedAt: Int64;
      out AError: string): Boolean;
    function KeyframeBefore(AWorkspaceId: Integer; const APath: string;
      AChangeId: Integer; out AFrame: TKeyframe; out AFound: Boolean;
      out AError: string): Boolean;
    function PutKeyframe(const AFrame: TKeyframe; out AError: string): Boolean;
    function Prune(AWorkspaceId, AKeepFromId: Integer;
      out AError: string): Boolean;
    function PruneByTurns(AWorkspaceId, AKeepTurns: Integer;
      out AError: string): Boolean;
    function NextId: Integer;
    property Count: Integer read GetCount;
    property Records[AIndex: Integer]: TChangeRecord read GetRecord;
  end;

implementation

{ --- TMemoryChangeStore ------------------------------------------------ }

destructor TMemoryChangeStore.Destroy;
begin
  FRecords := nil;
  FKeyframes := nil;
  inherited Destroy;
end;

function TMemoryChangeStore.GetCount: Integer;
begin
  Result := Length(FRecords);
end;

function TMemoryChangeStore.GetRecord(AIndex: Integer): TChangeRecord;
begin
  Result := FRecords[AIndex];
end;

function TMemoryChangeStore.NextId: Integer;
begin
  if Length(FRecords) = 0 then
    Result := 1
  else
    Result := FRecords[High(FRecords)].Id + 1;
end;

function TMemoryChangeStore.Append(const ARecord: TChangeRecord;
  out AId: Integer; out AError: string): Boolean;
var
  R: TChangeRecord;
begin
  AError := '';
  R := ARecord;
  R.Id := NextId;
  SetLength(FRecords, Length(FRecords) + 1);
  FRecords[High(FRecords)] := R;
  AId := R.Id;
  Result := True;
end;

function TMemoryChangeStore.ForPath(AWorkspaceId: Integer; const APath: string;
  AFromId, ALimit: Integer; out ARows: TChangeRecordArray;
  out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  ARows := nil;
  for I := 0 to High(FRecords) do
    if (FRecords[I].WorkspaceId = AWorkspaceId) and
      (FRecords[I].Path = APath) and (FRecords[I].Id >= AFromId) then
    begin
      SetLength(ARows, Length(ARows) + 1);
      ARows[High(ARows)] := FRecords[I];
      if (ALimit > 0) and (Length(ARows) >= ALimit) then
        Break;
    end;
  Result := True;
end;

function TMemoryChangeStore.Latest(AWorkspaceId: Integer; const APath: string;
  out ARow: TChangeRecord; out AFound: Boolean; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  ARow := Default(TChangeRecord);
  AFound := False;
  for I := High(FRecords) downto 0 do
    if (FRecords[I].WorkspaceId = AWorkspaceId) and
      (FRecords[I].Path = APath) then
    begin
      ARow := FRecords[I];
      AFound := True;
      Break;
    end;
  Result := True;
end;

function TMemoryChangeStore.Touching(AWorkspaceId: Integer;
  const APaths: TStringArrayLite; AFromId: Integer;
  out ARows: TChangeRecordArray; out AError: string): Boolean;
var
  I, K: Integer;
  Hit: Boolean;
begin
  AError := '';
  ARows := nil;
  for I := 0 to High(FRecords) do
  begin
    if (FRecords[I].WorkspaceId <> AWorkspaceId) or
      (FRecords[I].Id < AFromId) then
      Continue;
    Hit := False;
    for K := 0 to High(APaths) do
      if FRecords[I].Path = APaths[K] then
      begin
        Hit := True;
        Break;
      end;
    if Hit then
    begin
      SetLength(ARows, Length(ARows) + 1);
      ARows[High(ARows)] := FRecords[I];
    end;
  end;
  Result := True;
end;

function TMemoryChangeStore.ForTurn(AWorkspaceId, ATurnId: Integer;
  out ARows: TChangeRecordArray; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  ARows := nil;
  for I := 0 to High(FRecords) do
  begin
    if (FRecords[I].WorkspaceId <> AWorkspaceId) or
      (FRecords[I].TurnId <> ATurnId) then
      Continue;
    SetLength(ARows, Length(ARows) + 1);
    ARows[High(ARows)] := FRecords[I];
  end;
  Result := True;
end;

function TMemoryChangeStore.ForSessions(AWorkspaceId: Integer;
  const ASessionIds: TStringArrayLite; out ARows: TChangeRecordArray;
  out AError: string): Boolean;
var
  I, K: Integer;
  Hit: Boolean;
begin
  AError := '';
  ARows := nil;
  for I := 0 to High(FRecords) do
  begin
    if FRecords[I].WorkspaceId <> AWorkspaceId then
      Continue;
    Hit := False;
    for K := 0 to High(ASessionIds) do
      if FRecords[I].SessionId = ASessionIds[K] then
      begin
        Hit := True;
        Break;
      end;
    if not Hit then
      Continue;
    SetLength(ARows, Length(ARows) + 1);
    ARows[High(ARows)] := FRecords[I];
  end;
  Result := True;
end;

function TMemoryChangeStore.SetMessageId(AWorkspaceId, AChangeId,
  AMessageId: Integer; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  for I := 0 to High(FRecords) do
    if (FRecords[I].WorkspaceId = AWorkspaceId) and
      (FRecords[I].Id = AChangeId) then
    begin
      FRecords[I].MessageId := AMessageId;
      Break;
    end;
  { A row that is gone is a race, not a failure. }
  Result := True;
end;

function TMemoryChangeStore.MarkReverted(AWorkspaceId, ATurnId: Integer;
  ARevertedAt: Int64; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  for I := 0 to High(FRecords) do
    if (FRecords[I].WorkspaceId = AWorkspaceId) and
      (FRecords[I].TurnId = ATurnId) then
      FRecords[I].RevertedAt := ARevertedAt;
  { A turn with no rows kept nothing to mark - not a failure. }
  Result := True;
end;

function TMemoryChangeStore.KeyframeBefore(AWorkspaceId: Integer;
  const APath: string; AChangeId: Integer; out AFrame: TKeyframe;
  out AFound: Boolean; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  AFrame := Default(TKeyframe);
  AFound := False;
  for I := High(FKeyframes) downto 0 do
    if (FKeyframes[I].WorkspaceId = AWorkspaceId) and
      (FKeyframes[I].Path = APath) and
      (FKeyframes[I].ThroughChangeId <= AChangeId) then
    begin
      AFrame := FKeyframes[I];
      AFound := True;
      Break;
    end;
  Result := True;
end;

function TMemoryChangeStore.PutKeyframe(const AFrame: TKeyframe;
  out AError: string): Boolean;
var
  F: TKeyframe;
begin
  AError := '';
  F := AFrame;
  if F.Id = 0 then
    F.Id := Length(FKeyframes) + 1;
  SetLength(FKeyframes, Length(FKeyframes) + 1);
  FKeyframes[High(FKeyframes)] := F;
  Result := True;
end;

function TMemoryChangeStore.PruneByTurns(AWorkspaceId, AKeepTurns: Integer;
  out AError: string): Boolean;
var
  Turns: array of Integer;
  I, J, N, KeepFrom: Integer;
  Sorted: Boolean;
  Tmp: Integer;
begin
  AError := '';
  Turns := nil;
  N := 0;
  { The distinct turn ids for this workspace, newest first. }
  for I := High(FRecords) downto 0 do
  begin
    if FRecords[I].WorkspaceId <> AWorkspaceId then
      Continue;
    Sorted := False;
    for J := 0 to N - 1 do
      if Turns[J] = FRecords[I].TurnId then
      begin
        Sorted := True;
        Break;
      end;
    if Sorted then
      Continue;
    SetLength(Turns, N + 1);
    Turns[N] := FRecords[I].TurnId;
    Inc(N);
  end;
  if (AKeepTurns <= 0) or (N <= AKeepTurns) then
  begin
    Result := True;
    Exit;
  end;
  { Descending by construction (iterated newest first), but sort defensively:
    a caller may insert records out of turn order. }
  for I := 1 to N - 1 do
  begin
    J := I;
    while (J > 0) and (Turns[J] > Turns[J - 1]) do
    begin
      Tmp := Turns[J];
      Turns[J] := Turns[J - 1];
      Turns[J - 1] := Tmp;
      Dec(J);
    end;
  end;
  { Everything older than the AKeepTurns-th newest turn is dropped. Ids are
    per-workspace monotonic, so the boundary is "turn id < this one". }
  KeepFrom := 0;
  for I := 0 to High(FRecords) do
    if (FRecords[I].WorkspaceId = AWorkspaceId) and
      (FRecords[I].TurnId = Turns[AKeepTurns]) then
    begin
      KeepFrom := FRecords[I].Id;
      Break;
    end;
  if KeepFrom = 0 then
  begin
    Result := True;
    Exit;
  end;
  Result := Prune(AWorkspaceId, KeepFrom, AError);
end;

function TMemoryChangeStore.Prune(AWorkspaceId, AKeepFromId: Integer;
  out AError: string): Boolean;
var
  Kept: TChangeRecordArray;
  KeptFrames: array of TKeyframe;
  I, K: Integer;
  Best: TKeyframe;
  HaveBest: Boolean;
begin
  AError := '';
  { A store with no retention is a store that grows without bound; this is the
    library's only deletion path. }
  Kept := nil;
  for I := 0 to High(FRecords) do
    if (FRecords[I].WorkspaceId <> AWorkspaceId) or
      (FRecords[I].Id >= AKeepFromId) then
    begin
      SetLength(Kept, Length(Kept) + 1);
      Kept[High(Kept)] := FRecords[I];
    end;
  FRecords := Kept;

  { Keep the newest keyframe at or before the horizon, and anything newer, so the
    oldest surviving change can still be reconstructed. }
  HaveBest := False;
  Best := Default(TKeyframe);
  for K := 0 to High(FKeyframes) do
    if (FKeyframes[K].WorkspaceId = AWorkspaceId) and
      (FKeyframes[K].ThroughChangeId < AKeepFromId) then
      if (not HaveBest) or
        (FKeyframes[K].ThroughChangeId > Best.ThroughChangeId) then
      begin
        Best := FKeyframes[K];
        HaveBest := True;
      end;

  KeptFrames := nil;
  for K := 0 to High(FKeyframes) do
  begin
    if (FKeyframes[K].WorkspaceId <> AWorkspaceId) or
      (FKeyframes[K].ThroughChangeId >= AKeepFromId) or
      (HaveBest and (FKeyframes[K].Id = Best.Id)) then
    begin
      SetLength(KeptFrames, Length(KeptFrames) + 1);
      KeptFrames[High(KeptFrames)] := FKeyframes[K];
    end;
  end;
  SetLength(FKeyframes, Length(KeptFrames));
  for K := 0 to High(KeptFrames) do
    FKeyframes[K] := KeptFrames[K];
  Result := True;
end;

end.
