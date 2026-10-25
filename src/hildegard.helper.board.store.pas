unit hildegard.helper.board.store;
{ The SQLite implementation of the board's persistence.

  The board is append-only, so this adapter is mostly INSERT and SELECT. The one
  subtle query is CurrentOf: the newest live entry in a topic that nothing else
  supersedes. That is a NOT IN over the same table, which is exact and needs no
  chain walk. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.sqlite, hildegard.helper.store,
  hildegard.helper.board;

type
  IBoardStore = interface
    ['{A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D}']
    function Append(const AEntry: TBoardEntry; out AId: Integer;
      out AError: string): Boolean;
    function Read(AWorkspaceId: Integer; const AFilter: TBoardFilter;
      out AEntries: TBoardEntryArray; out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out AEntry: TBoardEntry;
      out AFound: Boolean; out AError: string): Boolean;
    { The newest live, non-superseded entry in a topic: what "current" means. }
    function CurrentOf(AWorkspaceId: Integer; const ATopic: string;
      out AEntry: TBoardEntry; out AFound: Boolean; out AError: string): Boolean;
    function MarkDeleted(AWorkspaceId, AId: Integer; ADeleted: Boolean;
      const ABy: string; out AError: string): Boolean;
    function SetPinned(AWorkspaceId, AId: Integer; APinned: Boolean;
      out AError: string): Boolean;
    function Move(AWorkspaceId, AId: Integer; const ATopic: string;
      out AError: string): Boolean;
    { Topic locks: moderation, and the reason a post can be refused. }
    function Lock(AWorkspaceId: Integer; const ATopic, ABy: string;
      ALocked: Boolean; out AError: string): Boolean;
    function IsLocked(AWorkspaceId: Integer; const ATopic: string;
      out ALockedBy: string; out AError: string): Boolean;
    { Counts for the tail, in one query. }
    function Toc(AWorkspaceId, ASinceId: Integer; out AUnread, AQuestions,
      ADecisions, AFindings: Integer; out ALastAt: Int64;
      out AError: string): Boolean;
    function CursorOf(const ASessionId: string; out AId: Integer;
      out AError: string): Boolean;
    function SetCursor(const ASessionId: string; AId: Integer;
      out AError: string): Boolean;
    { When this session's cursor last moved, as epoch seconds. 0 when unknown (a
      row from before v16, or a session that has never read). Separate from
      CursorOf so its five call sites keep their shape. }
    function CursorLastSeenOf(const ASessionId: string; out ALastSeen: Int64;
      out AError: string): Boolean;
    { The highest board id in this workspace, 0 when the board is empty. Used so a
      NEW session starts CURRENT: it did not miss anything, it was not there. }
    function BoardMaxId(AWorkspaceId: Integer; out AId: Integer;
      out AError: string): Boolean;
    { How many entries ASessionId has not read, for a PEER's benefit.

      A different question from the TOC: the TOC tells a session about its OWN
      unread and runs every tick. This is asked ABOUT another session, on demand -
      by a dashboard, or when deciding whether to mention a peer has fallen
      behind. Never per tick per session.

      Returns 0 for a session with no cursor, because a session that has never
      read is NEW, not behind. }
    function UnreadFor(const ASessionId: string; out AUnread: Integer;
      out AError: string): Boolean;
    { Retention: drop finished noise, never knowledge. `note` and `status` are
      pruned by count and age; `decision`, `finding`, `question` and `answer` are
      never touched. A memory system that forgets its decisions is not one. }
    function Prune(AWorkspaceId, AKeepNotes: Integer;
      AMaxAgeSec: Int64; out APruned: Integer; out AError: string): Boolean;
    { Full-text search over titles, bodies and topics. An empty result is a
      success, not a miss - the caller decides what "nothing found" means. }
    function Search(AWorkspaceId: Integer; const AQuery: string; ALimit: Integer;
      out AEntries: TBoardEntryArray; out AError: string): Boolean;
    { Changes to APaths since ASinceEpochSec: the staleness annotation. }
    function ChangedSince(AWorkspaceId: Integer; ASinceEpochSec: Int64;
      const APaths: TStringArrayLite; out ACount: Integer;
      out AError: string): Boolean;
  end;

