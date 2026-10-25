unit hildegard.helper.tasks.store;
{ The SQLite implementation of the task list.

  The one query that matters is Claim: a single UPDATE guarded on the current
  status, so two agents reaching for one card cannot both win. No lock, no lease,
  and nothing held across a model's thinking time. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.sqlite, hildegard.helper.store,
  hildegard.helper.tasks;

type
  ITaskStore = interface
    ['{C3D4E5F6-7A8B-4C9D-0E1F-2A3B4C5D6E7F}']
    function Add(const ACard: TTaskCard; out AId: Integer;
      out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out ACard: TTaskCard;
      out AFound: Boolean; out AError: string): Boolean;
    function List(AWorkspaceId: Integer; const AFilter: TTaskFilter;
      out ACards: TTaskCardArray; out AError: string): Boolean;

    { THE CAS: succeeds only from tsOpen. AClaimed False means someone else holds
      it, and APrevious carries the holder so the caller can name them. }
    function Claim(AWorkspaceId, AId: Integer; const ABy: string;
      var APrevious: TTaskCard; out AClaimed, AFound: Boolean;
      out AError: string): Boolean;

    { A guarded transition: the card must currently be in AFrom and (unless ABy
      is '' for an operator action) claimed by ABy. }
    function Transition(AWorkspaceId, AId: Integer; AFrom, ATo: TTaskStatus;
      const ABy: string; ABlockedOnId: Integer; ABlockedOnKind: TBlockerKind;
      const ADoneNote: string; out AError: string): Boolean;

    function Edit(AWorkspaceId, AId: Integer; const ATitle, ABody: string;
      out AError: string): Boolean;
    function Delete(AWorkspaceId, AId: Integer; out AError: string): Boolean;
    { Retention: finished cards only, by count and age. Never a live card, and
      never one that is another card's parent or blocker. }
    function Prune(AWorkspaceId, AKeepDone: Integer; AMaxAgeSec: Int64;
      out APruned: Integer; out AError: string): Boolean;
    { Cards this session holds, for the tail. }
    function Mine(AWorkspaceId: Integer; const ASessionId: string;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    { Open cards, most recently updated first - the tail's work queue. }
    function OpenCards(AWorkspaceId, ALimit: Integer;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    { The TRUE number of open cards, for the tail's count. OpenCards is capped,
      so its length is how many are named, never how many exist. }
    function OpenCount(AWorkspaceId: Integer; out ACount: Integer;
      out AError: string): Boolean;
    { Cards whose claim was RECOVERED from ASessionId and which are still open.
      A revived session returns believing it holds work it no longer does; this
      lets the revival notice say so. Matched on done_note, where ReclaimStale
      records the former holder. }
    function ReclaimedFrom(AWorkspaceId: Integer; const ASessionId: string;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    { Blocked cards, oldest first. The tail needs these because a block is only
      worth surfacing when it is yours OR has gone stale - and a card held by
      another session never appears in Mine. }
    function BlockedCards(AWorkspaceId, ALimit: Integer;
      out ACards: TTaskCardArray; out AError: string): Boolean;

    { A LIVE CLAIM IS NOT A LOCK, so nothing else would stop a session that dies
      from holding its cards forever. Two halves close that, and they belong
      together: Renew moves the clock for a session that is working, Reclaim takes
      cards from sessions that stopped. }

    { Move claimed_at to now for every card this session holds. Called at the turn
      boundary: opening a turn IS the heartbeat, so an agent that is working never
      looks dead and needs no background timer. }
    function RenewClaims(AWorkspaceId: Integer; const ABy: string;
      out ARenewed: Integer; out AError: string): Boolean;
    { Release claims older than AMaxAgeSec back to open, recording who held them.
      A reclaimed card is work nobody is doing, which is better than work that is
      silently taken. Never touches a fresh claim, an unclaimed card, or a
      finished one. }
    function ReclaimStale(AWorkspaceId: Integer; AMaxAgeSec: Integer;
      out AReclaimed: Integer; out AError: string): Boolean;
  end;

type
  TSqliteTaskStore = class(TInterfacedObject, ITaskStore)
  private
    FStore: TSqliteStore;
    function Prepare(const ASQL: string; out AStmt: Psqlite3_stmt;
      out AError: string): Boolean;
    procedure Fill(const AStmt: Psqlite3_stmt; out ACard: TTaskCard);
  public
    constructor Create(AStore: TSqliteStore);
    function Add(const ACard: TTaskCard; out AId: Integer;
      out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out ACard: TTaskCard;
      out AFound: Boolean; out AError: string): Boolean;
    function List(AWorkspaceId: Integer; const AFilter: TTaskFilter;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    function Claim(AWorkspaceId, AId: Integer; const ABy: string;
      var APrevious: TTaskCard; out AClaimed, AFound: Boolean;
      out AError: string): Boolean;
    function Transition(AWorkspaceId, AId: Integer; AFrom, ATo: TTaskStatus;
      const ABy: string; ABlockedOnId: Integer; ABlockedOnKind: TBlockerKind;
      const ADoneNote: string; out AError: string): Boolean;
    function Edit(AWorkspaceId, AId: Integer; const ATitle, ABody: string;
      out AError: string): Boolean;
    function Delete(AWorkspaceId, AId: Integer; out AError: string): Boolean;
    function Prune(AWorkspaceId, AKeepDone: Integer; AMaxAgeSec: Int64;
      out APruned: Integer; out AError: string): Boolean;
    function Mine(AWorkspaceId: Integer; const ASessionId: string;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    function OpenCards(AWorkspaceId, ALimit: Integer;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    function OpenCount(AWorkspaceId: Integer; out ACount: Integer;
      out AError: string): Boolean;
    { Cards whose claim was RECOVERED from ASessionId and which are still open.
      A revived session returns believing it holds work it no longer does; this
      lets the revival notice say so. Matched on done_note, where ReclaimStale
      records the former holder. }
    function ReclaimedFrom(AWorkspaceId: Integer; const ASessionId: string;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    function BlockedCards(AWorkspaceId, ALimit: Integer;
      out ACards: TTaskCardArray; out AError: string): Boolean;
    function RenewClaims(AWorkspaceId: Integer; const ABy: string;
      out ARenewed: Integer; out AError: string): Boolean;
    function ReclaimStale(AWorkspaceId: Integer; AMaxAgeSec: Integer;
      out AReclaimed: Integer; out AError: string): Boolean;
  end;

const
  TaskColumns = 'id, workspace_id, title, body, status, claimed_by, claimed_at, ' +
    'status_at, blocked_on_id, blocked_on_kind, parent, position, from_session, ' +
    'from_label, done_note, created_at, updated_at';

implementation

constructor TSqliteTaskStore.Create(AStore: TSqliteStore);
begin
  inherited Create;
  FStore := AStore;
end;

function TSqliteTaskStore.Prepare(const ASQL: string;
  out AStmt: Psqlite3_stmt; out AError: string): Boolean;
begin
  AStmt := nil;
  AError := '';
  Result := (FStore <> nil) and (FStore.Db <> nil) and
    (sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(ASQL)), -1, @AStmt,
      nil) = 0);
  if not Result then
    AError := 'task store: could not prepare a statement';
end;

procedure TSqliteTaskStore.Fill(const AStmt: Psqlite3_stmt;
  out ACard: TTaskCard);
var
  S: PAnsiChar;
begin
  ACard := Default(TTaskCard);
  ACard.Id := sqlite3_column_int(AStmt, 0);
  ACard.WorkspaceId := sqlite3_column_int(AStmt, 1);
  S := sqlite3_column_text(AStmt, 2);
  if S <> nil then ACard.Title := AnsiString(S);
  S := sqlite3_column_text(AStmt, 3);
  if S <> nil then ACard.Body := AnsiString(S);
  ACard.Status := TTaskStatus(sqlite3_column_int(AStmt, 4));
  S := sqlite3_column_text(AStmt, 5);
  if S <> nil then ACard.ClaimedBy := AnsiString(S);
  ACard.ClaimedAt := sqlite3_column_int64(AStmt, 6);
  ACard.StatusAt := sqlite3_column_int64(AStmt, 7);
  ACard.BlockedOnId := sqlite3_column_int(AStmt, 8);
  ACard.BlockedOnKind := TBlockerKind(sqlite3_column_int(AStmt, 9));
  ACard.Parent := sqlite3_column_int(AStmt, 10);
  ACard.Position := sqlite3_column_int(AStmt, 11);
  S := sqlite3_column_text(AStmt, 12);
  if S <> nil then ACard.FromSession := AnsiString(S);
  S := sqlite3_column_text(AStmt, 13);
  if S <> nil then ACard.FromLabel := AnsiString(S);
  S := sqlite3_column_text(AStmt, 14);
  if S <> nil then ACard.DoneNote := AnsiString(S);
  ACard.CreatedAt := sqlite3_column_int64(AStmt, 15);
  ACard.UpdatedAt := sqlite3_column_int64(AStmt, 16);
end;

function TSqliteTaskStore.Add(const ACard: TTaskCard; out AId: Integer;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Title, Body, FromSession, FromLabel: AnsiString;
begin
  Result := False;
  AId := 0;
  Title := AnsiString(ACard.Title);
  Body := AnsiString(ACard.Body);
  FromSession := AnsiString(ACard.FromSession);
  FromLabel := AnsiString(ACard.FromLabel);
  FStore.Lock.Acquire;
  try
    if not Prepare('INSERT INTO task_cards (workspace_id, title, body, status, ' +
      'claimed_by, claimed_at, status_at, blocked_on_id, blocked_on_kind, ' +
      'parent, position, from_session, from_label, done_note, created_at, ' +
      'updated_at) VALUES (?, ?, ?, ?, '''', 0, ?, 0, 0, ?, ?, ?, ?, '''', ?, ?)',
      Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, ACard.WorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Title), -1, nil);
      sqlite3_bind_text(Stmt, 3, PAnsiChar(Body), -1, nil);
      sqlite3_bind_int(Stmt, 4, Ord(tsOpen));
      sqlite3_bind_int64(Stmt, 5, ACard.CreatedAt);
      sqlite3_bind_int(Stmt, 6, ACard.Parent);
      sqlite3_bind_int(Stmt, 7, ACard.Position);
      sqlite3_bind_text(Stmt, 8, PAnsiChar(FromSession), -1, nil);
      sqlite3_bind_text(Stmt, 9, PAnsiChar(FromLabel), -1, nil);
      sqlite3_bind_int64(Stmt, 10, ACard.CreatedAt);
      sqlite3_bind_int64(Stmt, 11, ACard.CreatedAt);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if Result then
        AId := Integer(sqlite3_last_insert_rowid(FStore.Db))
      else
        AError := 'task store: could not add';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Get(AWorkspaceId, AId: Integer;
  out ACard: TTaskCard; out AFound: Boolean; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  ACard := Default(TTaskCard);
  AFound := False;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' + TaskColumns + ' FROM task_cards ' +
      'WHERE workspace_id = ? AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, AId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        Fill(Stmt, ACard);
        AFound := True;
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.List(AWorkspaceId: Integer;
  const AFilter: TTaskFilter; out ACards: TTaskCardArray;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  SQL, Where: string;
  N, Lim, Idx: Integer;
  MineSid: AnsiString;
begin
  Result := False;
  ACards := nil;
  N := 0;
  Where := ' WHERE workspace_id = ?';
  if AFilter.StatusSet then
    Where := Where + ' AND status = ?';
  if AFilter.Mine then
    Where := Where + ' AND claimed_by = ?';
  if AFilter.Parent > 0 then
    Where := Where + ' AND parent = ?';
  SQL := 'SELECT ' + TaskColumns + ' FROM task_cards' + Where +
    ' ORDER BY position, updated_at DESC, id DESC';
  Lim := AFilter.Limit;
  if Lim <= 0 then
    Lim := 50;
  SQL := SQL + ' LIMIT ' + IntToStr(Lim);
  MineSid := AnsiString(AFilter.MineSession);
  FStore.Lock.Acquire;
  try
    if not Prepare(SQL, Stmt, AError) then
      Exit;
    try
      Idx := 2;
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      if AFilter.StatusSet then
      begin
        sqlite3_bind_int(Stmt, Idx, Ord(AFilter.Status));
        Inc(Idx);
      end;
      if AFilter.Mine then
      begin
        sqlite3_bind_text(Stmt, Idx, PAnsiChar(MineSid), -1, nil);
        Inc(Idx);
      end;
      if AFilter.Parent > 0 then
        sqlite3_bind_int(Stmt, Idx, AFilter.Parent);
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(ACards, N + 1);
        Fill(Stmt, ACards[N]);
        Inc(N);
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Claim(AWorkspaceId, AId: Integer; const ABy: string;
  var APrevious: TTaskCard; out AClaimed, AFound: Boolean;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  By: AnsiString;
  Now2: Int64;
begin
  { THE CAS. One statement, guarded on the status: sqlite3_changes decides who
    won, and a loser re-reads the row to name the holder. }
  Result := False;
  AClaimed := False;
  AFound := False;
  AError := '';
  By := AnsiString(ABy);
  Now2 := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE task_cards SET status = ?, claimed_by = ?, ' +
      'claimed_at = ?, status_at = ?, updated_at = ? WHERE workspace_id = ? ' +
      'AND id = ? AND status = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, Ord(tsClaimed));
      sqlite3_bind_text(Stmt, 2, PAnsiChar(By), -1, nil);
      sqlite3_bind_int64(Stmt, 3, Now2);
      sqlite3_bind_int64(Stmt, 4, Now2);
      sqlite3_bind_int64(Stmt, 5, Now2);
      sqlite3_bind_int(Stmt, 6, AWorkspaceId);
      sqlite3_bind_int(Stmt, 7, AId);
      sqlite3_bind_int(Stmt, 8, Ord(tsOpen));
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not claim';
        Exit;
      end;
      AClaimed := sqlite3_changes(FStore.Db) = 1;
    finally
      sqlite3_finalize(Stmt);
    end;
    { Whoever calls, the row is read back: the loser needs the holder, and the
      winner needs to know the card existed at all. }
    Result := Get(AWorkspaceId, AId, APrevious, AFound, AError);
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Transition(AWorkspaceId, AId: Integer;
  AFrom, ATo: TTaskStatus; const ABy: string; ABlockedOnId: Integer;
  ABlockedOnKind: TBlockerKind; const ADoneNote: string;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  By, Note: AnsiString;
  Now2: Int64;
  SQL: string;
  Cur: TTaskCard;
  Found: Boolean;
  ReadErr: string;
begin
  { The same guard shape as Claim: AND status = AFrom, and - unless this is an
    operator action, marked by an empty ABy - AND claimed_by = ABy, so a stale
    actor cannot drive a card it no longer owns. }
  Result := False;
  AError := '';
  { The status guard is not the transition table. It says the row is in AFrom;
    it does not say ATo is reachable from it. An operator action (ABy = '')
    drops the claimed_by half entirely, leaving only that guard - which would
    let done -> claimed reopen a finished card. The table is the contract, so it
    is checked here rather than trusted to the WHERE clause. }
  if not IsLegalTransition(AFrom, ATo) then
  begin
    if Get(AWorkspaceId, AId, Cur, Found, ReadErr) and Found then
      AError := 'a ' + TaskStatusToName(Cur.Status) + ' card cannot become ' +
        TaskStatusToName(ATo) + '; from ' + TaskStatusToName(Cur.Status) +
        ' the verbs are: ' + LegalTransitionsFrom(Cur.Status)
    else
      AError := 'a ' + TaskStatusToName(AFrom) + ' card cannot become ' +
        TaskStatusToName(ATo) + '; from ' + TaskStatusToName(AFrom) +
        ' the verbs are: ' + LegalTransitionsFrom(AFrom);
    Exit;
  end;
  { Claiming is the CAS's job: only Claim stamps claimed_by and claimed_at. A
    transition here would set the status without the holder, leaving a card that
    counts as taken and that nobody can release. }
  if (AFrom = tsOpen) and (ATo = tsClaimed) then
  begin
    AError := 'use task_claim to claim a card: it records who holds it and when';
    Exit;
  end;
  By := AnsiString(ABy);
  Note := AnsiString(ADoneNote);
  Now2 := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
  FStore.Lock.Acquire;
  try
    SQL := 'UPDATE task_cards SET status = ?, status_at = ?, updated_at = ?, ' +
      'done_note = ?, blocked_on_id = ?, blocked_on_kind = ?';
    { A transition away from the claim clears it, so an unclaimed card does not
      keep a stale holder. }
    if ATo in [tsOpen, tsDone, tsDropped] then
      SQL := SQL + ', claimed_by = '''', claimed_at = 0';
    SQL := SQL + ' WHERE workspace_id = ? AND id = ? AND status = ?';
    if ABy <> '' then
    begin
      { The spec's drop guard is "claimed by me, OR unclaimed": an agent
        abandoning work nobody picked up is normal. Every other verb is
        claim-only. Without the OR, an unclaimed card could never be dropped,
        because its holder is ''. }
      if ATo = tsDropped then
        SQL := SQL + ' AND (claimed_by = ? OR claimed_by = '''')'
      else
        SQL := SQL + ' AND claimed_by = ?';
    end;
    if not Prepare(SQL, Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, Ord(ATo));
      sqlite3_bind_int64(Stmt, 2, Now2);
      sqlite3_bind_int64(Stmt, 3, Now2);
      sqlite3_bind_text(Stmt, 4, PAnsiChar(Note), -1, nil);
      sqlite3_bind_int(Stmt, 5, ABlockedOnId);
      sqlite3_bind_int(Stmt, 6, Ord(ABlockedOnKind));
      sqlite3_bind_int(Stmt, 7, AWorkspaceId);
      sqlite3_bind_int(Stmt, 8, AId);
      sqlite3_bind_int(Stmt, 9, Ord(AFrom));
      if ABy <> '' then
        sqlite3_bind_text(Stmt, 10, PAnsiChar(By), -1, nil);
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not transition';
        Exit;
      end;
      Result := sqlite3_changes(FStore.Db) = 1;
      if not Result then
      begin
        { Name what is actually true. "Wrong state" and "not yours" are the two
          ways this fails, and an agent can act on the difference. }
        if Get(AWorkspaceId, AId, Cur, Found, ReadErr) and Found then
        begin
          AError := 'the card is not in the expected state, or is not yours: ' +
            'it is ' + TaskStatusToName(Cur.Status);
          if Cur.ClaimedBy <> '' then
            AError := AError + ', held by ' + Cur.ClaimedBy;
        end
        else
          AError := 'no task card ' + IntToStr(AId) + ' in this workspace';
      end;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Edit(AWorkspaceId, AId: Integer;
  const ATitle, ABody: string; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Title, Body: AnsiString;
begin
  { Text only. Status is deliberately not writable here: every transition is a
    verb with an actor, so the row can answer "who moved this and why". }
  Result := False;
  AError := '';
  Title := AnsiString(ATitle);
  Body := AnsiString(ABody);
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE task_cards SET title = ?, body = ?, updated_at = ? ' +
      'WHERE workspace_id = ? AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Title), -1, nil);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Body), -1, nil);
      sqlite3_bind_int64(Stmt, 3,
        Round((Now - EncodeDate(1970, 1, 1)) * 86400));
      sqlite3_bind_int(Stmt, 4, AWorkspaceId);
      sqlite3_bind_int(Stmt, 5, AId);
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not edit';
        Exit;
      end;
      { An UPDATE that matched nothing is a silent no-op, and the spec says an
        unknown id is an error naming the id. sqlite3_changes is the only way to
        tell "edited" from "there was nothing there". }
      Result := sqlite3_changes(FStore.Db) = 1;
      if not Result then
        AError := 'no task card ' + IntToStr(AId) + ' in this workspace';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Delete(AWorkspaceId, AId: Integer;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  AError := '';
  FStore.Lock.Acquire;
  try
    if not Prepare('DELETE FROM task_cards WHERE workspace_id = ? AND id = ?',
      Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, AId);
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not delete';
        Exit;
      end;
      Result := sqlite3_changes(FStore.Db) = 1;
      if not Result then
        AError := 'no task card ' + IntToStr(AId) + ' in this workspace';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Prune(AWorkspaceId, AKeepDone: Integer;
  AMaxAgeSec: Int64; out APruned: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Cutoff: Int64;

  { Both rules share the same two exclusions. A card another card names as its
    parent or its blocker is never pruned, however finished it is: the reference
    would dangle, and the blocked card would point at nothing. }
  function Exclusions: string;
  begin
    Result :=
      ' AND id NOT IN (SELECT parent FROM task_cards WHERE workspace_id = ? ' +
      'AND parent <> 0)' +
      ' AND id NOT IN (SELECT blocked_on_id FROM task_cards ' +
      'WHERE workspace_id = ? AND blocked_on_kind = ?)';
  end;

  function BindExclusions(const AStmt: Psqlite3_stmt; AFirst: Integer): Integer;
  begin
    sqlite3_bind_int(AStmt, AFirst, AWorkspaceId);
    sqlite3_bind_int(AStmt, AFirst + 1, AWorkspaceId);
    sqlite3_bind_int(AStmt, AFirst + 2, Ord(tbkCard));
    Result := AFirst + 3;
  end;

begin
  { Finished cards only, by age AND by count. The two catch different things: age
    bounds the clock, count bounds the table - a burst of cards finished in one
    afternoon is exactly the case age cannot see. }
  Result := False;
  APruned := 0;
  AError := '';
  FStore.Lock.Acquire;
  try
    if AMaxAgeSec > 0 then
    begin
      Cutoff := Round((Now - EncodeDate(1970, 1, 1)) * 86400) - AMaxAgeSec;
      if not Prepare('DELETE FROM task_cards WHERE workspace_id = ? ' +
        'AND status IN (?, ?) AND updated_at < ?' + Exclusions, Stmt,
        AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_int(Stmt, 2, Ord(tsDone));
        sqlite3_bind_int(Stmt, 3, Ord(tsDropped));
        sqlite3_bind_int64(Stmt, 4, Cutoff);
        BindExclusions(Stmt, 5);
        if sqlite3_step(Stmt) = SQLITE_DONE then
          APruned := sqlite3_changes(FStore.Db);
      finally
        sqlite3_finalize(Stmt);
      end;
    end;
    { AKeepDone <= 0 keeps none, which is what a test asks for to prove the rule
      can see a card at all. The newest survive: a card finished five minutes ago
      is still the context someone needs to pick the thread back up. }
    if AKeepDone >= 0 then
    begin
      if not Prepare('DELETE FROM task_cards WHERE workspace_id = ? ' +
        'AND status IN (?, ?)' +
        ' AND id NOT IN (SELECT id FROM task_cards WHERE workspace_id = ? ' +
        'AND status IN (?, ?) ORDER BY updated_at DESC, id DESC LIMIT ?)' +
        Exclusions, Stmt, AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_int(Stmt, 2, Ord(tsDone));
        sqlite3_bind_int(Stmt, 3, Ord(tsDropped));
        sqlite3_bind_int(Stmt, 4, AWorkspaceId);
        sqlite3_bind_int(Stmt, 5, Ord(tsDone));
        sqlite3_bind_int(Stmt, 6, Ord(tsDropped));
        sqlite3_bind_int(Stmt, 7, AKeepDone);
        BindExclusions(Stmt, 8);
        if sqlite3_step(Stmt) = SQLITE_DONE then
          APruned := APruned + sqlite3_changes(FStore.Db);
      finally
        sqlite3_finalize(Stmt);
      end;
    end;
    Result := True;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.Mine(AWorkspaceId: Integer; const ASessionId: string;
  out ACards: TTaskCardArray; out AError: string): Boolean;
var
  F: TTaskFilter;
begin
  F := Default(TTaskFilter);
  F.Mine := True;
  F.MineSession := ASessionId;
  F.Limit := 5;
  Result := List(AWorkspaceId, F, ACards, AError);
end;

function TSqliteTaskStore.OpenCards(AWorkspaceId, ALimit: Integer;
  out ACards: TTaskCardArray; out AError: string): Boolean;
var
  F: TTaskFilter;
begin
  F := Default(TTaskFilter);
  F.Status := tsOpen;
  F.StatusSet := True;
  F.Limit := ALimit;
  Result := List(AWorkspaceId, F, ACards, AError);
end;

function TSqliteTaskStore.OpenCount(AWorkspaceId: Integer; out ACount: Integer;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  ACount := 0;
  AError := '';
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT COUNT(*) FROM task_cards WHERE workspace_id = ? ' +
      'AND status = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, Ord(tsOpen));
      if sqlite3_step(Stmt) = SQLITE_ROW then
        ACount := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.ReclaimedFrom(AWorkspaceId: Integer;
  const ASessionId: string; out ACards: TTaskCardArray; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Pat: AnsiString;
  N: Integer;
begin
  { ReclaimStale writes "claim recovered from <session> after it went stale" into
    done_note, so the former holder is recoverable without a new column. Only OPEN
    cards count: once someone re-claims it, the loss is no longer news. }
  Result := False;
  ACards := nil;
  AError := '';
  if ASessionId = '' then
  begin
    Result := True;
    Exit;
  end;
  Pat := AnsiString('claim recovered from ' + ASessionId + ' ');
  N := 0;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' + TaskColumns + ' FROM task_cards ' +
      'WHERE workspace_id = ? AND status = ? AND done_note LIKE ? ' +
      'ORDER BY id', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, Ord(tsOpen));
      sqlite3_bind_text(Stmt, 3, PAnsiChar(Pat), -1, nil);
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(ACards, N + 1);
        Fill(Stmt, ACards[N]);
        Inc(N);
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.BlockedCards(AWorkspaceId, ALimit: Integer;
  out ACards: TTaskCardArray; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  N, Lim: Integer;
begin
  { Oldest first: the tail shows a block because it has sat too long, so the
    longest-waiting is the one worth naming. }
  Result := False;
  ACards := nil;
  AError := '';
  N := 0;
  Lim := ALimit;
  if Lim <= 0 then
    Lim := 3;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' + TaskColumns + ' FROM task_cards ' +
      'WHERE workspace_id = ? AND status = ? ORDER BY status_at, id LIMIT ' +
      IntToStr(Lim), Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, Ord(tsBlocked));
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(ACards, N + 1);
        Fill(Stmt, ACards[N]);
        Inc(N);
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.RenewClaims(AWorkspaceId: Integer;
  const ABy: string; out ARenewed: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  By: AnsiString;
  Now2: Int64;
begin
  { Renewal is what makes "is this claim alive?" answerable without a background
    heartbeat: an agent that is working opens turns, and the turn boundary calls
    this. Only claimed cards are touched - a blocked card is still yours, but its
    claimed_at is not what the recovery rule reads. }
  Result := False;
  ARenewed := 0;
  AError := '';
  By := AnsiString(ABy);
  Now2 := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE task_cards SET claimed_at = ? WHERE workspace_id = ? ' +
      'AND claimed_by = ? AND status = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int64(Stmt, 1, Now2);
      sqlite3_bind_int(Stmt, 2, AWorkspaceId);
      sqlite3_bind_text(Stmt, 3, PAnsiChar(By), -1, nil);
      sqlite3_bind_int(Stmt, 4, Ord(tsClaimed));
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not renew claims';
        Exit;
      end;
      ARenewed := sqlite3_changes(FStore.Db);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteTaskStore.ReclaimStale(AWorkspaceId: Integer;
  AMaxAgeSec: Integer; out AReclaimed: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Cutoff: Int64;
begin
  { The recovery half. A claim is a statement, not a lock, so a session that dies
    mid-card holds it indefinitely - and task_reassign needs the operator, who may
    not be there. This releases such a claim back to open and records who held it,
    so the next agent sees abandoned work rather than a card that looks taken.

    Never a fresh claim (someone is working), never an unclaimed card, never a
    finished one. The note names the holder because a card silently reappearing as
    open loses the fact that anyone had it. }
  Result := False;
  AReclaimed := 0;
  AError := '';
  if AMaxAgeSec <= 0 then
  begin
    AError := 'a reclaim threshold must be positive';
    Exit;
  end;
  Cutoff := Round((Now - EncodeDate(1970, 1, 1)) * 86400) - AMaxAgeSec;
  FStore.Lock.Acquire;
  try
    { Two ways a claim is reclaimable, and they answer DIFFERENT questions:

      1. The holder is DEAD - no live runtime row. That is an existence fact we
         can now observe, so it needs no waiting: reclaim immediately.
      2. The holder is ALIVE but has not renewed within the lease. That is
         abandonment, an intent fact we must still infer from elapsed time.

      Before the heartbeat existed, (1) was unobservable and the lease carried
      both jobs - which made a session that simply THOUGHT for longer than the
      lease lose its card. Liveness fixes that without weakening (2). }
    if not Prepare('UPDATE task_cards SET status = ?, claimed_by = '''', ' +
      'claimed_at = 0, status_at = ?, updated_at = ?, ' +
      'done_note = ''claim recovered from '' || claimed_by || ' +
      ''' after it went stale'' WHERE workspace_id = ? AND status = ? ' +
      'AND ( claimed_at < ? OR claimed_by NOT IN ' +
      '(SELECT session_id FROM session_runtimes) )', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, Ord(tsOpen));
      sqlite3_bind_int64(Stmt, 2,
        Round((Now - EncodeDate(1970, 1, 1)) * 86400));
      sqlite3_bind_int64(Stmt, 3,
        Round((Now - EncodeDate(1970, 1, 1)) * 86400));
      sqlite3_bind_int(Stmt, 4, AWorkspaceId);
      sqlite3_bind_int(Stmt, 5, Ord(tsClaimed));
      sqlite3_bind_int64(Stmt, 6, Cutoff);
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        AError := 'task store: could not reclaim';
        Exit;
      end;
      AReclaimed := sqlite3_changes(FStore.Db);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

end.
