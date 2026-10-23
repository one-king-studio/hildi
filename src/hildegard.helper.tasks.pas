unit hildegard.helper.tasks;
{ The shared task list: mutable cards with a claim.

  By contrast with the board, a card's STATUS changes and the change is the
  point. That is why this is a separate feature with its own table: a board entry
  is an append-only fact, and one table cannot hold both disciplines.

  Nothing here knows about SQLite: persistence is ITaskStore, supplied by the
  consumer, the same seam the changes library and the board use. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TTaskStatus = (tsOpen, tsClaimed, tsBlocked, tsDone, tsDropped);

  { What a blocked card waits on. A card is work; a board question is an answer
    someone owes. The kind is explicit because an id alone cannot say which table
    it names, and guessing from a shared id space resolves to the wrong thing the
    first time the two disagree. }
  TBlockerKind = (tbkNone, tbkCard, tbkQuestion);

const
  TaskStatusNames: array[TTaskStatus] of string = (
    'open', 'claimed', 'blocked', 'done', 'dropped');
  BlockerKindNames: array[TBlockerKind] of string = (
    'none', 'card', 'question');

  { Retention: finished cards only. Live state is never pruned. }
  DefaultTaskKeepDone = 200;
  DefaultTaskDoneMaxAgeSec = 30 * 24 * 60 * 60;   // 30 days
  { A blocked card is worth surfacing in the tail after this long. }
  StaleBlockMinutes = 30;

  { How long a claim may go unrenewed before another turn boundary reclaims it.
    Deliberately generous: a claim is renewed at every turn boundary, so this only
    fires for a session that genuinely stopped. Longer than the slowest plausible
    turn, shorter than the interval at which a human notices a stuck card. }
  DefaultClaimLeaseSec = 30 * 60;

const
  { The explanation rides the stable half of the prompt, like the board's: the
    <tasks> element is data only, so a model that has never seen the task list
    needs to be told what it is. This text is identical on every request, so it
    caches with the system prompt instead of riding the turn. }
  TaskStableText =
    'This workspace has a task list: durable work shared with any other agent '
    + 'here, and with your future self after a context reset. Claim a card '
    + 'before you work on it (task_claim) so others can see it is taken; move '
    + 'it with task_update (release, block, unblock, done, drop). Every status '
    + 'change records who made it, so status is not editable - use a verb. The '
    + '<tasks> element in your turn shows what you hold and what is open.';

type
  TTaskCard = record
    Id: Integer;
    WorkspaceId: Integer;
    Title: string;             // required, one line
    Body: string;              // optional: acceptance criteria, context
    Status: TTaskStatus;
    ClaimedBy: string;         // a session id; '' when unclaimed
    ClaimedAt: Int64;
    StatusAt: Int64;           // when it entered its current status
    BlockedOnId: Integer;      // 0 => not blocked
    BlockedOnKind: TBlockerKind;
    Parent: Integer;           // 0 => top level; ONE level of nesting
    Position: Integer;         // manual order within its column
    FromSession, FromLabel: string;
    DoneNote: string;          // the summary or the drop reason
    CreatedAt, UpdatedAt: Int64;
  end;

  TTaskCardArray = array of TTaskCard;

  TTaskFilter = record
    Status: TTaskStatus;
    StatusSet: Boolean;        // False => any status
    Mine: Boolean;             // only cards claimed by the asking session
    MineSession: string;       // the id Mine compares against
    Parent: Integer;           // 0 => any; >0 => that card's subtasks
    Limit: Integer;            // 0 => default
  end;

function TaskStatusFromName(const AName: string; out AStatus: TTaskStatus):
  Boolean;
function TaskStatusToName(AStatus: TTaskStatus): string;
function TaskStatusList: string;
function BlockerKindToName(AKind: TBlockerKind): string;
{ True when AFrom -> ATo is a legal transition. Task_List_v1.SPEC.md's table. }
function IsLegalTransition(AFrom, ATo: TTaskStatus): Boolean;
{ The verbs a status offers, for an error message that teaches. }
function LegalTransitionsFrom(AFrom: TTaskStatus): string;

implementation

function TaskStatusToName(AStatus: TTaskStatus): string;
begin
  Result := TaskStatusNames[AStatus];
end;

function TaskStatusFromName(const AName: string; out AStatus: TTaskStatus):
  Boolean;
var
  S: TTaskStatus;
begin
  Result := False;
  AStatus := tsOpen;
  for S := Low(TTaskStatus) to High(TTaskStatus) do
    if SameText(AName, TaskStatusNames[S]) then
    begin
      AStatus := S;
      Exit(True);
    end;
end;

function TaskStatusList: string;
var
  S: TTaskStatus;
begin
  Result := '';
  for S := Low(TTaskStatus) to High(TTaskStatus) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + TaskStatusNames[S];
  end;
end;

function BlockerKindToName(AKind: TBlockerKind): string;
begin
  Result := BlockerKindNames[AKind];
end;

function IsLegalTransition(AFrom, ATo: TTaskStatus): Boolean;
begin
  { Every transition goes through a verb with an actor, so the row can answer
    "who moved this and why". A free-form status write would lose that, which is
    why task_edit cannot change status. }
  case AFrom of
    tsOpen:     Result := ATo in [tsClaimed, tsDropped];
    tsClaimed:  Result := ATo in [tsOpen, tsBlocked, tsDone, tsDropped];
    tsBlocked:  Result := ATo in [tsClaimed, tsDropped];
    tsDone:     Result := False;      // a finished card is finished
    tsDropped:  Result := False;      // a dropped card is dropped
  end;
end;

function LegalTransitionsFrom(AFrom: TTaskStatus): string;
var
  T: TTaskStatus;
begin
  Result := '';
  for T := Low(TTaskStatus) to High(TTaskStatus) do
    if IsLegalTransition(AFrom, T) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + TaskStatusNames[T];
    end;
  if Result = '' then
    Result := 'none (a finished card is terminal)';
end;

end.
