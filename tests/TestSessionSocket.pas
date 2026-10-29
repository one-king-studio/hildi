unit TestSessionSocket;
{ fpcunit tests for the stale runtime-file sweep in
  HildiSessionSocket.

  The sweep is best-effort housekeeping for /tmp: it must remove a dead socket
  and an old log, but never a socket a live runtime still owns. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  HildiSessionSocket;

type
  TSessionSocketSweepTest = class(TTestCase)
  private
    FDir: string;
    function ExistsAt(const APath: string): Boolean;
    function MakeFile(const AName: string): string;
    function ListenAt(const APath: string): Integer;
    procedure RemoveTree(const ADir: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSweepRemovesADeadSocket;
    procedure TestSweepRemovesAnOldLog;
    procedure TestSweepKeepsALiveSocket;
    procedure TestSweepKeepsAFreshLog;
    procedure TestSweepKeepsALogWithALiveRuntime;
  end;

implementation

uses
  BaseUnix, Sockets;

function TSessionSocketSweepTest.ExistsAt(const APath: string): Boolean;
begin
  { FileExists is unreliable for a socket node; access(2) is not. }
  Result := fpAccess(PAnsiChar(AnsiString(APath)), F_OK) = 0;
end;

function TSessionSocketSweepTest.MakeFile(const AName: string): string;
var
  H: THandle;
begin
  Result := FDir + AName;
  H := FileCreate(Result);
  AssertTrue('created ' + AName, H <> THandle(-1));
  FileClose(H);
end;

function TSessionSocketSweepTest.ListenAt(const APath: string): Integer;
var
  Addr: TUnixSockAddr;
  Len: TSockLen;
begin
  Result := -1;
  if not MakeUnixAddr(APath, Addr, Len) then
    Exit;
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    Exit;
  if (fpBind(Result, PSockAddr(@Addr), Len) <> 0) or
    (fpListen(Result, 4) <> 0) then
  begin
    CloseSocket(Result);
    Result := -1;
  end;
end;

procedure TSessionSocketSweepTest.RemoveTree(const ADir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
          DeleteFile(IncludeTrailingPathDelimiter(ADir) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(ADir);
end;

procedure TSessionSocketSweepTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hildi-sweep-test' +
    PathDelim;
  RemoveTree(FDir);
  ForceDirectories(FDir);
end;

procedure TSessionSocketSweepTest.TearDown;
begin
  RemoveTree(FDir);
end;

procedure TSessionSocketSweepTest.TestSweepRemovesADeadSocket;
var
  Sock: string;
begin
  { A plain file where a socket should be: the connect probe fails, so it is
    dead and must go. }
  Sock := MakeFile('dead.sock');
  SweepRuntimeDir(FDir, 0, 0);
  AssertFalse('a dead socket is removed', ExistsAt(Sock));
end;

procedure TSessionSocketSweepTest.TestSweepRemovesAnOldLog;
var
  Log: string;
begin
  Log := MakeFile('dead.log');
  SweepRuntimeDir(FDir, 0, 0);
  AssertFalse('an expired log is removed', ExistsAt(Log));
end;

procedure TSessionSocketSweepTest.TestSweepKeepsALiveSocket;
var
  Fd: Integer;
  Sock: string;
begin
  Sock := FDir + 'live.sock';
  Fd := ListenAt(Sock);
  AssertTrue('bound a listening socket', Fd >= 0);
  try
    SweepRuntimeDir(FDir, 0, 0);
    AssertTrue('a live socket is kept', ExistsAt(Sock));
  finally
    CloseSocket(Fd);
  end;
end;

procedure TSessionSocketSweepTest.TestSweepKeepsAFreshLog;
var
  Log: string;
begin
  Log := MakeFile('fresh.log');
  SweepRuntimeDir(FDir, 0, LogSweepKeepMs);
  AssertTrue('a fresh log is kept', ExistsAt(Log));
end;

procedure TSessionSocketSweepTest.TestSweepKeepsALogWithALiveRuntime;
var
  Fd: Integer;
  Log: string;
begin
  { A running session's log must survive even with a zero keep window. }
  Fd := ListenAt(FDir + 'live.sock');
  AssertTrue('bound a listening socket', Fd >= 0);
  try
    Log := MakeFile('live.log');
    SweepRuntimeDir(FDir, 0, 0);
    AssertTrue('a live runtime''s log is kept', ExistsAt(Log));
  finally
    CloseSocket(Fd);
  end;
end;

initialization
  RegisterTest(TSessionSocketSweepTest);
end.
