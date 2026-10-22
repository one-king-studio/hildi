unit hildegard.helper.changes.store;
{ The SQLite implementation of the changes library's IChangeStore.

  This lives in the harness, not the library: the library owns the model and the
  rules, the consumer owns the database. That is what keeps src/changes liftable
  and testable with TMemoryChangeStore.

  Every statement is prepared per call. That is deliberate: the adapter's methods
  are called once per tool call (not in a hot loop), and a prepared-statement
  cache would need lifetime management that buys nothing here. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.sqlite, hildegard.helper.store,
  changes.types, changes.store;

type
  TSqliteChangeStore = class(TInterfacedObject, IChangeStore)
  private
    FStore: TSqliteStore;
    procedure Fill(const AStmt: Psqlite3_stmt; out ARow: TChangeRecord);
  public
    constructor Create(AStore: TSqliteStore);
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
    function KeyframeBefore(AWorkspaceId: Integer; const APath: string;
      AChangeId: Integer; out AFrame: TKeyframe; out AFound: Boolean;
      out AError: string): Boolean;
    function PutKeyframe(const AFrame: TKeyframe; out AError: string): Boolean;
    function Prune(AWorkspaceId, AKeepFromId: Integer;
      out AError: string): Boolean;
    function NextId: Integer;
  end;

const
  SqlInsertChange =
    'INSERT INTO file_changes (workspace_id, session_id, turn_id, message_id, ' +
    'path, kind, before_hash, after_hash, patch, patch_bytes, capped, ' +
    'before_size, after_size, source, external_session, created_at) ' +
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

  SqlSelectChange =
    'SELECT id, workspace_id, session_id, turn_id, message_id, path, kind, ' +
    'before_hash, after_hash, patch, patch_bytes, capped, before_size, ' +
    'after_size, source, external_session, created_at FROM file_changes ';

implementation

{ Every method binds on a statement prepared from an AnsiString that must outlive
  the bind: sqlite3_bind_text does not copy. A local AnsiString per column keeps
  it valid until the statement is finalized. }
constructor TSqliteChangeStore.Create(AStore: TSqliteStore);
begin
  inherited Create;
  FStore := AStore;
end;

procedure TSqliteChangeStore.Fill(const AStmt: Psqlite3_stmt;
  out ARow: TChangeRecord);
var
  S: PAnsiChar;
begin
  ARow := Default(TChangeRecord);
  ARow.Id := sqlite3_column_int(AStmt, 0);
  ARow.WorkspaceId := sqlite3_column_int(AStmt, 1);
  S := sqlite3_column_text(AStmt, 2);
  if S <> nil then ARow.SessionId := AnsiString(S);
  ARow.TurnId := sqlite3_column_int(AStmt, 3);
  ARow.MessageId := sqlite3_column_int(AStmt, 4);
  S := sqlite3_column_text(AStmt, 5);
  if S <> nil then ARow.Path := AnsiString(S);
  ARow.Kind := TChangeKind(sqlite3_column_int(AStmt, 6));
  S := sqlite3_column_text(AStmt, 7);
  if S <> nil then ARow.BeforeHash := AnsiString(S);
  S := sqlite3_column_text(AStmt, 8);
  if S <> nil then ARow.AfterHash := AnsiString(S);
  S := sqlite3_column_text(AStmt, 9);
  if S <> nil then ARow.Patch := AnsiString(S);
  ARow.PatchBytes := sqlite3_column_int(AStmt, 10);
  ARow.Capped := sqlite3_column_int(AStmt, 11) <> 0;
  ARow.BeforeSize := sqlite3_column_int64(AStmt, 12);
  ARow.AfterSize := sqlite3_column_int64(AStmt, 13);
  ARow.Source := TChangeSource(sqlite3_column_int(AStmt, 14));
  S := sqlite3_column_text(AStmt, 15);
  if S <> nil then ARow.ExternalSession := AnsiString(S);
  ARow.CreatedAt := sqlite3_column_int64(AStmt, 16);
end;

function TSqliteChangeStore.Append(const ARecord: TChangeRecord;
  out AId: Integer; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  SessionId, Path, BeforeHash, AfterHash, Patch, ExtSession: AnsiString;
  Prepared: AnsiString;
begin
  Result := False;
  AId := 0;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
  begin
    AError := 'the store is not open';
    Exit;
  end;
  { Held for the duration: bind_text does not copy, so the AnsiStrings must
    outlive every step. }
  SessionId := AnsiString(ARecord.SessionId);
  Path := AnsiString(ARecord.Path);
  BeforeHash := AnsiString(ARecord.BeforeHash);
  AfterHash := AnsiString(ARecord.AfterHash);
  Patch := AnsiString(ARecord.Patch);
  ExtSession := AnsiString(ARecord.ExternalSession);

  FStore.Lock.Acquire;
  try
    Stmt := nil;
    { A local AnsiString: PAnsiChar of a string constant yields a temporary that
      is not guaranteed to outlive the call. }
    Prepared := AnsiString(SqlInsertChange);
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(Prepared), -1, @Stmt, nil)
      <> 0 then
    begin
      AError := 'could not prepare the insert';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, ARecord.WorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(SessionId), -1, nil);
      sqlite3_bind_int(Stmt, 3, ARecord.TurnId);
      sqlite3_bind_int(Stmt, 4, ARecord.MessageId);
      sqlite3_bind_text(Stmt, 5, PAnsiChar(Path), -1, nil);
      sqlite3_bind_int(Stmt, 6, Ord(ARecord.Kind));
      sqlite3_bind_text(Stmt, 7, PAnsiChar(BeforeHash), -1, nil);
      sqlite3_bind_text(Stmt, 8, PAnsiChar(AfterHash), -1, nil);
      sqlite3_bind_text(Stmt, 9, PAnsiChar(Patch), -1, nil);
      sqlite3_bind_int(Stmt, 10, ARecord.PatchBytes);
      sqlite3_bind_int(Stmt, 11, Ord(ARecord.Capped));
      sqlite3_bind_int64(Stmt, 12, ARecord.BeforeSize);
      sqlite3_bind_int64(Stmt, 13, ARecord.AfterSize);
      sqlite3_bind_int(Stmt, 14, Ord(ARecord.Source));
      sqlite3_bind_text(Stmt, 15, PAnsiChar(ExtSession), -1, nil);
      sqlite3_bind_int64(Stmt, 16, ARecord.CreatedAt);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if Result then
        AId := Integer(sqlite3_last_insert_rowid(FStore.Db))
      else
        AError := 'could not append a change';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteChangeStore.ForPath(AWorkspaceId: Integer; const APath: string;
  AFromId, ALimit: Integer; out ARows: TChangeRecordArray;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  P: AnsiString;
  SQL: string;
  N: Integer;
begin
  Result := False;
  ARows := nil;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  SQL := SqlSelectChange +
    'WHERE workspace_id = ? AND path = ? AND id >= ? ORDER BY id';
  if ALimit > 0 then
    SQL := SQL + ' LIMIT ?';
  P := AnsiString(APath);
  N := 0;
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(SQL)), -1, @Stmt, nil)
      <> 0 then
    begin
      AError := 'could not prepare the query';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(P), -1, nil);
      sqlite3_bind_int(Stmt, 3, AFromId);
      if ALimit > 0 then
        sqlite3_bind_int(Stmt, 4, ALimit);
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(ARows, N + 1);
        Fill(Stmt, ARows[N]);
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

