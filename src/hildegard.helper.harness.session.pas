unit hildegard.helper.harness.session;
{ Owns the agent-side object graph for one session: the session view (workspace,
  store, identity, history, metrics) plus the LLM client, the tool registry
  (builtins and gated run_command), the approval service, the turn queue/gate,
  and the agent loop.

  Used by the headless runtime. A UI client uses hildegard.helper.harness.view
  instead, so it links no agent, tools, or conversation store. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils,
  async.base, async.scheduler, async.concurrency,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.skills,
  hildegard.helper.approval,
  hildegard.helper.approval.store, hildegard.helper.command.tool,
  hildegard.helper.files,
  hildegard.helper.session, hildegard.helper.session.store,
  hildegard.helper.store,
  changes.types, changes.store, hildegard.helper.changes.store,
  hildegard.helper.changes.recorder, hildegard.helper.changes.revert,
  changes.log, hildegard.helper.hash,
  hildegard.helper.board, hildegard.helper.board.store,
  hildegard.helper.board.tools,
  hildegard.helper.tasks, hildegard.helper.tasks.store,
  hildegard.helper.tasks.tools,
  hildegard.helper.coordination,
  hildegard.helper.workspace.changes,
  hildegard.helper.recall.tool, hildegard.helper.harness.turn,
  hildegard.helper.harness.view,
  hildegard.helper.mcp.config, hildegard.helper.mcp.client,
  hildegard.helper.mcp.transport, hildegard.helper.mcp.oauth.flow,
  hildegard.helper.shell.commands, hildegard.helper.shell.tier,
  hildegard.helper.shell.executor;
type
  { The loop side of one session. Owns a TSessionView for the workspace, store,
    identity, history, and metrics. Not thread-safe except that Queue/Gate are
    safe across the worker/UI boundary. Call Close (or Free) to release
    everything. }
  THarnessSession = class
  private
    FView: TSessionView;
    FConversation: IConversationStore;
    FClient: TLLMClient;
    FTools: TToolRegistry;
    FCommandTool: TCommandTool;
    FFileTool: TFileTool;
    FRecallTool: TRecallTool;
    FMcp: TMcpManager;
    FMcpTokenProviders: TObjectList;
    { The skill registry: the capability layer (manifest + load_skill + decay).
      Empty by default; Lazy_MCP fills it with one skill per MCP server. Held as
      the interface it is handed to the loop as (the owning ref), so it is freed
      by refcount, never by a raw Free. }
    FSkills: TSkillRegistry;
    FSkillsKeep: IToolProvider;
    { The change-log recorder: hears what a tool call changed and writes it down.
      Nil when the session has no store, so a database-less session records
      nothing rather than failing. }
    FRecorder: TChangeRecorder;
    { The board: durable knowledge. Nil without a store. }
    FBoardStore: IBoardStore;
    FBoardTools: TBoardTools;
    { The task list: mutable shared work. Nil without a store. Needs the board
      too, because a card may be blocked on a board question. }
    FTaskStore: ITaskStore;
    FTaskTools: TTaskTool;
    { The last unread count this session was notified of. The read cursor only
      advances on an actual board_read, so without this every tick would
      re-announce the same post forever. }
    FLastBoardNotice: Integer;
    { The revival notice fires ONCE, on the first board tick of this session. A
      session that was away must be told, but re-telling it every tick would be
      noise - and the fact does not change while the session runs. }
    FRevivalChecked: Boolean;
    { The coordination mode observed at the last board tick. A TRANSITION between
      single and multi raises one ambient notice, so an agent switches behaviour
      mid-session rather than continuing to act alone after a peer arrives.

      TModeKnown separates "never checked" from "checked and found single" - the
      first tick must not announce a transition from nowhere. }
    FLastMode: TCoordinationMode;
    FModeKnown: Boolean;
    FChangeStore: IChangeStore;
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    FGate: TApprovalGate;
    { The shared turn pool: one bounded executor for the session, so turns reuse
      threads instead of spawning and joining a TThread per turn. }
    FTurnPool: IAsyncScheduler;
    { The pool for parallel tool calls, separate from FTurnPool (the turn
      occupies a turn-pool worker while its tools run). }
    FToolPool: IAsyncScheduler;
    FApprovalService: IApprovalService;
    { MCP events (server failure etc.) are recorded as session errors. }
    procedure McpEvent(const AMessage, ADetail: string);
    { Rebuild the STABLE half of the system prompt: skill descriptions, then the
      board's and the task list's explanations. One function because two callers
      - Init and every MCP reconcile - must agree; when the reconcile assigned
      StableText alone it silently dropped the board prose on every session that
      had a store. }
    procedure ComposeStablePrompt;
    { Resolves a board question for a `blocked_on` that names one. The task list
      must not depend on the board unit, so the check is injected; only a live
      `question` entry counts, never a note or a decision. }
    function TaskQuestionExists(AWorkspaceId, AId: Integer;
      out ATitle: string): Boolean;
    { The builtin shell tier's `tool`/`mcp` dispatch: the normal resolution
      (the base registry, then the MCP manager), so every dispatched tool still
      passes its own gate. }
    function InvokeShellTool(const AName, AArgumentsJson, AReason: string;
      out AResult, AError: string): Boolean;
    { The change-log sink: what a run_command call changed, handed to the
      recorder. Matches TCommandChangesEvent. }
    procedure RecordChanges(const AChanges: TFileChangeSet;
      const AToolCallId: string);
    { The loop reports its turn id here, so changes are attributed to a turn. }
    procedure NoteTurnOpened(ATurnId: Int64);
    { The loop reports the turn as terminal here, so the fold is flushed and the
      summary is complete when the turn ends - not when the next one opens. }
    procedure NoteTurnFinished(ATurnId: Int64);
    { At each turn boundary, re-declare the MCP skills from the current config so
      a server added/enabled/removed is picked up without a restart. Lazy: it
      declares, it does not connect. }
    procedure ReconcileMcpSkills;
    { The current effective MCP config from the store, for the provider. }
    function McpConfigSource: TMcpConfig;
    { A token source for a server with a stored OAuth token (or nil). }
    function McpTokenSourceFor(const AServer: TMcpServerConfig): TMcpTokenSource;
    function Init(const AConfig: THarnessSessionConfig; out AError: string):
      Boolean;
  public
    { Opens the session view and builds the tools, approvals, and loop. Returns
      nil with AError on failure. }
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): THarnessSession;
    destructor Destroy; override;

    { The client-side view: identity, store, history, and metrics. }
    property View: TSessionView read FView;
    property Loop: TAgentLoop read FLoop;
    { Anchor the change rows written by the tool call AToolCallId to the message
      row it produced, so a diff can be shown under the call that made it. The
      rows exist already; the message may not, which is why the runtime calls this
      after the tool result rather than the tool calling it during the run. }
    procedure AnchorChanges(const AToolCallId: string);
    { Undo one turn: revert the files it changed AND rewind the transcript to
      before it. The two halves must move together, or the transcript and the
      workspace disagree - which is the failure this feature exists to prevent.

      Order is deliberate: FILES FIRST, then messages. If the revert refuses
      (a file moved on since), nothing is lost - the transcript is still there
      and says what happened. Deleting messages first and then failing to revert
      would destroy the record of work that is still on disk.

      Refused while a turn is in flight: the runtime holds the workspace, so a
      revert underneath it has no correct resolution. Refused too when any of the
      turn's changes cannot be reverted at all - rewinding the transcript would
      hide a turn whose files are still changed, the lie in the other direction.
      ADetail says which refusal, naming the path. }
    function UndoTurn(ATurnId: Int64; out ADetail: string): Boolean;
    { One turn of a cumulative undo: revert its files and rewind its messages,
      all-or-nothing. Called newest-first by UndoTurn, because each revert
      compares against that turn's AfterHash and only holds once the later turns
      are already undone. }
    function UndoOneTurn(ATurnId: Int64; out ADetail: string): Boolean;
    { Redo: re-apply the turns an undo took away, OLDEST first.

      The mirror of UndoTurn, and the reason the order flips: undo walks newest
      first so each revert finds the file at its AfterHash; redo walks oldest
      first so each apply finds the file at its BeforeHash. Both directions rely
      on the same trick - the turn you are moving is always the one whose
      precondition currently holds.

      A turn is redone by restoring its status to tsCompleted, which is what
      brings its messages back into the context: the Compose filter excludes
      tsUndone and nothing else, so redo needs no message surgery.

      Redo is only meaningful for the turns the most recent undo took away, so a
      prompt closes the window (the operator abandoned the future by doing new
      work). This does not enforce that - it redoes the requested suffix - but
      the caller is expected to offer only that suffix. }
    function RedoTurn(ATurnId: Int64; out ADetail: string): Boolean;
    { The oldest turn that is actually redoable: undone AND above the redo floor.
      0 when the window is empty. This is what a bare `/redo` means, and it lives
      here so the local driver and the runtime cannot disagree about it - picking
      the oldest undone turn without the floor would select an abandoned turn and
      then refuse, even when a later turn is genuinely redoable. }
    function OldestRedoableTurn: Int64;
    { Notice any board entries this session has not seen, coalesced into ONE
      transient prompt item so ten agents posting is O(ticks), not O(entries).
      Called by the runtime on its tick. Returns the count noticed. }
    function NoticeBoard: Integer;
    { One-shot revival notice: says how long this session was away, whether the
      board was pruned, what is readable now, and which of its claims were
      recovered while it was gone. Called once, from the first board tick. }
    procedure NoticeRevival;
    property Tools: TToolRegistry read FTools;
    property Queue: TTurnQueue read FQueue;
    property Gate: TApprovalGate read FGate;
    { The shared executor the turn worker runs on. }
    property TurnPool: IAsyncScheduler read FTurnPool;
    { The capability layer: skills load on demand; empty unless Lazy_MCP fills it. }
    property Skills: TSkillRegistry read FSkills;
    { The session's approval service, so the runtime can hand it to the
      delegation tools. }
    property ApprovalService: IApprovalService read FApprovalService;

    { Cancel pending approvals; frees owned objects. Idempotent. }
    procedure Close;
  end;

