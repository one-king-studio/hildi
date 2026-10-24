unit hildegard.helper.coordination;
{ The coordination protocol: how to behave around the board and the task list,
  and whether this session is alone.

  Why this is its own unit rather than more prose in the board's or the task
  list's stable text: those two describe TOOLS (their arguments, their kinds).
  This describes the PROTOCOL, which survives swapping the substrate. A project
  that replaces the board with something else still wants "claim before you
  change" and "record decisions, not activity".

  The mode is DETECTED, not configured. A project should not have to declare
  itself multi-agent; the workspace already knows how many runtimes are attached
  and whether this session was spawned as a child. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.sqlite, hildegard.helper.store;

type
  { cmSingle: nobody else is here, so the board is a journal and the task list is
    a personal plan. cmMulti: another live session shares this workspace, so both
    are coordination surfaces and the protocol matters. }
  TCoordinationMode = (cmSingle, cmMulti);

  { Why we believe the mode, so the prompt can be honest about it rather than
    asserting a fact it cannot support.

    The distinct reasons matter because they call for DIFFERENT behaviour even
    though two of them yield the same mode:

      crSpawnedChild  - a parent exists and decides. Coordination here is
                        dispatch; the child does not negotiate with equals.
      crPeerRuntime   - another INDEPENDENT session is live: the operator opened
                        another instance in this workspace. Peers are equals,
                        nobody decides for anyone, and a dead peer has no owner -
                        which is why liveness (not lineage) must be load-bearing.

    "Multi-agent" in this design means crPeerRuntime. Treating a spawned child as
    a peer would apply consensus rules where an owner already exists. }
  TCoordinationReason = (
    crOnlyRuntime,     // exactly one live runtime in this workspace
    crPeerRuntime,     // another INDEPENDENT session shares this workspace
    crSpawnedChild,    // this session was spawned by another (depth > 0)
    crUnknown);        // no store, or the query failed - do not guess

const
  { Both modes are described in the STABLE half. The text never changes, so it
    caches with the system prompt; only the mode line at the end varies, and it
    varies rarely. Writing only the active mode would churn the cache every time
    a peer appears. }
  CoordinationStableText =
    'This workspace may be shared: another agent now, or your future self after '
    + 'a context reset. Two things make that work, and they are separate on '
    + 'purpose.'
    + LineEnding + LineEnding
    + 'The BOARD (board_post / board_read) holds durable knowledge: decisions, '
    + 'findings, open questions, status. It is append-only - correct an entry by '
    + 'posting again with `supersedes`, never by editing, so the history '
    + 'survives. The task LIST (task_add / task_claim / task_update) holds work '
    + 'that moves: claim a card before you work on it, so a peer sees it is taken '
    + 'instead of starting it too.'
    + LineEnding + LineEnding
    + 'Four rules, whether you are alone or not:'
    + LineEnding
    + '- Claim before you change. Others see what you record, never what you '
    + 'intend.'
    + LineEnding
    + '- Trust the source over the summary. Your view of shared state can lag a '
    + 'peer''s change; when something looks wrong, read the source before '
    + 'blaming a peer. Two agents agreeing from the same stale view is not '
    + 'evidence.'
    + LineEnding
    + '- Record decisions and findings, not activity. A decision survives your '
    + 'context; a status does not.'
    + LineEnding
    + '- Before reporting done, check that your check could have failed.'
    + LineEnding
    + '- The board is for COORDINATION, not persistence. An artifact that must '
    + 'survive a fresh clone - a spec, a decision worth keeping, the docs a '
    + 'project requires - belongs in a FILE in the workspace. The board is what '
    + 'is true now; it is pruned, and it is invisible to anyone reading the repo.'
    + LineEnding + LineEnding
    + 'Here, "more than one agent" means PEER SESSIONS: the operator opening '
    + 'another instance in the same workspace. Peers are equals - nobody decides '
    + 'for anyone. (A subagent is a different thing: it has a parent that decides, '
    + 'and coordination there is dispatch, not negotiation.)'
    + LineEnding + LineEnding
    + 'If more than one agent is working here, agree protocols BEFORE you start '
    + 'and PIN them to the board as a `decision` under the topic `protocols`: '
    + 'who owns which paths, who commits and when, how you report finishing, and '
    + 'how a stuck claim gets recovered. Read that topic before your first '
    + 'change. A protocol that lives only in a conversation dies with it.';

  { The mode line, appended to the stable text. Kept short: the prose above is
    the instruction, this is only which half of it applies. }
  SingleModeText =
    'You are ALONE in this workspace. There is no peer to coordinate with: use '
    + 'the board as a journal for your future self, and the task list to keep '
    + 'your own plan visible across a context reset.';

  MultiModeText =
    'You are NOT alone: another live session shares this workspace. Treat the '
    + 'board and the task list as coordination with a peer - claim before you '
    + 'change, and read the board before assuming a file is untouched.';

  { No store means no runtimes to count. Say so rather than guess "alone". }
  UnknownModeText =
    'This workspace may be shared; nothing here can confirm whether a peer is '
    + 'active. Assume it might be, and claim before you change.';

{ How many live runtimes are attached to AWorkspaceId, and whether this session
  was itself spawned. Returns cmSingle/cmMulti plus the reason. Never raises: an
  unknown mode is reported as crUnknown, not guessed. }
function DetectCoordinationMode(const AStore: TSqliteStore;
  AWorkspaceId: Integer; const ASessionId: string;
  out APeerCount: Integer; out AReason: TCoordinationReason):
  TCoordinationMode;

{ The stable text plus the line for AMode. '' when AMode cannot be determined. }
function CoordinationPromptFor(AMode: TCoordinationMode;
  AReason: TCoordinationReason): string;

implementation

function DetectCoordinationMode(const AStore: TSqliteStore;
  AWorkspaceId: Integer; const ASessionId: string;
  out APeerCount: Integer; out AReason: TCoordinationReason):
  TCoordinationMode;
var
  Stmt: Psqlite3_stmt;
  SQL: AnsiString;
  Depth, Live: Integer;

  function OneInt(const AQuery: string; out AValue: Integer): Boolean;
  begin
    Result := False;
    AValue := 0;
    SQL := AnsiString(AQuery);
    if sqlite3_prepare_v2(AStore.Db, PAnsiChar(SQL), -1, @Stmt, nil) <>
      SQLITE_OK then
      Exit;
    try
      if sqlite3_step(Stmt) = SQLITE_ROW then
        AValue := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  end;

begin
  APeerCount := 0;
  AReason := crUnknown;
  Result := cmSingle;
  if AStore = nil then
    Exit;
  AStore.Lock.Acquire;
  try
    { depth > 0 means someone spawned this session: a parent exists by
      construction, whether or not its runtime row is still fresh. }
    if not OneInt('SELECT depth FROM sessions WHERE id = ''' +
      StringReplace(ASessionId, '''', '''''', [rfReplaceAll]) + '''', Depth) then
      Exit;
    if Depth > 0 then
    begin
      Result := cmMulti;
      AReason := crSpawnedChild;
      Exit;
    end;
    { Count the OTHER live runtimes in this workspace. The runtime table is the
      only place presence is recorded; a session row alone proves nothing, since
      a finished session keeps its row forever. }
    if not OneInt('SELECT COUNT(*) FROM session_runtimes r ' +
      'JOIN sessions s ON s.id = r.session_id ' +
      'WHERE s.workspace_id = ' + IntToStr(AWorkspaceId) +
      ' AND s.id <> ''' + StringReplace(ASessionId, '''', '''''', [rfReplaceAll])
      + '''', Live) then
      Exit;
    APeerCount := Live;
    if Live > 0 then
    begin
      Result := cmMulti;
      AReason := crPeerRuntime;
    end
    else
      AReason := crOnlyRuntime;
  finally
    AStore.Lock.Release;
  end;
end;

function CoordinationPromptFor(AMode: TCoordinationMode;
  AReason: TCoordinationReason): string;
begin
  Result := CoordinationStableText + LineEnding + LineEnding;
  if AReason = crUnknown then
    Exit(Result + UnknownModeText);
  case AMode of
    cmSingle: Result := Result + SingleModeText;
    cmMulti: Result := Result + MultiModeText;
  end;
end;

end.