function TSqliteChangeStore.Latest(AWorkspaceId: Integer; const APath: string;
  out ARow: TChangeRecord; out AFound: Boolean;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  P: AnsiString;
begin
  Result := False;
  ARow := Default(TChangeRecord);
  AFound := False;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  P := AnsiString(APath);
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(
      AnsiString(SqlSelectChange +
        'WHERE workspace_id = ? AND path = ? ORDER BY id DESC LIMIT 1')),
      -1, @Stmt, nil) <> 0 then
    begin
      AError := 'could not prepare the query';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(P), -1, nil);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        Fill(Stmt, ARow);
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

function TSqliteChangeStore.Touching(AWorkspaceId: Integer;
  const APaths: TStringArrayLite; AFromId: Integer;
  out ARows: TChangeRecordArray; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Bound: array of AnsiString;
  SQL, List: string;
  I, N: Integer;
begin
  Result := False;
  ARows := nil;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  if Length(APaths) = 0 then
  begin
    Result := True;
    Exit;
  end;
  { One placeholder per path. The caller supplies them (a board entry's
    referenced files), so the count is small and known. }
  List := '';
  SetLength(Bound, Length(APaths));
  for I := 0 to High(APaths) do
  begin
    if I > 0 then
      List := List + ', ';
    List := List + '?';
    Bound[I] := AnsiString(APaths[I]);
  end;
  SQL := SqlSelectChange + 'WHERE workspace_id = ? AND id >= ? AND path IN (' +
    List + ') ORDER BY id';
  N := 0;
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(SQL)), -1, @Stmt, nil)
      <> 0 then
    begin
      AError := 'could not prepare the query';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_int(Stmt, 2, AFromId);
      for I := 0 to High(Bound) do
        sqlite3_bind_text(Stmt, 3 + I, PAnsiChar(Bound[I]), -1, nil);
      while sqlite3_step(Stmt) = SQLITE_ROW do
      begin
        SetLength(ARows, N + 1);
        Fill(Stmt, ARows[N]);
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