type
  TSqliteBoardStore = class(TInterfacedObject, IBoardStore)
  private
    FStore: TSqliteStore;
    function Prepare(const ASQL: string; out AStmt: Psqlite3_stmt;
      out AError: string): Boolean;
    procedure Fill(const AStmt: Psqlite3_stmt; out AEntry: TBoardEntry);
  public
    constructor Create(AStore: TSqliteStore);
    function Append(const AEntry: TBoardEntry; out AId: Integer;
      out AError: string): Boolean;
    function Read(AWorkspaceId: Integer; const AFilter: TBoardFilter;
      out AEntries: TBoardEntryArray; out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out AEntry: TBoardEntry;
      out AFound: Boolean; out AError: string): Boolean;
    function CurrentOf(AWorkspaceId: Integer; const ATopic: string;
      out AEntry: TBoardEntry; out AFound: Boolean; out AError: string): Boolean;
    function MarkDeleted(AWorkspaceId, AId: Integer; ADeleted: Boolean;
      const ABy: string; out AError: string): Boolean;
    function SetPinned(AWorkspaceId, AId: Integer; APinned: Boolean;
      out AError: string): Boolean;
    function Move(AWorkspaceId, AId: Integer; const ATopic: string;
      out AError: string): Boolean;
    function Lock(AWorkspaceId: Integer; const ATopic, ABy: string;
      ALocked: Boolean; out AError: string): Boolean;
    function IsLocked(AWorkspaceId: Integer; const ATopic: string;
      out ALockedBy: string; out AError: string): Boolean;
    function Toc(AWorkspaceId, ASinceId: Integer; out AUnread, AQuestions,
      ADecisions, AFindings: Integer; out ALastAt: Int64;
      out AError: string): Boolean;
    function CursorOf(const ASessionId: string; out AId: Integer;
      out AError: string): Boolean;
    function SetCursor(const ASessionId: string; AId: Integer;
      out AError: string): Boolean;
    { When this session's cursor last moved, as epoch seconds. 0 when unknown (a
      row from before v16, or a session that has never read). Separate from
      CursorOf so its five call sites keep their shape. }
    function CursorLastSeenOf(const ASessionId: string; out ALastSeen: Int64;
      out AError: string): Boolean;
    { The highest board id in this workspace, 0 when the board is empty. Used so a
      NEW session starts CURRENT: it did not miss anything, it was not there. }
    function BoardMaxId(AWorkspaceId: Integer; out AId: Integer;
      out AError: string): Boolean;
    { How many entries ASessionId has not read, for a PEER's benefit.

      A different question from the TOC: the TOC tells a session about its OWN
      unread and runs every tick. This is asked ABOUT another session, on demand -
      by a dashboard, or when deciding whether to mention a peer has fallen
      behind. Never per tick per session.

      Returns 0 for a session with no cursor, because a session that has never
      read is NEW, not behind. }
    function UnreadFor(const ASessionId: string; out AUnread: Integer;
      out AError: string): Boolean;
    function Prune(AWorkspaceId, AKeepNotes: Integer;
      AMaxAgeSec: Int64; out APruned: Integer; out AError: string): Boolean;
    function Search(AWorkspaceId: Integer; const AQuery: string;
      ALimit: Integer; out AEntries: TBoardEntryArray;
      out AError: string): Boolean;
    function ChangedSince(AWorkspaceId: Integer; ASinceEpochSec: Int64;
      const APaths: TStringArrayLite; out ACount: Integer;
      out AError: string): Boolean;
  end;

const
  BoardColumns = 'id, workspace_id, from_session, from_label, kind, topic, ' +
    'title, body, reply_to, supersedes, paths, deleted_at, deleted_by, pinned, ' +
    'created_at';

implementation

constructor TSqliteBoardStore.Create(AStore: TSqliteStore);
begin
  inherited Create;
  FStore := AStore;
end;

function TSqliteBoardStore.Prepare(const ASQL: string;
  out AStmt: Psqlite3_stmt; out AError: string): Boolean;
begin
  AStmt := nil;
  AError := '';
  Result := (FStore <> nil) and (FStore.Db <> nil) and
    (sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(ASQL)), -1, @AStmt,
      nil) = 0);
  if not Result then
    AError := 'board store: could not prepare a statement';
end;

procedure TSqliteBoardStore.Fill(const AStmt: Psqlite3_stmt;
  out AEntry: TBoardEntry);
var
  S: PAnsiChar;
