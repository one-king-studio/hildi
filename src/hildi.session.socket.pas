unit hildi.session.socket;
{ The AF_UNIX transport primitives shared by the session client and the session
  runtime: the runtime directory, the socket path, the liveness probe, and the
  send/recv/framing helpers. Nothing here knows the wire schema or the agent, so
  both halves of the split can depend on it. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils
  {$ifdef unix}, BaseUnix, Sockets{$endif};

{ A write to a closed peer must not raise SIGPIPE and kill the process. Darwin
  and the BSDs have a per-socket option; Linux uses a per-send flag instead. }
{$ifdef linux}
const
  SendFlags = MSG_NOSIGNAL;
{$else}
const
  SendFlags = 0;
{$endif}

{ The owner-only runtime directory (a short path, never $HOME). }
function RuntimeDir: string;
{ The socket path for a session; derived from the id and kept short. }
function SocketPathFor(const ASessionId: string): string;
{ True when a runtime is listening on the session's socket (a live connect). }
function SessionSocketReady(const ASessionId: string): Boolean;

const
  { A socket younger than this may be mid-bind (bind creates the file before
    listen), so the sweep leaves it for a live runtime to own. }
  SocketSweepGraceMs = 60000;
  { A log is kept while its runtime is live, and for this long afterwards so a
    crash log can still be read. }
  LogSweepKeepMs = 60 * 60 * 1000;

{ Remove stale runtime files from ADir, best effort. A <session>.sock whose
  runtime is not live (the connect probe fails) and that is at least
  ASocketGraceMs old is unlinked. A <session>.log is unlinked once its runtime is
  not live and the log is at least ALogKeepMs old. A live runtime's socket and
  log are never touched. }
procedure SweepRuntimeDir(const ADir: string; ASocketGraceMs, ALogKeepMs: Int64);

function NowMs: Int64;
function ShellQuote(const AValue: string): string;
function ConnectProbe(const APath: string): Boolean;
function ConnectFd(const APath: string): Integer;
function WaitReadable(AFd, ATimeoutMs: Integer): Boolean;
function ExtractLine(var ABuf: AnsiString; out ALine: string): Boolean;
function SendAll(AFd: Integer; const AData: AnsiString): Boolean;
function ReadLineTimeout(AFd, ATimeoutMs: Integer; var ABuf: AnsiString;
  out ALine: string): Boolean;
procedure SetNonBlocking(AFd: Integer);
procedure SetNoSigPipe(AFd: Integer);
{$ifdef unix}
function MakeUnixAddr(const APath: string; out AAddr: TUnixSockAddr;
  out ALen: TSockLen): Boolean;
{$endif}

implementation

{$ifdef unix}
function NowMs: Int64;
begin
  Result := Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

function MakeUnixAddr(const APath: string; out AAddr: TUnixSockAddr;
  out ALen: TSockLen): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := Length(APath);
  if (N = 0) or (N > 103) then
    Exit;
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.family := AF_UNIX;
  Move(APath[1], AAddr.path, N);
  AAddr.path[N] := #0;
  {$ifdef darwin}
  AAddr.sa_len := N + 3;
  {$endif}
  ALen := N + 3;
  Result := True;
end;

procedure SetNonBlocking(AFd: Integer);
begin
  fpFcntl(AFd, F_SETFL, fpFcntl(AFd, F_GETFL, 0) or O_NONBLOCK);
end;

{$ifdef darwin}
procedure SetNoSigPipe(AFd: Integer);
var
  One: cint;
begin
  One := 1;
  fpsetsockopt(AFd, SOL_SOCKET, SO_NOSIGPIPE, @One, SizeOf(One));
end;
{$else}
procedure SetNoSigPipe(AFd: Integer);
begin
end;
{$endif}

{ Connect and close, for the "is the socket live?" probe. }
function ConnectProbe(const APath: string): Boolean;
var
  Addr: TUnixSockAddr;
  Len: TSockLen;
  S: Integer;
begin
  Result := False;
  if not MakeUnixAddr(APath, Addr, Len) then
    Exit;
  S := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if S < 0 then
    Exit;
  SetNoSigPipe(S);
  try
    Result := fpConnect(S, PSockAddr(@Addr), Len) = 0;
  finally
    CloseSocket(S);
  end;
end;

function ConnectFd(const APath: string): Integer;
var
  Addr: TUnixSockAddr;
  Len: TSockLen;
  S: Integer;
begin
  Result := -1;
  if not MakeUnixAddr(APath, Addr, Len) then
    Exit;
  S := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if S < 0 then
    Exit;
  SetNoSigPipe(S);
  if fpConnect(S, PSockAddr(@Addr), Len) <> 0 then
  begin
    CloseSocket(S);
    Exit;
  end;
  Result := S;
end;

function WaitReadable(AFd, ATimeoutMs: Integer): Boolean;
var
  FD: TFDSet;
  TV: TTimeVal;
begin
  fpFD_ZERO(FD);
  fpFD_SET(AFd, FD);
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  Result := fpSelect(AFd + 1, @FD, nil, nil, @TV) > 0;
end;

function ExtractLine(var ABuf: AnsiString; out ALine: string): Boolean;
var
  P: Integer;
begin
  P := Pos(#10, ABuf);
  if P = 0 then
    Exit(False);
  ALine := string(Copy(ABuf, 1, P - 1));
  Delete(ABuf, 1, P);
  if (ALine <> '') and (ALine[Length(ALine)] = #13) then
    Delete(ALine, Length(ALine), 1);
  Result := True;
end;

function SendAll(AFd: Integer; const AData: AnsiString): Boolean;
var
  Off, N: Integer;
begin
  Result := False;
  Off := 1;
  while Off <= Length(AData) do
  begin
    N := fpSend(AFd, @AData[Off], Length(AData) - Off + 1, SendFlags);
    if N > 0 then
      Inc(Off, N)
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else
      Exit;
  end;
  Result := True;
end;

{ Reads one line with a timeout. The socket is in blocking mode; used only for
  the handshake. }
function ReadLineTimeout(AFd, ATimeoutMs: Integer; var ABuf: AnsiString;
  out ALine: string): Boolean;
var
  Deadline: Int64;
  Tmp: array[0..4095] of Byte;
  N: Integer;
  Remaining: Int64;
begin
  ALine := '';
  Deadline := NowMs + ATimeoutMs;
  while True do
  begin
    if ExtractLine(ABuf, ALine) then
      Exit(True);
    Remaining := Deadline - NowMs;
    if Remaining <= 0 then
      Exit(False);
    if not WaitReadable(AFd, Remaining) then
      Exit(False);
    N := fpRecv(AFd, @Tmp, SizeOf(Tmp), 0);
    if N > 0 then
    begin
      SetLength(ABuf, Length(ABuf) + N);
      Move(Tmp, ABuf[Length(ABuf) - N + 1], N);
    end
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else
      Exit(False);
  end;
end;

{ The file's mtime in ms since the epoch, or 0 when it cannot be read (so a
  dead file is swept rather than kept). }
function FileMTimeMs(const APath: string): Int64;
var
  DT: TDateTime;
begin
  if not FileAge(APath, DT) then
    Exit(0);
  Result := Trunc((DT - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

procedure SweepRuntimeDir(const ADir: string; ASocketGraceMs, ALogKeepMs: Int64);
var
  SR: TSearchRec;
  Path, Name: string;
  Now_: Int64;
begin
  if ADir = '' then
    Exit;
  Now_ := NowMs;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      Name := SR.Name;
      if (Name = '') or (Name = '.') or (Name = '..') then
        Continue;
      Path := IncludeTrailingPathDelimiter(ADir) + Name;
      if ExtractFileExt(Name) = '.sock' then
      begin
        if ConnectProbe(Path) then
          Continue;                       { a live runtime owns it }
        if (ASocketGraceMs > 0) and
          (Now_ - FileMTimeMs(Path) < ASocketGraceMs) then
          Continue;                       { possibly mid-bind }
        fpUnlink(PAnsiChar(AnsiString(Path)));
      end
      else if ExtractFileExt(Name) = '.log' then
      begin
        { Keep a log while its runtime is live, and for a while afterwards so a
          crash log can still be read. }
        if ConnectProbe(ChangeFileExt(Path, '.sock')) then
          Continue;
        if (ALogKeepMs > 0) and (Now_ - FileMTimeMs(Path) < ALogKeepMs) then
          Continue;
        fpUnlink(PAnsiChar(AnsiString(Path)));
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;
{$else}
function NowMs: Int64;
begin
  Result := Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

function ConnectProbe(const APath: string): Boolean;
begin
  Result := False;
end;

function ConnectFd(const APath: string): Integer;
begin
  Result := -1;
end;

function WaitReadable(AFd, ATimeoutMs: Integer): Boolean;
begin
  Result := False;
end;

function ExtractLine(var ABuf: AnsiString; out ALine: string): Boolean;
begin
  Result := False;
end;

function SendAll(AFd: Integer; const AData: AnsiString): Boolean;
begin
  Result := False;
end;

function ReadLineTimeout(AFd, ATimeoutMs: Integer; var ABuf: AnsiString;
  out ALine: string): Boolean;
begin
  Result := False;
end;

procedure SetNonBlocking(AFd: Integer);
begin
end;

procedure SetNoSigPipe(AFd: Integer);
begin
end;

procedure SweepRuntimeDir(const ADir: string; ASocketGraceMs, ALogKeepMs: Int64);
begin
end;
{$endif}

function ShellQuote(const AValue: string): string;
begin
  Result := '''' + StringReplace(AValue, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function RuntimeDir: string;
begin
  {$ifdef unix}
  Result := '/tmp/hildi-' + IntToStr(fpGetUID) + PathDelim;
  {$else}
  Result := GetTempDir + 'hildi' + PathDelim;
  {$endif}
end;

function SocketPathFor(const ASessionId: string): string;
begin
  Result := RuntimeDir + ASessionId + '.sock';
end;

function SessionSocketReady(const ASessionId: string): Boolean;
begin
  {$ifdef unix}
  Result := ConnectProbe(SocketPathFor(ASessionId));
  {$else}
  Result := False;
  {$endif}
end;

end.
