unit HildiSQLITE;
{ Minimal static binding to SQLite 3. Declares only the functions the store
  uses, all `external 'sqlite3'`, so the linker resolves them from a linked-in
  static libsqlite3 (no runtime .dylib/.so, no SQLDB, no dlopen).

  Build links `-lsqlite3`; point FPC's library path (-Fl) at the directory
  holding the static archive (see the Makefile). }

{$mode delphi}{$H+}

{ The static archive is linked explicitly by the Makefile via -k<path>; the
  `external 'sqlite3'` declarations add no dynamic library of their own. }

interface

uses
  ctypes;

type
  Psqlite3 = Pointer;
  PPsqlite3 = ^Psqlite3;
  Psqlite3_stmt = Pointer;
  PPsqlite3_stmt = ^Psqlite3_stmt;
  sqlite3_int64 = Int64;

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;

  SQLITE_OPEN_READWRITE = $00000002;
  SQLITE_OPEN_CREATE = $00000004;
  SQLITE_OPEN_FULLMUTEX = $00010000;

  { sqlite3_column_type values }
  SQLITE_INTEGER = 1;
  SQLITE_FLOAT = 2;
  SQLITE_TEXT = 3;
  SQLITE_BLOB = 4;
  SQLITE_NULL = 5;

function sqlite3_open(filename: PAnsiChar; ppDb: PPsqlite3): cint;
  cdecl; external 'sqlite3';
function sqlite3_close(db: Psqlite3): cint; cdecl; external 'sqlite3';
function sqlite3_errmsg(db: Psqlite3): PAnsiChar; cdecl; external 'sqlite3';
function sqlite3_exec(db: Psqlite3; sql: PAnsiChar; callback: Pointer;
  arg: Pointer; errmsg: PPAnsiChar): cint; cdecl; external 'sqlite3';
procedure sqlite3_free(p: Pointer); cdecl; external 'sqlite3';
function sqlite3_prepare_v2(db: Psqlite3; sql: PAnsiChar; nByte: cint;
  ppStmt: PPsqlite3_stmt; pzTail: PPAnsiChar): cint; cdecl; external 'sqlite3';
function sqlite3_finalize(stmt: Psqlite3_stmt): cint; cdecl; external 'sqlite3';
function sqlite3_step(stmt: Psqlite3_stmt): cint; cdecl; external 'sqlite3';
function sqlite3_reset(stmt: Psqlite3_stmt): cint; cdecl; external 'sqlite3';
function sqlite3_bind_text(stmt: Psqlite3_stmt; idx: cint; value: PAnsiChar;
  n: cint; destructor_: Pointer): cint; cdecl; external 'sqlite3';
function sqlite3_bind_int(stmt: Psqlite3_stmt; idx: cint; value: cint): cint;
  cdecl; external 'sqlite3';
function sqlite3_bind_int64(stmt: Psqlite3_stmt; idx: cint;
  value: sqlite3_int64): cint; cdecl; external 'sqlite3';
function sqlite3_column_text(stmt: Psqlite3_stmt; idx: cint): PAnsiChar;
  cdecl; external 'sqlite3';
function sqlite3_column_int(stmt: Psqlite3_stmt; idx: cint): cint;
  cdecl; external 'sqlite3';
function sqlite3_column_int64(stmt: Psqlite3_stmt; idx: cint): sqlite3_int64;
  cdecl; external 'sqlite3';
function sqlite3_column_type(stmt: Psqlite3_stmt; idx: cint): cint;
  cdecl; external 'sqlite3';
function sqlite3_changes(db: Psqlite3): cint; cdecl; external 'sqlite3';
function sqlite3_last_insert_rowid(db: Psqlite3): sqlite3_int64;
  cdecl; external 'sqlite3';
function sqlite3_busy_timeout(db: Psqlite3; ms: cint): cint;
  cdecl; external 'sqlite3';
function sqlite3_libversion: PAnsiChar; cdecl; external 'sqlite3';

{ SQLITE_TRANSIENT is (void*)-1; pass it to make SQLite copy bound text. }
function SQLiteTransient: Pointer;

implementation

function SQLiteTransient: Pointer;
begin
  Result := Pointer(-1);
end;

end.