function TSqliteChangeStore.KeyframeBefore(AWorkspaceId: Integer;
  const APath: string; AChangeId: Integer; out AFrame: TKeyframe;
  out AFound: Boolean; out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  P: AnsiString;
  S: PAnsiChar;
begin
  Result := False;
  AFrame := Default(TKeyframe);
  AFound := False;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  P := AnsiString(APath);
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(
      'SELECT id, workspace_id, path, hash, content, through_change_id, ' +
      'created_at FROM file_keyframes WHERE workspace_id = ? AND path = ? ' +
      'AND through_change_id <= ? ORDER BY through_change_id DESC LIMIT 1')),
      -1, @Stmt, nil) <> 0 then
    begin
      AError := 'could not prepare the keyframe query';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, AWorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(P), -1, nil);
      sqlite3_bind_int(Stmt, 3, AChangeId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
      begin
        AFrame.Id := sqlite3_column_int(Stmt, 0);
        AFrame.WorkspaceId := sqlite3_column_int(Stmt, 1);
        S := sqlite3_column_text(Stmt, 2);
        if S <> nil then AFrame.Path := AnsiString(S);
        S := sqlite3_column_text(Stmt, 3);
        if S <> nil then AFrame.Hash := AnsiString(S);
        S := sqlite3_column_text(Stmt, 4);
        if S <> nil then AFrame.Content := AnsiString(S);
        AFrame.ThroughChangeId := sqlite3_column_int(Stmt, 5);
        AFrame.CreatedAt := sqlite3_column_int64(Stmt, 6);
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

function TSqliteChangeStore.PutKeyframe(const AFrame: TKeyframe;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  P, H, C: AnsiString;
begin
  Result := False;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  P := AnsiString(AFrame.Path);
  H := AnsiString(AFrame.Hash);
  C := AnsiString(AFrame.Content);
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(
      'INSERT OR REPLACE INTO file_keyframes (workspace_id, path, hash, ' +
      'content, through_change_id, created_at) VALUES (?, ?, ?, ?, ?, ?)')),
      -1, @Stmt, nil) <> 0 then
    begin
      AError := 'could not prepare the keyframe insert';
      Exit;
    end;
    try
      sqlite3_bind_int(Stmt, 1, AFrame.WorkspaceId);
      sqlite3_bind_text(Stmt, 2, PAnsiChar(P), -1, nil);
      sqlite3_bind_text(Stmt, 3, PAnsiChar(H), -1, nil);
      sqlite3_bind_text(Stmt, 4, PAnsiChar(C), -1, nil);
      sqlite3_bind_int(Stmt, 5, AFrame.ThroughChangeId);
      sqlite3_bind_int64(Stmt, 6, AFrame.CreatedAt);
      Result := sqlite3_step(Stmt) = SQLITE_DONE;
      if not Result then
        AError := 'could not write a keyframe';
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteChangeStore.Prune(AWorkspaceId, AKeepFromId: Integer;
  out AError: string): Boolean;
var
  Stmt: Psqlite3_stmt;
  Horizon: Integer;
  Ignored: Integer;

  function Run(const ASQL: string; ABindWorkspace, ABindId: Integer;
    out AValue: Integer): Boolean;
  begin
    Result := False;
    AValue := 0;
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(ASQL)), -1, @Stmt,
      nil) <> 0 then
      Exit;
    try
      sqlite3_bind_int(Stmt, 1, ABindWorkspace);
      sqlite3_bind_int(Stmt, 2, ABindId);
      if sqlite3_step(Stmt) = SQLITE_ROW then
        AValue := sqlite3_column_int(Stmt, 0);
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  end;

begin
  Result := False;
  AError := '';
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  FStore.Lock.Acquire;
  try
    { The newest keyframe at or before the horizon must survive, or the oldest
      surviving change has nothing to replay from. }
    if not Run('SELECT COALESCE(MAX(through_change_id), 0) FROM file_keyframes ' +
      'WHERE workspace_id = ? AND through_change_id < ?', AWorkspaceId,
      AKeepFromId, Horizon) then
    begin
      AError := 'could not find the keyframe horizon';
      Exit;
    end;
    if not Run('DELETE FROM file_changes WHERE workspace_id = ? AND id < ?',
      AWorkspaceId, AKeepFromId, Ignored) then
    begin
      AError := 'could not prune changes';
      Exit;
    end;
    { Horizon as the bound value AND as the result would alias: Run zeroes the
      out parameter before it is read. }
    if not Run('DELETE FROM file_keyframes WHERE workspace_id = ? AND ' +
      'through_change_id < ?', AWorkspaceId, Horizon, Ignored) then
    begin
      AError := 'could not prune keyframes';
      Exit;
    end;
    Result := True;
  finally
    FStore.Lock.Release;
  end;
end;

function TSqliteChangeStore.NextId: Integer;
var
  Stmt: Psqlite3_stmt;
begin
  Result := 1;
  if (FStore = nil) or (FStore.Db = nil) then
    Exit;
  FStore.Lock.Acquire;
  try
    Stmt := nil;
    if sqlite3_prepare_v2(FStore.Db, PAnsiChar(AnsiString(
      'SELECT COALESCE(MAX(id), 0) + 1 FROM file_changes')), -1, @Stmt, nil) = 0
    then
    try
      if sqlite3_step(Stmt) = SQLITE_ROW then
        Result := sqlite3_column_int(Stmt, 0);
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    FStore.Lock.Release;
  end;
end;

end.