begin
  AEntry := Default(TBoardEntry);
  AEntry.Id := sqlite3_column_int(AStmt, 0);
  AEntry.WorkspaceId := sqlite3_column_int(AStmt, 1);
  S := sqlite3_column_text(AStmt, 2);
  if S <> nil then AEntry.FromSession := AnsiString(S);
  S := sqlite3_column_text(AStmt, 3);
  if S <> nil then AEntry.FromLabel := AnsiString(S);
  AEntry.Kind := TBoardKind(sqlite3_column_int(AStmt, 4));
  S := sqlite3_column_text(AStmt, 5);
  if S <> nil then AEntry.Topic := AnsiString(S);
  S := sqlite3_column_text(AStmt, 6);
  if S <> nil then AEntry.Title := AnsiString(S);
  S := sqlite3_column_text(AStmt, 7);
  if S <> nil then AEntry.Body := AnsiString(S);
  AEntry.ReplyTo := sqlite3_column_int(AStmt, 8);
  AEntry.Supersedes := sqlite3_column_int(AStmt, 9);
  S := sqlite3_column_text(AStmt, 10);
  if S <> nil then AEntry.Paths := TextToPaths(AnsiString(S));
  AEntry.DeletedAt := sqlite3_column_int64(AStmt, 11);
  S := sqlite3_column_text(AStmt, 12);
  if S <> nil then AEntry.DeletedBy := AnsiString(S);
  AEntry.Pinned := sqlite3_column_int(AStmt, 13) <> 0;
  AEntry.CreatedAt := sqlite3_column_int64(AStmt, 14);
end;