const
  { The instruction that turns the current conversation into a checkpoint. The
    checkpoint is an ordinary turn: the runtime queues this as an ambient message
    and runs an ambient turn; the assistant's reply is the handoff document
    (delivered to the next page by Compose, see hildegard.helper.handoff). }
  CheckpointInstruction =
    'Write a handoff so another agent can pick this work up in a fresh context, ' +
    'with no memory of this session. Reply with the handoff document itself, as ' +
    'your message - do not write it to a file, and do not use a tool to record ' +
    'it. Be concise but complete; write the document itself, not commentary ' +
    'about it. It is a handoff, not a specification: it orients the next agent ' +
    'and points at the sources of truth - it does not restate them. Cover, as ' +
    'headed sections: ' +
    '(1) Objective - what we are doing and why; ' +
    '(2) Decisions - each decision and its rationale; ' +
    '(3) State - what is done, in progress, and uncommitted; ' +
    '(4) Grounding - the documents, files, or resources the next agent should ' +
    'read first to understand this work: exact paths, links, or identifiers, ' +
    'and one line on why each matters. Prefer the few highest-value sources ' +
    'over a full inventory; point at the workspace, do not reproduce it; ' +
    '(5) Gotchas - pitfalls, constraints, and things that bit us; ' +
    '(6) Open threads - what to do next.';

  { The AGENTIC revert. Unlike /undo (which moves the workspace backwards), this
    asks the agent to undo a turn's changes by moving FORWARDS - the way `git
    revert` applies an inverse as new work rather than `git reset` erasing
    history. The reverted turn stays in the ledger, so the record shows both what
    was done and that it was later reverted.

    The agent is the only party that can do this well: it must read what changed,
    decide how to invert it in the CURRENT state (which may have moved on since),
    and make a coherent change through its own gated tools. A patch inversion
    proves a byte-exact restore is possible; a revert only needs the effect
    undone, and only the agent can judge that. }
  RevertInstruction =
    'Revert the file changes made in an earlier turn of this session, by moving ' +
    'FORWARDS: make a new change that undoes their effect. Do not rewrite ' +
    'history or delete anything from the transcript. ' +
    'Read what that turn actually changed first, using the change history ' +
    'available to you. Then decide how to undo its EFFECT in the current state ' +
    'of the files, which may have moved on since - the goal is that the work ' +
    'that turn did is no longer in effect, not a byte-exact restore. Use your ' +
    'normal tools so the change is recorded like any other. ' +
    'If some of it cannot be undone coherently, undo what you can and say ' +
    'plainly what you left and why. Finish with a one-line summary of what you ' +
    'reverted.';

implementation

destructor THarnessSession.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure THarnessSession.Close;
begin
  FLoop.Free;
  FLoop := nil;
  FMcp.Free;
  FMcp := nil;
  FMcpTokenProviders.Free;
  FMcpTokenProviders := nil;
  { The registry is freed by refcount: the loop's ref is gone (FLoop.Free above);
    drop our owning ref last. Never Free it directly (double-free). }
  FSkills := nil;
  FSkillsKeep := nil;
  FCommandTool.Free;
  FRecorder.Free;
  { The loop holds the board as an interface (AddProvider), so its reference is
    the owner. Dropping ours is the only correct release - a Free here would
    double-free, the same rule the skill registry follows. }
  FBoardTools := nil;
  FBoardStore := nil;
  FTaskTools := nil;
  FTaskStore := nil;
  FChangeStore := nil;
  FCommandTool := nil;
  FFileTool.Free;
  FFileTool := nil;
  FRecallTool.Free;
  FRecallTool := nil;
  FTools.Free;
  FTools := nil;
  FClient.Free;
  FClient := nil;
  FConversation := nil;
  FView.Free;
  FView := nil;
  FGate.Free;
  FGate := nil;
  FQueue.Free;
  FQueue := nil;
  FToolPool := nil;
  FTurnPool := nil;
end;

class function THarnessSession.Open(const AConfig: THarnessSessionConfig;
  out AError: string): THarnessSession;
var
  Session: THarnessSession;
begin
  Result := nil;
  AError := '';
  Session := THarnessSession.Create;
  try
    if not Session.Init(AConfig, AError) then
    begin
      Session.Free;
      Exit(nil);
    end;
  except
    on E: Exception do
    begin
      Session.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := Session;
end;

function THarnessSession.NoticeBoard: Integer;
var
  Cursor, MaxId: Integer;
  Unread, Q, D, F: Integer;
  LastAt: Int64;
  Err: string;
  F2: TBoardFilter;
  Answers: TBoardEntryArray;
  Q1: TBoardEntry;
  Found: Boolean;
  I: Integer;
  Title, Text: string;
  NewMode: TCoordinationMode;
  Peers: Integer;
  Why: TCoordinationReason;
begin
  Result := 0;
  if (FBoardStore = nil) or (FLoop = nil) then
    Exit;
  { REVIVAL, once per session. A long-lived session returning after days gets one
    notice naming what it missed and what it lost, then never again - the facts do
    not change while it runs.

    It reports rather than injects: auto-dumping a backlog would blow the context
    budget, and the session can board_read deliberately if it wants history. }
  if not FRevivalChecked then
  begin
    FRevivalChecked := True;
    NoticeRevival;
  end;
  { A MODE TRANSITION raises one ambient notice, so an agent switches behaviour
    mid-session rather than carrying on alone after a peer arrives (or competing
    with nobody after one leaves).

    Safe to detect here precisely because claim renewal is UNCONDITIONAL: the
    transition changes what the agent is TOLD, never what state is valid. A
    conditional-renewal design would have needed the notice to repair state, and
    it would have arrived after the damage. }
  if FView.Store <> nil then
  begin
    NewMode := DetectCoordinationMode(FView.Store, FView.WorkspaceId,
      FView.SessionId, Peers, Why);
    { The first observation is not a transition: a session must not be told a peer
      "joined" when it simply looked for the first time. }
    if FModeKnown and (NewMode <> FLastMode) then
    begin
      if NewMode = cmMulti then
        FLoop.PromptQueue.PushBoard(
          'Another session is now live in this workspace. Switch to coordination '
          + 'mode: claim before you change, and read the board before assuming a '
          + 'file is untouched.', 0)
      else if NewMode = cmSingle then
        FLoop.PromptQueue.PushBoard(
          'You are alone in this workspace again. The board is a journal for your '
          + 'own future self now, not coordination with a peer.', 0);
    end;
    FLastMode := NewMode;
    FModeKnown := True;
  end;
  { Coalesce: ONE notice naming the total, not one per entry. A busy board with
    ten agents must cost O(ticks), not O(entries). }
  if not FBoardStore.CursorOf(FView.SessionId, Cursor, Err) then
    Exit;
  if not FBoardStore.Toc(FView.WorkspaceId, Cursor, Unread, Q, D, F, LastAt,
    Err) then
    Exit;
  if Unread <= 0 then
  begin
    FLastBoardNotice := 0;
    Exit;
  end;
  { Announce only when the count has CHANGED. The read cursor advances on
    board_read, not on being noticed, so re-notifying on every tick would
    announce the same post forever. }
  if Unread = FLastBoardNotice then
    Exit;
  FLastBoardNotice := Unread;

  { One exception to the bare count: an ANSWER to a question THIS session asked
    is the agent's own business, so it carries the question's title. A peer
    answering your question is not the same as traffic. }
  Title := '';
  F2 := Default(TBoardFilter);
  F2.Kind := bkAnswer;
  F2.KindSet := True;
  F2.SinceId := Cursor;
  F2.Limit := 5;
  if FBoardStore.Read(FView.WorkspaceId, F2, Answers, Err) then
    for I := 0 to High(Answers) do
      if Answers[I].ReplyTo <> 0 then
        if FBoardStore.Get(FView.WorkspaceId, Answers[I].ReplyTo, Q1, Found,
          Err) then
          if Found and (Q1.FromSession = FView.SessionId) and
            (Q1.Kind = bkQuestion) then
          begin
            Title := Q1.Title;
            Break;
          end;

  if Title <> '' then
    Text := 'an answer to your question "' + Title + '" (' + IntToStr(Unread) +
      ' new board message(s))'
  else
    Text := IntToStr(Unread) + ' new board message(s)';
  { Honesty about pruning. Unread is computed as "id > cursor", but pruning
    DELETES rows, so a cursor sitting on a pruned id under-reports with no
    indication. If the board holds fewer entries than the cursor implies, older
    ones are gone and we say so rather than silently under-counting.

    Deliberately "some were pruned", not "16 were pruned": if pruning ran twice
    while nobody watched we cannot distinguish 16 from 200, and inventing a
    number would be the same error as a confident unread count. }
  if FBoardStore.BoardMaxId(FView.WorkspaceId, MaxId, Err) and (Cursor > MaxId)
  then
    Text := Text + ' - some were pruned since you last read';
  FLoop.PromptQueue.PushBoard(Text, Unread);
  Result := Unread;
end;

procedure THarnessSession.NoticeRevival;
var
  Cursor: Integer;
  LastSeen, Now2, AgeSec: Int64;
  Unread, Q, D, F: Integer;
  LastAt: Int64;
  Err: string;
  Cards: TTaskCardArray;
  Ids: string;
  I: Integer;
  Text, Changed: string;

  function AgeText(ASec: Int64): string;
  begin
    if ASec < 3600 then
      Result := IntToStr(ASec div 60) + 'm'
    else if ASec < 86400 then
      Result := IntToStr(ASec div 3600) + 'h'
    else
      Result := IntToStr(ASec div 86400) + 'd';
  end;

begin
  { A session that has never read the board is NEW, not returning: it missed
    nothing because it was not there. Only a session WITH a cursor and a
    timestamp can have been away. }
  if not FBoardStore.CursorOf(FView.SessionId, Cursor, Err) then
    Exit;
  if Cursor <= 0 then
    Exit;
  if not FBoardStore.CursorLastSeenOf(FView.SessionId, LastSeen, Err) then
    Exit;
  if LastSeen <= 0 then
    Exit;                              // a pre-v16 row: unknown, not "now"

  Now2 := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
  AgeSec := Now2 - LastSeen;
  if AgeSec < 0 then
    AgeSec := 0;
  { Short absences are ordinary turn gaps, not a revival. Announcing every one
    would be noise. }
  if AgeSec < 1800 then
    Exit;

  Changed := '';
  if FBoardStore.Toc(FView.WorkspaceId, Cursor, Unread, Q, D, F, LastAt, Err)
  then
  begin
    if Unread > 0 then
      if Unread = 1 then
        Changed := '1 board entry since you last read'
      else
        Changed := IntToStr(Unread) + ' board entries since you last read';
    { Pruning honesty: if the board holds fewer entries than the cursor implies,
      older ones are gone. "Some were pruned", never a fabricated count. }
    if (LastAt <> 0) and (Cursor > LastAt) then
    begin
      if Changed <> '' then
        Changed := Changed + '; ';
      Changed := Changed + 'the board has been pruned since';
    end;
  end;

  { Claims recovered while away. A revived session returns believing it holds work
    it no longer does, which is worse than not knowing at all. }
  Ids := '';
  if FTaskStore <> nil then
    if FTaskStore.ReclaimedFrom(FView.WorkspaceId, FView.SessionId, Cards, Err)
    then
      for I := 0 to High(Cards) do
      begin
        if Ids <> '' then
          Ids := Ids + ', ';
        Ids := Ids + '#' + IntToStr(Cards[I].Id);
      end;

  if (Changed = '') and (Ids = '') then
    Exit;

  Text := 'You were away ' + AgeText(AgeSec) + ' ago';
  if Changed <> '' then
    Text := Text + '. ' + Changed;
  if Ids <> '' then
    Text := Text + '. Claims recovered from you while away: ' + Ids +
      ' - they are open again, so re-claim anything you still intend to do';
  FLoop.PromptQueue.PushBoard(Text, 0);
end;

procedure THarnessSession.NoteTurnOpened(ATurnId: Int64);
var
  ErrIgnored: string;
  Ignored: Integer;
  StoreErrIgnored: TStoreError;
begin
  if FRecorder <> nil then
    FRecorder.SetTurn(ATurnId);
  { Retention runs at the boundary, which is the only place it can: a turn just
    closed, so nothing is writing into the window that is about to be trimmed.
    A failure here must not fail the turn - a growing change log is a nuisance,
    not a broken session. }
  if FChangeStore <> nil then
    FChangeStore.PruneByTurns(FView.WorkspaceId, DefaultRetentionTurns, ErrIgnored);
  { The board prunes its noise classes at the same boundary, and never its
    knowledge. Swallowed for the same reason. }
  if FBoardStore <> nil then
    FBoardStore.Prune(FView.WorkspaceId, DefaultBoardKeepNotes,
      DefaultBoardNoteMaxAgeSec, Ignored, ErrIgnored);
  { The task list prunes finished cards by count and age, never live ones and
    never one another card names. Swallowed for the same reason. }
  if FTaskStore <> nil then
  begin
    FTaskStore.Prune(FView.WorkspaceId, DefaultTaskKeepDone,
      DefaultTaskDoneMaxAgeSec, Ignored, ErrIgnored);
    { Claim recovery has three parts now, and the boundary is where two of them
      belong. The heartbeat (runtime tick) keeps a live session looking alive -
      NOT the turn boundary, which was only ever a proxy. Expiry removes runtime
      rows whose process stopped heartbeating, so a crash cannot leave a session
      looking present forever. Reclaim then releases two different things: a live
      session that stopped working (the lease), and a session that is simply
      gone (no runtime row). Without all three the store's recovery is dead code,
      which is how the original gap opened. }
    FTaskStore.RenewClaims(FView.WorkspaceId, FView.SessionId, Ignored,
      ErrIgnored);
    if FView.Store <> nil then
      FView.Store.ExpireRuntimes(
        Round((Now - EncodeDate(1970, 1, 1)) * 86400) - DefaultRuntimeExpirySec,
        Ignored, StoreErrIgnored);
    FTaskStore.ReclaimStale(FView.WorkspaceId, DefaultClaimLeaseSec, Ignored,
      ErrIgnored);
  end;
end;

procedure THarnessSession.NoteTurnFinished(ATurnId: Int64);
begin
  { Fold the turn into one net row per path. This is the turn-boundary, not the
    next turn's opening: the summary must be complete when the turn ends, and a
    flush that waited for the following turn would render an empty block under
    the turn that just finished. Swallowed - a summary is not worth failing a
    turn over. }
  if (FRecorder <> nil) and (ATurnId <> 0) then
    FRecorder.FlushTurn;
end;

procedure THarnessSession.AnchorChanges(const AToolCallId: string);
var
  MsgId: Int64;
  StoreErr: TStoreError;
begin
  { The change rows exist already - they were appended while the tool ran. The
    message row may not, which is why this runs after the result rather than
    during the call. A missing row (or no store) is skipped silently: an
    unattributed change is a lesser problem than a failed turn. }
  if (FRecorder = nil) or (FView.Store = nil) or (AToolCallId = '') then
    Exit;
  if not FView.Store.ToolMessageId(FView.SessionId, AToolCallId, MsgId,
    StoreErr) then
    Exit;
  if MsgId > 0 then
    FRecorder.AnchorCall(AToolCallId, Integer(MsgId));
end;

function THarnessSession.UndoTurn(ATurnId: Int64; out ADetail: string): Boolean;
var
  Turns: TTurnRecordArray;
  I, First: Integer;
  UndidCount, SkippedUndone: Integer;
  StoreErr: TStoreError;
  MarkErr: string;
  Part: string;
begin
  { CUMULATIVE undo: undoing turn N walks back every turn from the newest to N
    inclusive, newest first. Undoing one turn in the middle while later turns
    survive would leave the transcript claiming work that happened after a turn
    that no longer exists, on top of files derived from reverted state.

    Newest-first order is required, not cosmetic: each turn's revert compares the
    file against that turn's AfterHash, and that only holds if the later turns
    have already been undone. }
  Result := False;
  ADetail := '';
  if FView.Store = nil then
  begin
    ADetail := 'this session has no store, so it recorded no changes';
    Exit;
  end;
  if ATurnId <= 0 then
  begin
    ADetail := 'no turn to undo';
    Exit;
  end;

  Turns := FView.Turns;
  First := -1;
  for I := 0 to High(Turns) do
    if Turns[I].Id = ATurnId then
    begin
      First := I;
      Break;
    end;
  if First < 0 then
  begin
    ADetail := 'that turn is not in this session';
    Exit;
  end;

  { Walk newest down to the target. Any refusal stops the whole undo, but the
    turns already undone stay undone - each one is itself all-or-nothing, and
    re-reverting is refused by the CAS, so a retry cannot double-apply. }
  UndidCount := 0;
  SkippedUndone := 0;
  for I := High(Turns) downto First do
  begin
    { A turn that is already undone is not silently passed over: the operator
      asked to move to a state and is owed an answer about what actually moved.
      Counted, and reported below. }
    if Turns[I].Status = tsUndone then
    begin
      Inc(SkippedUndone);
      Continue;
    end;
    if Turns[I].Status <> tsCompleted then
      Continue;   { failed, or running - nothing to move }
    if not UndoOneTurn(Turns[I].Id, Part) then
    begin
      ADetail := Part;
      Exit;
    end;
    { The change rows are marked reverted BEFORE the turn is marked, so a crash
      between the two leaves rows pointing at a completed turn that the dialog
      will still offer - recoverable. The reverse order could strand a tsUndone
      turn whose rows still look revertible. }
    if not FChangeStore.MarkReverted(FView.WorkspaceId, Integer(Turns[I].Id),
      Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay), MarkErr) then
    begin
      ADetail := 'the files were restored but the change rows could not be '
        + 'marked reverted: ' + MarkErr;
      Exit;
    end;
    { Soft-delete: the turn stays in the ledger so the record still shows it
      happened, but it is no longer part of the current context. The lifetime
      token totals keep counting it, because it did consume them. }
    if not FView.Store.FinishTurn(Turns[I].Id, tsUndone, 'undone', 0, '',
      '', StoreErr) then
    begin
      ADetail := 'the files were restored but the turn could not be marked: '
        + StoreErr.Message;
      Exit;
    end;
    Inc(UndidCount);
  end;

  { Report what moved. An undo that did nothing must not read as a success. }
  if UndidCount = 0 then
  begin
    if SkippedUndone > 0 then
      ADetail := 'already undone'
    else
      ADetail := 'nothing to undo: no completed turn in that range';
    Exit;
  end;
  { THE LAST UNDO DEFINES THE REDO WINDOW. The suffix it just took away is
    exactly what /redo may put back, and any earlier window is void - there is
    only ever one legal path forward, from the most recent undo. The floor is the
    id just below that suffix, so every undone turn sits above it.

    Set here rather than in BeginTurn: a prompt does NOT abandon the window. The
    operator undoes, prompts, undoes again, and expects to redo the second undo's
    suffix; a prompt raising the floor made that permanently impossible. }
  if not FView.Store.SetRedoFloor(FView.SessionId, Turns[First].Id - 1,
    StoreErr) then
  begin
    ADetail := 'the turns were undone but the redo window could not be set: '
      + StoreErr.Message;
    Exit;
  end;
  if SkippedUndone > 0 then
    ADetail := 'undid ' + IntToStr(UndidCount) + ' turn(s); '
      + IntToStr(SkippedUndone) + ' was already undone';
  Result := True;
end;

function THarnessSession.RedoTurn(ATurnId: Int64; out ADetail: string): Boolean;
var
  Turns: TTurnRecordArray;
  I, First: Integer;
  RedidCount, SkippedLive: Integer;
  Floor: Int64;
  StoreErr: TStoreError;
  MarkErr: string;
  Part: string;
  Rows: TChangeRecordArray;
  Results: TRevertResultArray;
  Hasher: TSha256Hasher;
  J: Integer;
begin
  { CUMULATIVE redo, OLDEST first: redoing to turn N re-applies every undone turn
    from N forward. The order is the mirror of undo's and is required for the
    same reason - each apply compares the file against that turn's BeforeHash,
    which only holds once every EARLIER turn has been re-applied.

    The redo WINDOW is closed by a prompt: the operator who undoes five turns and
    then prompts has abandoned those five, so redoing them later would resurrect
    work they moved past. That cannot be read off the status - abandoned turns
    keep tsUndone, because the record still shows the work happened - so the
    session carries a floor, and nothing below it is redoable. }
  Result := False;
  ADetail := '';
  if FView.Store = nil then
  begin
    ADetail := 'this session has no store, so it recorded no changes';
    Exit;
  end;
  if ATurnId <= 0 then
  begin
    ADetail := 'no turn to redo';
    Exit;
  end;

  Floor := 0;
  if not FView.Store.RedoFloor(FView.SessionId, Floor, StoreErr) then
  begin
    ADetail := 'could not read the redo window: ' + StoreErr.Message;
    Exit;
  end;
  if (Floor > 0) and (ATurnId <= Floor) then
  begin
    { Refused rather than silently clamped: redoing "as much as still counts" is
      not what the operator asked for, and a partial answer would be a different
      change than the one requested. }
    ADetail := 'that turn cannot be redone: a newer prompt abandoned it';
    Exit;
  end;

  Turns := FView.Turns;
  First := -1;
  for I := 0 to High(Turns) do
    if Turns[I].Id = ATurnId then
    begin
      First := I;
      Break;
    end;
  if First < 0 then
  begin
    ADetail := 'that turn is not in this session';
    Exit;
  end;

  RedidCount := 0;
  SkippedLive := 0;
  for I := First to High(Turns) do
  begin
    if Turns[I].Status <> tsUndone then
    begin
      { A turn that is still live was never undone, so there is nothing to
        re-apply. Counted rather than silently passed over. }
      Inc(SkippedLive);
      Continue;
    end;

    if not FChangeStore.ForTurn(FView.WorkspaceId, Integer(Turns[I].Id), Rows,
      Part) then
    begin
      ADetail := Part;
      Exit;
    end;
    Hasher := TSha256Hasher.Create;
    try
      if not ApplyTurn(FView.WorkspaceRoot, Rows, Hasher.OfText, 0, Results) then
      begin
        ADetail := 'could not read this turn''s changes';
        Exit;
      end;
    finally
      Hasher.Free;
    end;
    { All-or-nothing for the turn: a partial redo would leave the transcript and
      the workspace disagreeing, the same lie in the other direction. }
    for J := 0 to High(Results) do
      if (Results[J].Outcome <> rvReverted) and
        (Results[J].Outcome <> rvSkipped) then
      begin
        ADetail := 'could not redo ' + Results[J].Path + ': '
          + Results[J].Detail;
        Exit;
      end;

    { The rows are in effect again... }
    if not FChangeStore.MarkReverted(FView.WorkspaceId, Integer(Turns[I].Id),
      0, MarkErr) then
    begin
      ADetail := 'the files were reapplied but the change rows could not be '
        + 'marked live: ' + MarkErr;
      Exit;
    end;
    { ...and restoring tsCompleted is what brings the messages back: the context
      filter excludes tsUndone and nothing else, so no message surgery is
      needed. }
    if not FView.Store.FinishTurn(Turns[I].Id, tsCompleted, 'redone', 0, '',
      '', StoreErr) then
    begin
      ADetail := 'the files were reapplied but the turn could not be marked: '
        + StoreErr.Message;
      Exit;
    end;
    Inc(RedidCount);
  end;

  if RedidCount = 0 then
  begin
    if SkippedLive > 0 then
      ADetail := 'nothing to redo: those turns are not undone'
    else
      ADetail := 'nothing to redo in that range';
    Exit;
  end;
  if SkippedLive > 0 then
    ADetail := 'redid ' + IntToStr(RedidCount) + ' turn(s); '
      + IntToStr(SkippedLive) + ' was not undone';
  Result := True;
end;

function THarnessSession.UndoOneTurn(ATurnId: Int64; out ADetail: string): Boolean;
var
  Rows: TChangeRecordArray;
  Results: TRevertResultArray;
  I, N, Reverted, Skipped: Integer;
  Hasher: TSha256Hasher;
  StoreErr: TStoreError;
begin
  Result := False;
  ADetail := '';
  if FView.Store = nil then
  begin
    ADetail := 'this session has no store, so it recorded no changes';
    Exit;
  end;
  if ATurnId <= 0 then
  begin
    ADetail := 'no turn to undo';
    Exit;
  end;

  if not FChangeStore.ForTurn(FView.WorkspaceId, Integer(ATurnId), Rows,
    ADetail) then
    Exit;

  { Only net rows describe what the turn did. A turn with NONE is not a turn that
    cannot be undone - it is a CONVERSATIONAL turn, and going back on the
    conversation is the primary meaning of undo. File reversion is secondary: when
    there is nothing to revert, there is nothing to do here and the caller still
    marks the turn undone and drops it from the context.

    This used to refuse with 'this turn changed no files', which made /undo
    unavailable on any discussion-only session. }
  N := 0;
  for I := 0 to High(Rows) do
    if Rows[I].IsNet then
      Inc(N);
  if N = 0 then
  begin
    Result := True;
    Exit;
  end;

  Hasher := TSha256Hasher.Create;
  try
    if not RevertTurn(FView.WorkspaceRoot, Rows, Hasher.OfText, 0, Results) then
    begin
      ADetail := 'could not read this turn''s changes';
      Exit;
    end;
  finally
    Hasher.Free;
  end;

  { Refuse the whole undo if any file could not be restored. Rewinding the
    transcript while files stay changed would hide a turn that is still in
    effect - the same lie as moving one without the other, in the other
    direction. A SKIPPED row (no patch captured) also blocks: the file may well
    have changed and nothing can prove otherwise. }
  Reverted := 0;
  Skipped := 0;
  for I := 0 to High(Results) do
    case Results[I].Outcome of
      rvReverted: Inc(Reverted);
      rvSkipped:
        begin
          Inc(Skipped);
          if ADetail = '' then
            ADetail := Results[I].Path + ': ' + Results[I].Detail;
        end;
    else
      ADetail := Results[I].Path + ': ' + Results[I].Detail;
    end;
  if Reverted <> N then
  begin
    if ADetail = '' then
      ADetail := 'not every changed file could be restored';
    Exit;
  end;

  { Files are back, so the two halves agree. The transcript is moved by STATUS,
    not by deletion: the turn is marked tsUndone (by the caller) and the context
    filters excludes it, so its messages stay in the ledger.

    They used to be DELETED here, which was the pre-tsUndone way to keep them out
    of the prompt. That was wrong twice over: the spec says an undone turn's
    messages are "marked reverted rather than deleted" so the record still shows
    the work happened, and a deleted row is a row `/redo` can never bring back. }
  Result := True;
end;

function THarnessSession.OldestRedoableTurn: Int64;
var
  Turns: TTurnRecordArray;
  Floor: Int64;
  I: Integer;
  StoreErr: TStoreError;
begin
  Result := 0;
  if FView.Store = nil then
    Exit;
  { An unreadable floor must not read as "no floor": that would offer a turn the
    operator abandoned. Treat it as the whole window being closed, which is the
    conservative answer - the operator can always ask for a specific turn. }
  if not FView.Store.RedoFloor(FView.SessionId, Floor, StoreErr) then
    Exit;
  Turns := FView.Turns;
  for I := 0 to High(Turns) do
    if (Turns[I].Status = tsUndone) and (Turns[I].Id > Floor) then
    begin
      Result := Turns[I].Id;
      Exit;
    end;
end;

function THarnessSession.TaskQuestionExists(AWorkspaceId, AId: Integer;
  out ATitle: string): Boolean;
var
  E: TBoardEntry;
  Found: Boolean;
  Err: string;
begin
  { Only a live `question` counts. A note or a decision is not an answer someone
    owes, so it cannot be something work waits on. A deleted entry is likewise
    not a question any more. }
  Result := False;
  ATitle := '';
  if FBoardStore = nil then
    Exit;
  if not FBoardStore.Get(AWorkspaceId, AId, E, Found, Err) then
    Exit;
  if not Found then
    Exit;
  if E.DeletedAt <> 0 then
    Exit;
  if E.Kind <> bkQuestion then
    Exit;
  ATitle := E.Title;
  Result := True;
end;

procedure THarnessSession.RecordChanges(const AChanges: TFileChangeSet;
  const AToolCallId: string);
begin
  { The turn is known (the loop reports it); the message id is NOT, because the
    tool result row does not exist yet when the handler runs. So the rows are
    recorded against their CALL id, and anchored later by AnchorChanges once the
    result row exists. Without the call id, two concurrent calls could not be
    told apart. }
  if FRecorder <> nil then
    FRecorder.Observe(AChanges, AToolCallId);
end;

function THarnessSession.InvokeShellTool(const AName, AArgumentsJson,
  AReason: string; out AResult, AError: string): Boolean;
var
  Tool: TRegisteredTool;
begin
  AResult := '';
  AError := '';
  if FTools.Find(AName, Tool) then
    Exit(Tool.Handler(AArgumentsJson, AResult, AError));
  if (FMcp <> nil) and FMcp.Find(AName, Tool) then
    Exit(Tool.Handler(AArgumentsJson, AResult, AError));
  AError := 'unknown tool: ' + AName;
  Result := False;
end;

procedure THarnessSession.McpEvent(const AMessage, ADetail: string);
begin
  if FConversation <> nil then
    FConversation.AppendError(AMessage, ADetail);
end;

procedure THarnessSession.ComposeStablePrompt;
var
  Mode: TCoordinationMode;
  Reason: TCoordinationReason;
  Peers: Integer;
begin
  if FLoop = nil then
    Exit;
  FLoop.StablePrompt := FSkills.StableText;
  { The tail elements are data; their explanations belong here, where they cache
    with the system prompt instead of costing every request.

    One block, not three: the coordination text teaches the board, the task list,
    the four protocol rules, and - when there is a peer - how to agree protocols
    before starting. Splitting it per-surface duplicated the shared rules and made
    "am I alone?" a fact stated in two places that could disagree. }
  if (FBoardStore <> nil) or (FTaskStore <> nil) then
  begin
    Mode := DetectCoordinationMode(FView.Store, FView.WorkspaceId,
      FView.SessionId, Peers, Reason);
    FLoop.StablePrompt := FLoop.StablePrompt + LineEnding + LineEnding +
      CoordinationPromptFor(Mode, Reason);
  end;
  { Tell the model which shell commands the gated tier runs, and why to prefer
    them. Without this it reaches for perl or python3 - which are NOT in the tier,
    so the whole script silently escalates to the process tier, where effects are
    inferred by a tree walk rather than known exactly. The list is generated from
    the dispatch table, so it cannot drift from what actually runs. }
  FLoop.StablePrompt := FLoop.StablePrompt + LineEnding + LineEnding +
    'Prefer the built-in shell for composed file work. run_command runs these '
    + 'commands in-process, gated and with exact before/after effects: '
    + BuiltinCommandList + '.'
    + LineEnding
    + 'Loops, pipelines, redirects and command substitution all work. Anything '
    + 'else - perl, python3, node, a binary - is NOT in that list: the whole '
    + 'script leaves the gated tier and runs as a subprocess, where what it '
    + 'changed can only be inferred by comparing the tree before and after. If a '
    + 'job needs a language you cannot express in the commands above, prefer the '
    + 'dedicated file tools (file_read, file_edit, file_search_replace, '
    + 'patch_apply, json_edit, yaml_edit) over a script.';
end;

function THarnessSession.McpTokenSourceFor(
  const AServer: TMcpServerConfig): TMcpTokenSource;
var
  Row: TOAuthTokenRow;
  StoreErr: TStoreError;
  Provider: TOAuthTokenProvider;
begin
  Result := nil;
  if (AServer.Transport <> mtHttp) or (FView = nil) or (FView.Store = nil) then
    Exit;
  if not FView.Store.LoadOAuthToken(AServer.Scope, FView.WorkspaceId,
    AServer.Name, Row, StoreErr) then
    Exit;   { no stored token: fall back to static headers / none }
  Provider := TOAuthTokenProvider.Create(FView.Store, AServer.Scope,
    FView.WorkspaceId, AServer.Name, AServer.Url);
  FMcpTokenProviders.Add(Provider);
  Result := Provider.GetToken;
end;

function THarnessSession.McpConfigSource: TMcpConfig;
var
  Ctx: TMcpConfigContext;
  Rows: TMcpServerRowArray;
  StoreErr: TStoreError;
begin
  Result := Default(TMcpConfig);
  if (FView = nil) or (FView.Store = nil) then
    Exit;
  Ctx := Default(TMcpConfigContext);
  Ctx.WorkspaceId := FView.WorkspaceId;
  Result.Context := Ctx;
  Rows := nil;
  if FView.Store.LoadMcpServers(Ctx, Rows, StoreErr) then
    Result.Servers := ResolveMcpConfig(Rows, Ctx);
end;

procedure THarnessSession.ReconcileMcpSkills;
var
  Cfg: TMcpConfig;
  I, J: Integer;
  Key: string;  Present: Boolean;
  Keys: TStringArray;
begin
  if (FSkills = nil) or (FMcp = nil) then
    Exit;
  Cfg := McpConfigSource;
  { Reconcile the manager's runtime set from the config first (lazy: it adds or
    drops runtimes but does not connect). This is what lets a server added after
    open be loadable. }
  FMcp.Reconcile(Cfg);
  { Remove MCP skills whose server is gone or disabled. }
  Keys := FSkills.Keys;
  for I := 0 to High(Keys) do
  begin
    Key := Keys[I];
    if Copy(Key, 1, 4) <> 'mcp_' then
      Continue;
    Present := False;
    for J := 0 to High(Cfg.Servers) do
      if McpSkillKey(Cfg.Servers[J].Name) = Key then
      begin
        Present := True;
        Break;
      end;
    if not Present then
      FSkills.Remove(Key);
  end;
  { Declare/replace a skill per configured server (no connect). }
  RegisterMcpSkills(FSkills, Cfg, FMcp);
  { The STABLE half - each skill's description and when-to-use - goes to the
    system prompt, where stable text belongs. Only the activation state stays in
    the per-request fragment, so the manifest stops costing ~105 tokens on every
    request and a load only changes a few short lines. }
  ComposeStablePrompt;
end;

function THarnessSession.Init(const AConfig: THarnessSessionConfig;
  out AError: string): Boolean;
var
  EnvValue: string;
  LlmConfig: TLLMConfig;
  ApprovalStore: IApprovalStore;
  ApprovalService: IApprovalService;
  ApprovalCtx: TApprovalContext;
  ToolConfig: TCommandToolConfig;
  TierConfig: TBuiltinShellConfig;
  FileConfig: TFileToolConfig;
  AgentConfig: TAgentConfig;
  Conv: TSqliteConversationStore;
  McpCfg: TMcpConfig;
  Cap: Integer;
begin
  Result := False;

  { The view loads .env, opens the workspace/store, and resolves the session. }
  FView := TSessionView.Open(AConfig, AError);
  if FView = nil then
    Exit;

  Cap := ResolveToolResultCap(AConfig.ToolResultCap);

  LlmConfig := Default(TLLMConfig);
  LlmConfig := ResolveLLMConfig(LlmConfig);
  if AConfig.Model <> '' then
    LlmConfig.Model := AConfig.Model;
  if AConfig.Endpoint <> '' then
    LlmConfig.Endpoint := AConfig.Endpoint;
  FClient := TLLMClient.Create(LlmConfig, AConfig.Transport);

  FTools := TToolRegistry.Create;
  RegisterDefaultTools(FTools);

  { A store enables persistence and durable approvals; without one, approvals
    are session-only (in memory) and nothing is written. }
  if FView.Store <> nil then
  begin
    ApprovalStore := TStoreApprovalStore.Create(FView.Store);
    Conv := TSqliteConversationStore.Create(FView.Store, FView.SessionId, 0);
    Conv.ToolResultCap := Cap;
    FConversation := Conv;
  end
  else
  begin
    ApprovalStore := TMemoryApprovalStore.Create;
    FConversation := TMemoryConversationStore.Create;
  end;

  FQueue := TTurnQueue.Create;
  { The shared turn pool. Two workers so a turn blocked on an approval (or on
    the provider) never starves the next turn, and so a cancel of one turn can
    be processed while another runs. }
  FTurnPool := TExecutorScheduler.Create(2);
  { Bound the approval wait only when the config asks for it (0 = wait
    indefinitely). A connected client owns the timeout; the auto-deny is for a
    headless run with no one to answer. }
  FGate := TApprovalGate.Create(FQueue, AConfig.ApprovalTimeoutMs);

  ApprovalCtx.WorkspaceId := FView.WorkspaceId;
  { A subagent resolves approvals against its lineage root, so the whole
    lineage shares one session scope. }
  if AConfig.ApprovalRootSessionId <> '' then
    ApprovalCtx.SessionId := AConfig.ApprovalRootSessionId
  else
    ApprovalCtx.SessionId := FView.SessionId;
  ApprovalService := TApprovalService.Create(ApprovalStore, FGate.Prompt,
    ApprovalCtx);
  FApprovalService := ApprovalService;
  ToolConfig := Default(TCommandToolConfig);
  ToolConfig.Shell := DefaultShellProfile;
  ToolConfig.DefaultCwd := FView.WorkspaceRoot;
  { Optional cap on the model's run_command timeout (ms); unset = the model
    defines its own. }
  EnvValue := GetEnvironmentVariable('HILDEGARD_COMMAND_TIMEOUT_MS');
  if EnvValue <> '' then
    ToolConfig.MaxTimeoutMs := StrToInt64Def(EnvValue, 0);
  { The change log: created BEFORE the tool, because the tool reads its config
    once at construction and holds no setter. A session with no store records
    nothing, which is the honest behaviour rather than a failure. }
  if FView.Store <> nil then
  begin
    FChangeStore := TSqliteChangeStore.Create(FView.Store);
    FRecorder := TChangeRecorder.Create(FChangeStore, FView.WorkspaceId,
      FView.SessionId);
    ToolConfig.OnChanges := RecordChanges;
  end;
  { The builtin shell tier runs supported scripts in-process; anything else
    falls through to the process executor. HILDEGARD_BUILTIN_SHELL=0 disables it
    for a session (the process tier is then used exactly as before). }
  if GetEnvironmentVariable('HILDEGARD_BUILTIN_SHELL') <> '0' then
  begin
    TierConfig := Default(TBuiltinShellConfig);
    TierConfig.Root := FView.WorkspaceRoot;
    TierConfig.MaxOutputBytes := DefaultMaxOutputBytes;
    TierConfig.AllowedTools := ['file_read', 'file_list', 'file_glob',
      'file_grep', 'file_stat', 'mcp_*'];
    FCommandTool := TCommandTool.Create(ToolConfig, ApprovalService,
      TBuiltinCommandExecutor.Create(TierConfig, ApprovalService,
        TProcessCommandExecutor.Create, InvokeShellTool));
  end
  else
    FCommandTool := TCommandTool.Create(ToolConfig, ApprovalService);
  FCommandTool.Register(FTools);

  FileConfig := Default(TFileToolConfig);
  FileConfig.Root := FView.WorkspaceRoot;
  { The same handler the command tool uses. Without this the file tools write
    with no record at all - undo, the turn summary, the diff viewer and revert
    would all be blind to file_write and file_edit, which is how an agent most
    often edits. }
  if FRecorder <> nil then
    FileConfig.OnChanges := RecordChanges;
  FFileTool := TFileTool.Create(FileConfig, ApprovalService);
  FFileTool.Register(FTools);

  { The board: durable knowledge shared with peers and with this session's
    future self. Only with a store - there is nowhere to put entries otherwise. }
  FBoardStore := nil;
  FBoardTools := nil;
  if FView.Store <> nil then
  begin
    FBoardStore := TSqliteBoardStore.Create(FView.Store);
    FBoardTools := TBoardTools.Create(FBoardStore, FView.WorkspaceId,
      FView.SessionId, 'parent', ApprovalService);
    FBoardTools.Register(FTools);
  end;

  { The task list: mutable shared work. Same rule - no store, nowhere to put a
    card. The board hook is passed only when a board exists, so a question
    blocker is refused by name rather than recorded pointing at nothing. }
  FTaskStore := nil;
  FTaskTools := nil;
  if FView.Store <> nil then
  begin
    FTaskStore := TSqliteTaskStore.Create(FView.Store);
    if FBoardStore <> nil then
      FTaskTools := TTaskTool.Create(FTaskStore, FView.WorkspaceId,
        FView.SessionId, 'parent', ApprovalService, TaskQuestionExists)
    else
      FTaskTools := TTaskTool.Create(FTaskStore, FView.WorkspaceId,
        FView.SessionId, 'parent', ApprovalService, nil);
    FTaskTools.Register(FTools);
  end;

  { The recall tool reads stored artifacts; without a store there are none. }
  if FView.Store <> nil then
  begin
    FRecallTool := TRecallTool.Create(FView.Store, FView.SessionId, Cap);
    FRecallTool.Register(FTools);
  end;

  { MCP servers: effective config comes from the store (scoped), resolved for
    this workspace. The manager is created LAZY (no connect on startup), so the
    runtime's socket binds without touching a server; each enabled server becomes
    a skill, and a load_skill connects it. Only with a store; without one there
    is nowhere to read config from. }
  if FView.Store <> nil then
  begin
    McpCfg := McpConfigSource;
    FMcpTokenProviders := TObjectList.Create(True);
    FMcp := TMcpManager.Create(McpCfg, ApprovalService, McpEvent,
      McpTokenSourceFor);
    FMcp.Lazy := True;
  end;

  AgentConfig := Default(TAgentConfig);
  AgentConfig.SystemPrompt := AConfig.SystemPrompt;
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := GetEnvironmentVariable('HILDEGARD_SYSTEM_PROMPT');
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := DefaultSystemPrompt;
  { The tool-call budget keeps its agent default; the context cap comes from the
    view (which resolved the config, env, or the default). }
  AgentConfig.MaxContextTokens := FView.MaxContextTokens;
  { State the workspace root in the user turn's <context>, so the model grounds
    shell paths instead of guessing one. }
  AgentConfig.WorkspaceRoot := FView.WorkspaceRoot;
  AgentConfig.RetryMaxAttempts := AConfig.RetryMaxAttempts;

  FLoop := TAgentLoop.Create(FClient, FConversation, FTools, AgentConfig);
  { A separate pool for parallel tool calls: the turn runs on FTurnPool, so tool
    jobs must not share it (a low concurrency would serialize or deadlock). }
  FToolPool := TExecutorScheduler.Create(4);
  FLoop.ToolPool := FToolPool;
  { The skill registry is the capability layer; register it as the provider. Its
    load_skill is offered once any skill is declared. Empty by default. }
  FSkills := TSkillRegistry.Create;
  FSkillsKeep := FSkills;   // owning interface ref
  FLoop.AddProvider(FSkillsKeep);
  { The board contributes its TOC through the same seam the skills manifest uses.
    Its tools are registered directly; the provider exists for the tail. }
  if FBoardTools <> nil then
    FLoop.AddProvider(FBoardTools);
  { The task list contributes its work queue the same way. }
  if FTaskTools <> nil then
    FLoop.AddProvider(FTaskTools);
  { Lazy MCP: each configured server is a skill (declared, not connected). A
    load_skill connects it. Re-declared at each turn boundary so an add/enable/
    remove is picked up without a restart. }
  { The stable half of the manifest (descriptions) goes to the system prompt. It
    must be set even with no MCP configured: a locally-declared skill would
    otherwise lose its description entirely, since the fragment now carries only
    state. }
  FLoop.StablePrompt := FSkills.StableText;
  { The board's and the task list's explanations ride the stable half too: those
    tail elements are data only, so a model that has never seen either needs to
    be told what it is. Composed in one place so an MCP reconcile cannot drop
    them. }
  ComposeStablePrompt;
  { The change log attributes each change to the turn it happened in. }
  FLoop.OnTurnOpened := NoteTurnOpened;
  { The fold flushes when the turn is TERMINAL, not when the next one opens. }
  FLoop.OnTurnFinished := NoteTurnFinished;
  if FMcp <> nil then
  begin
    ReconcileMcpSkills;
    FLoop.OnTurnStart := ReconcileMcpSkills;
  end;
  Result := True;
end;

end.