function TSqliteBoardStore.Append(const AEntry: TBoardEntry;
  out AId: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  FromSession, FromLabel, Topic, Title, Body, Paths, DeletedBy: AnsiString;
begin
  Result := False;
  AId := 0;
  FromSession := AnsiString(AEntry.FromSession);
  FromLabel := AnsiString(AEntry.FromLabel);
  Topic := AnsiString(AEntry.Topic);
  Title := AnsiString(AEntry.Title);
  Body := AnsiString(AEntry.Body);
  Paths := AnsiString(PathsToText(AEntry.Paths));
  DeletedBy := '';
  FStore.Lock.Acquire;
  try
    if not Prepare('INSERT INTO board_entries (workspace_id, from_session, ' +
      'from_label, kind, topic, title, body, reply_to, supersedes, paths, ' +
      'deleted_at, deleted_by, pinned, created_at) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, '''', 0, ?)', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AEntry.WorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(FromSession), -1, nil);
      sqlite3_bind_text(Stmt, 3, PAnsiChar(FromLabel), -1, nil);
      sqlite3_bind_int(Stmt, 4, Ord(AEntry.Kind));
      sqlite3_bind_text(Stmt, 5, PAnsiChar(Topic), -1, nil);
      sqlite3_bind_text(Stmt, 6, PAnsiChar(Title), -1, nil);
      sqlite3_bind_text(Stmt, 7, PAnsiChar(Body), -1, nil);
      sqlite3_bind_int(Stmt, 8, AEntry.ReplyTo);
      sqlite3_bind_int(Stmt, 9, AEntry.Supersedes);
      sqlite3_bind_text(Stmt, 10, PAnsiChar(Paths), -1, nil);
      sqlite3_bind_int64(Stmt, 11, AEntry.CreatedAt);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if Result then
        AId := Integer(sqlite3_last_insert_rowid(FStore.Db))
      else
        AError := 'board store: could not append';
    finally
      sqlite3_finalize(Stmt);
    end;
    { Index the entry in the same critical section, so a search never sees a row
      the board does not (the same discipline messages_fts follows). A failure
      here does not fail the append: an unindexed entry is still readable. }
    if Result then
    begin
      Stmt := nil;
      if Prepare('INSERT INTO board_fts (title, body, topic, session_id, ' +
        'entry_id) VALUES (?, ?, ?, ?, ?)', Stmt, AError) then
      try
        sqlite3_bind_text(Stmt, 1, PAnsiChar(Title), -1, nil);
        sqlite3_bind_text(Stmt, 2, PAnsiChar(Body), -1, nil);
        sqlite3_bind_text(Stmt, 3, PAnsiChar(Topic), -1, nil);
        sqlite3_bind_text(Stmt, 4, PAnsiChar(FromSession), -1, nil);
        sqlite3_bind_int(Stmt, 5, AId);
        sqlite3_step(Stmt);
      finally
        sqlite3_finalize(Stmt);
      end;
      AError := '';          { a search-index miss is not an append failure }
    end;
    if DeletedBy = '' then ;   // keeps the unused local honest under -Sew
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.Read(AWorkspaceId: Integer;
  const AFilter: TBoardFilter; out AEntries: TBoardEntryArray;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  SQL, Where: string;
  Topic: AnsiString;
  N, Lim, Idx: Integer;
begin
  Result := False;
  AEntries := nil;
  N := 0;
  Where := ' WHERE workspace_id = ?';
  if not AFilter.IncludeDeleted then
    Where := Where + ' AND deleted_at = 0';
  if AFilter.Topic <> '' then
    Where := Where + ' AND topic = ?';
  if AFilter.KindSet then
    Where := Where + ' AND kind = ?';
  if AFilter.SinceId > 0 then
    Where := Where + ' AND id > ?';
  if AFilter.PinnedOnly then
    Where := Where + ' AND pinned <> 0';
  SQL := 'SELECT ' + BoardColumns + ' FROM board_entries' + Where +
    ' ORDER BY id DESC';
  Lim := AFilter.Limit;
  if Lim <= 0 then
    Lim := DefaultBoardReadLimit;
  SQL := SQL + ' LIMIT ' + IntToStr(Lim);
  Topic := AnsiString(AFilter.Topic);
  FStore.Lock.Acquire;
  try
    if not Prepare(SQL, Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      { Bound positionally to the WHERE clause as built: index 1 is always the
        workspace, then each optional clause takes the next slot in order. }
      Idx := 2;
      if AFilter.Topic <> '' then
      begin
        sqlite3_bind_text(Stmt, Idx, PAnsiChar(Topic), -1, nil);
        Inc(Idx);
      end;
      if AFilter.KindSet then
      begin
        sqlite3_bind_int(Stmt, Idx, Ord(AFilter.Kind));
        Inc(Idx);
      end;
      if AFilter.SinceId > 0 then
        sqlite3_bind_int(Stmt, Idx, AFilter.SinceId);
      while sqlite3_step(Stmt) = SQLite_ROW do
      begin
        SetLength(AEntries, N + 1);
        Fill(Stmt, AEntries[N]);
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

function TSqliteBoardStore.Get(AWorkspaceId, AId: Integer;
  out AEntry: TBoardEntry; out AFound: Boolean;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  AEntry := Default(TBoardEntry);
  AFound := False;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' + BoardColumns + ' FROM board_entries ' +
      'WHERE workspace_id = ? AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, AId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        Fill(Stmt, AEntry);
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

function TSqliteBoardStore.CurrentOf(AWorkspaceId: Integer;
  const ATopic: string; out AEntry: TBoardEntry; out AFound: Boolean;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Topic: AnsiString;
begin
  { The newest live entry in the topic that no other live entry supersedes. A
    NOT IN over the same table, so supersession stays a pointer and no chain walk
    is needed. }
  Result := False;
  AEntry := Default(TBoardEntry);
  AFound := False;
  Topic := AnsiString(ATopic);
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' + BoardColumns + ' FROM board_entries ' +
      'WHERE workspace_id = ? AND topic = ? AND deleted_at = 0 ' +
      'AND id NOT IN (SELECT supersedes FROM board_entries ' +
      'WHERE workspace_id = ? AND deleted_at = 0 AND supersedes <> 0) ' +
      'ORDER BY id DESC LIMIT 1', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Topic), -1, nil);
      sqlite3_bind_int(Stmt, 3, AWorkspaceId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        Fill(Stmt, AEntry);
        AEntry.Current := True;
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

function TSqliteBoardStore.MarkDeleted(AWorkspaceId, AId: Integer;
  ADeleted: Boolean; const ABy: string; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  By: AnsiString;
begin
  Result := False;
  By := AnsiString(ABy);
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE board_entries SET deleted_at = ?, deleted_by = ? ' +
      'WHERE workspace_id = ? AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int64(Stmt, 1, Ord(ADeleted));
      sqlite3_bind_text(Stmt, 2, PAnsiChar(By), -1, nil);
      sqlite3_bind_int(Stmt, 3, AWorkspaceId);
      sqlite3_bind_int(Stmt, 4, AId);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if not Result then
        AError := 'board store: could not update';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.SetPinned(AWorkspaceId, AId: Integer;
  APinned: Boolean; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE board_entries SET pinned = ? WHERE workspace_id = ? ' +
      'AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, Ord(APinned));
      sqlite3_bind_int(Stmt, 2, AWorkspaceId);
      sqlite3_bind_int(Stmt, 3, AId);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.Move(AWorkspaceId, AId: Integer;
  const ATopic: string; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Topic: AnsiString;
begin
  { Re-topics an entry. Append-only is not violated: the entry's text, author and
    timestamp are untouched, only which page it belongs to. The caller decides
    whether that is allowed (a locked topic refuses it). }
  Result := False;
  AError := '';
  if Trim(ATopic) = '' then
  begin
    AError := 'move needs a topic';
    Exit;
  end;
  Topic := AnsiString(ATopic);
  FStore.Lock.Acquire;
  try
    if not Prepare('UPDATE board_entries SET topic = ? WHERE workspace_id = ? ' +
      'AND id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Topic), -1, nil);
      sqlite3_bind_int(Stmt, 2, AWorkspaceId);
      sqlite3_bind_int(Stmt, 3, AId);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if not Result then
        AError := 'board store: could not move';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.Lock(AWorkspaceId: Integer; const ATopic,
  ABy: string; ALocked: Boolean; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Topic, By: AnsiString;
begin
  Result := False;
  Topic := AnsiString(ATopic);
  By := AnsiString(ABy);
  FStore.Lock.Acquire;
  try
    if ALocked then
    begin
      if not Prepare('INSERT OR REPLACE INTO board_lock (workspace_id, topic, ' +
        'locked_by, locked_at) VALUES (?, ?, ?, ?)', Stmt, AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_text(Stmt, 2, PAnsiChar(Topic), -1, nil);
        sqlite3_bind_text(Stmt, 3, PAnsiChar(By), -1, nil);
        sqlite3_bind_int64(Stmt, 4, 0);
        Result := sqlite3_step(Stmt) = SQLITE_DONE;
      finally
        sqlite3_finalize(Stmt);
      end;
    end
    else
    begin
      if not Prepare('DELETE FROM board_lock WHERE workspace_id = ? AND ' +
        'topic = ?', Stmt, AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_text(Stmt, 2, PAnsiChar(Topic), -1, nil);
        Result := sqlite3_step(Stmt) = SQLITE_DONE;
      finally
        sqlite3_finalize(Stmt);
      end;
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.IsLocked(AWorkspaceId: Integer;
  const ATopic: string; out ALockedBy: string; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Topic: AnsiString;
  S: PAnsiChar;
begin
  { Returns True when the query succeeded; ALockedBy is '' when not locked. }
  Result := False;
  ALockedBy := '';
  Topic := AnsiString(ATopic);
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT locked_by FROM board_lock WHERE workspace_id = ? ' +
      'AND topic = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Topic), -1, nil);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        S := sqlite3_column_text(Stmt, 0);
        if S <> nil then
          ALockedBy := AnsiString(S);
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.Toc(AWorkspaceId, ASinceId: Integer;
  out AUnread, AQuestions, ADecisions, AFindings: Integer; out ALastAt: Int64;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  Result := False;
  AUnread := 0;
  AQuestions := 0;
  ADecisions := 0;
  AFindings := 0;
  ALastAt := 0;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT ' +
      'SUM(CASE WHEN id > ? THEN 1 ELSE 0 END), ' +
      { An answered question is not an open one. Counting it forever tells every
        agent that someone is waiting when nobody is - the count is what drives
        whether a model thinks it owes an answer, so it has to mean "still open".
        A DELETED answer does not count, so retracting one reopens the question. }
      'SUM(CASE WHEN kind = ? AND id NOT IN (' +
      '  SELECT reply_to FROM board_entries WHERE workspace_id = ? ' +
      '  AND reply_to <> 0 AND kind = ? AND deleted_at = 0' +
      ') THEN 1 ELSE 0 END), ' +
      'SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), ' +
      'SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), ' +
      'MAX(created_at) ' +
      'FROM board_entries WHERE workspace_id = ? AND deleted_at = 0',
      Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, ASinceId);
      sqlite3_bind_int(Stmt, 2, Ord(bkQuestion));
      sqlite3_bind_int(Stmt, 3, AWorkspaceId);
      sqlite3_bind_int(Stmt, 4, Ord(bkAnswer));
      sqlite3_bind_int(Stmt, 5, Ord(bkDecision));
      sqlite3_bind_int(Stmt, 6, Ord(bkFinding));
      sqlite3_bind_int(Stmt, 7, AWorkspaceId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        AUnread := sqlite3_column_int(Stmt, 0);
        AQuestions := sqlite3_column_int(Stmt, 1);
        ADecisions := sqlite3_column_int(Stmt, 2);
        AFindings := sqlite3_column_int(Stmt, 3);
        ALastAt := sqlite3_column_int64(Stmt, 4);
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.CursorOf(const ASessionId: string;
  out AId: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Sid: AnsiString;
begin
  Result := False;
  AId := 0;
  Sid := AnsiString(ASessionId);
  FStore.Lock.Acquire;
  try
    { last_seen_at is read separately: keeping CursorOf's shape avoids changing
      five call sites for a value only the revival path needs. 0 = unknown (a row
      from before v16). }
    if not Prepare('SELECT last_id FROM board_reads WHERE session_id = ?',
      Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Sid), -1, nil);
      if sqlite3_step(Stmt) = SQLITE_ROW then
        AId := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.SetCursor(const ASessionId: string; AId: Integer;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Sid: AnsiString;
begin
  Result := False;
  Sid := AnsiString(ASessionId);
  FStore.Lock.Acquire;
  try
    { last_seen_at is stamped on every cursor move: a cursor says WHERE a session
      had read to, the timestamp says WHEN. Without it a revived session cannot be
      told it was away. }
    if not Prepare('INSERT OR REPLACE INTO board_reads ' +
      '(session_id, last_id, last_seen_at) VALUES (?, ?, ?)', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Sid), -1, nil);
      sqlite3_bind_int(Stmt, 2, AId);
      sqlite3_bind_int64(Stmt, 3,
        Round((Now - EncodeDate(1970, 1, 1)) * 86400));
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.BoardMaxId(AWorkspaceId: Integer;
  out AId: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
begin
  { A NEW session starts CURRENT: it did not miss anything, it was not there.
    Greeting it with a backlog would be the same class of error as an invented
    unread count. }
  Result := False;
  AId := 0;
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT COALESCE(MAX(id), 0) FROM board_entries ' +
      'WHERE workspace_id = ?', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
        AId := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.UnreadFor(const ASessionId: string;
  out AUnread: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Sid: AnsiString;
begin
  { Asked ABOUT a session, not by it - a dashboard or a peer-warning. The TOC
    answers the same shape for the ASKING session every tick; this is on demand
    for someone else, so it is deliberately NOT part of any tick.

    No cursor returns 0: a session that has never read is NEW, not behind. That
    is the same rule the new-session-starts-current fix applies. }
  Result := False;
  AUnread := 0;
  AError := '';
  Sid := AnsiString(ASessionId);
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT COUNT(*) FROM board_entries ' +
      'WHERE workspace_id = (SELECT workspace_id FROM board_reads ' +
      'WHERE session_id = ?) AND id > ' +
      '(SELECT last_id FROM board_reads WHERE session_id = ?) ' +
      'AND deleted_at = 0', Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Sid), -1, nil);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Sid), -1, nil);
      if sqlite3_step(Stmt) = SQLITE_ROW then
        AUnread := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.CursorLastSeenOf(const ASessionId: string;
  out ALastSeen: Int64; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Sid: AnsiString;
begin
  { 0 means unknown, never "now": a row written before v16, or a session that has
    never read, must not be mistaken for a session that is current. }
  Result := False;
  ALastSeen := 0;
  Sid := AnsiString(ASessionId);
  FStore.Lock.Acquire;
  try
    if not Prepare('SELECT last_seen_at FROM board_reads WHERE session_id = ?',
      Stmt, AError) then
      Exit;
    try
      sqlite3_bind_text(Stmt, 1, PAnsiChar(Sid), -1, nil);
      if sqlite3_step(Stmt) = SQLITE_ROW then
        ALastSeen := sqlite3_column_int64(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteBoardStore.Search(AWorkspaceId: Integer;
  const AQuery: string; ALimit: Integer; out AEntries: TBoardEntryArray;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Q: AnsiString;
  N, Lim: Integer;
begin
  { An empty query is a success with no rows: "search for nothing" is not an
    error, and the caller decides what an empty result means. }
  Result := False;
  AEntries := nil;
  AError := '';
  if Trim(AQuery) = '' then
  begin
    Result := True;
    Exit;
  end;
  Lim := ALimit;
  if Lim <= 0 then
    Lim := DefaultBoardReadLimit;
  Q := AnsiString(AQuery);
  N := 0;
  FStore.Lock.Acquire;
  try
    { Join back to the row so a hit returns a real entry, not just a snippet.
      Deleted entries stay out of results. }
    if not Prepare('SELECT ' + BoardColumns + ' FROM board_entries b ' +
      'WHERE b.workspace_id = ? AND b.deleted_at = 0 AND b.id IN (' +
      'SELECT entry_id FROM board_fts WHERE board_fts MATCH ?) ' +
      'ORDER BY b.id DESC LIMIT ' + IntToStr(Lim), Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(Q), -1, nil);
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(AEntries, N + 1);
        Fill(Stmt, AEntries[N]);
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

function TSqliteBoardStore.Prune(AWorkspaceId, AKeepNotes: Integer;
  AMaxAgeSec: Int64; out APruned: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Cutoff: Int64;
begin
  { Only the noise classes: note and status. Knowledge - decision, finding,
    question, answer - is never pruned, however old. A memory system that forgets
    its decisions is not one. }
  Result := False;
  APruned := 0;
  AError := '';
  FStore.Lock.Acquire;
  try
    { Age first: anything older than the window, whatever the count. }
    if AMaxAgeSec > 0 then
    begin
      Cutoff := AMaxAgeSec;
      if not Prepare('DELETE FROM board_entries WHERE workspace_id = ? ' +
        'AND deleted_at = 0 AND kind IN (?, ?) AND created_at < ?', Stmt,
        AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_int(Stmt, 2, Ord(bkNote));
        sqlite3_bind_int(Stmt, 3, Ord(bkStatus));
        sqlite3_bind_int64(Stmt, 4, Cutoff);
        if sqlite3_step(Stmt) = SQLITE_DONE then
          APruned := sqlite3_changes(FStore.Db);
      finally
        sqlite3_finalize(Stmt);
      end;
    end;
    { Then the count: keep the newest AKeepNotes of the noise classes. }
    if AKeepNotes > 0 then
    begin
      if not Prepare('DELETE FROM board_entries WHERE workspace_id = ? ' +
        'AND deleted_at = 0 AND kind IN (?, ?) AND id NOT IN (' +
        'SELECT id FROM board_entries WHERE workspace_id = ? ' +
        'AND deleted_at = 0 AND kind IN (?, ?) ORDER BY id DESC LIMIT ?)',
        Stmt, AError) then
        Exit;
      try
        sqlite3_bind_int(Stmt, 1, AWorkspaceId);
        sqlite3_bind_int(Stmt, 2, Ord(bkNote));
        sqlite3_bind_int(Stmt, 3, Ord(bkStatus));
        sqlite3_bind_int(Stmt, 4, AWorkspaceId);
        sqlite3_bind_int(Stmt, 5, Ord(bkNote));
        sqlite3_bind_int(Stmt, 6, Ord(bkStatus));
        sqlite3_bind_int(Stmt, 7, AKeepNotes);
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

function TSqliteBoardStore.ChangedSince(AWorkspaceId: Integer;
  ASinceEpochSec: Int64; const APaths: TStringArrayLite;
  out ACount: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  SQL, List: string;
  Bound: array of AnsiString;
  I: Integer;
begin
  Result := False;
  ACount := 0;
  if Length(APaths) = 0 then
  begin
    Result := True;
    Exit;
  end;
  List := '';
  SetLength(Bound, Length(APaths));
  for I := 0 to High(APaths) do
  begin
    if I > 0 then
      List := List + ', ';
    List := List + '?';
    Bound[I] := AnsiString(APaths[I]);
  end;
  SQL := 'SELECT COUNT(*) FROM file_changes WHERE workspace_id = ? ' +
    'AND created_at > ? AND path IN (' + List + ')';
  FStore.Lock.Acquire;
  try
    if not Prepare(SQL, Stmt, AError) then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int64(Stmt, 2, ASinceEpochSec);
      for I := 0 to High(Bound) do
        sqlite3_bind_text(Stmt, 3 + I, PAnsiChar(Bound[I]), -1, nil);
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

end.
