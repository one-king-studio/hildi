unit HildiStdioChild;
{ A bidirectional stdio child manager for MCP servers: spawns a child with
  pipes both ways, writes newline-framed lines to its stdin, reads framed lines
  from its stdout (with a bounded wait), drains its stderr into a bounded tail,
  and tears down with a bounded close-then-kill.

  Deliberately not a general process API, and deliberately synchronous and
  single-threaded: no reader thread, no queue, nothing to join. The MCP client
  drives it on the loop's thread. See
  docs/features/MCP_Client/Stdio_Child_Manager_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Process,
  HildiSessionSocket, HildiProcess;

type
  { Why a ReadLine call returned False. }
  TStdioReadResult = (srOk, srTimeout, srEof, srTooLong, srError);

  TStdioChildConfig = record
    Executable: string;        // resolved path or PATH name
    Args: array of string;     // exact argv after the executable
    Env: array of string;      // optional 'NAME=VALUE' additions; nil = inherit
    WorkingDir: string;        // '' => current directory
    ReadTimeoutMs: Integer;    // 0 => DefaultStdioReadTimeoutMs
    CloseTimeoutMs: Integer;   // bounded close-then-kill grace; 0 => default
    MaxLineBytes: Integer;     // reject a longer line; 0 => default
    MaxStderrBytes: Integer;   // bound on the retained stderr tail; 0 => default
  end;

  TStdioChild = class
  private
    FConfig: TStdioChildConfig;
    FProcess: TProcess;
    FStarted: Boolean;
    FExited: Boolean;
    FExitCode: Integer;
    FOutBuf: AnsiString;       // retained partial stdout line
    FStderr: AnsiString;       // bounded stderr tail
    FMaxLineBytes: Integer;
    FMaxStderrBytes: Integer;
    procedure DrainStderr;
  public
    constructor Create(const AConfig: TStdioChildConfig);
    destructor Destroy; override;

    { Spawn the child with both pipes. False + AError on failure. Idempotent. }
    function Start(out AError: string): Boolean;

    { Write one line to the child's stdin, appending LF. False + AError when
      the pipe is closed (the child has exited). }
    function WriteLine(const ALine: string; out AError: string): Boolean;

    { Read one line from stdout within ATimeoutMs. Returns True (srOk) or False
      with AReason set. ALine excludes the trailing LF (and a preceding CR). }
    function ReadLine(out ALine: string; ATimeoutMs: Integer;
      out AReason: TStdioReadResult): Boolean;

    { True while the child has not been observed to exit. }
    function Alive: Boolean;

    { The last-observed exit code, NormalizeExit'd. Valid after an exit. }
    function ExitCode: Integer;

    { The retained stderr tail (bounded by MaxStderrBytes). }
    function StderrTail: string;

    { Close stdin, wait CloseTimeoutMs, then kill (SIGTERM then SIGKILL).
      Idempotent; safe in Destroy. }
    procedure Close;
  end;

const
  DefaultStdioReadTimeoutMs = 30000;
  DefaultStdioCloseTimeoutMs = 2000;
  DefaultStdioMaxLineBytes = 1 shl 20;      // 1 MiB — MCP lines are far smaller
  DefaultStdioMaxStderrBytes = 64 shl 10;   // 64 KiB retained for diagnostics

implementation

{$ifdef unix}
uses
  BaseUnix;

{ The child environment: the current process environment, with AAdd overriding
  by name. Used only when the config supplies additions; otherwise the child
  inherits the parent environment unchanged. }
function BuildEnv(const AAdd: array of string): TStringList;
var
  Override, I: Integer;
  Pair, Name: string;
  Over: TStringList;
begin
  Result := TStringList.Create;
  Over := TStringList.Create;
  try
    for I := 0 to High(AAdd) do
    begin
      Pair := AAdd[I];
      Override := Pos('=', Pair);
      if Override > 0 then
        Over.Values[Copy(Pair, 1, Override - 1)] :=
          Copy(Pair, Override + 1, MaxInt);
    end;
    for I := 0 to GetEnvironmentVariableCount - 1 do
    begin
      Pair := GetEnvironmentString(I);
      Name := Copy(Pair, 1, Pos('=', Pair) - 1);
      if Over.IndexOfName(Name) < 0 then
        Result.Add(Pair);
    end;
    for I := 0 to Over.Count - 1 do
      Result.Add(Over[I]);
  finally
    Over.Free;
  end;
end;
{$endif}

constructor TStdioChild.Create(const AConfig: TStdioChildConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.ReadTimeoutMs <= 0 then
    FConfig.ReadTimeoutMs := DefaultStdioReadTimeoutMs;
  if FConfig.CloseTimeoutMs <= 0 then
    FConfig.CloseTimeoutMs := DefaultStdioCloseTimeoutMs;
  if FConfig.MaxLineBytes <= 0 then
    FMaxLineBytes := DefaultStdioMaxLineBytes
  else
    FMaxLineBytes := FConfig.MaxLineBytes;
  if FConfig.MaxStderrBytes <= 0 then
    FMaxStderrBytes := DefaultStdioMaxStderrBytes
  else
    FMaxStderrBytes := FConfig.MaxStderrBytes;
  FProcess := nil;
  FStarted := False;
  FExited := False;
  FExitCode := 0;
end;

destructor TStdioChild.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TStdioChild.Start(out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  if FStarted then
    Exit(True);
  if FConfig.Executable = '' then
  begin
    AError := 'no executable configured';
    Exit(False);
  end;
  FProcess := TProcess.Create(nil);
  try
    FProcess.Executable := FConfig.Executable;
    for I := 0 to High(FConfig.Args) do
      FProcess.Parameters.Add(FConfig.Args[I]);
    if FConfig.WorkingDir <> '' then
      FProcess.CurrentDirectory := FConfig.WorkingDir;
    {$ifdef unix}
    if Length(FConfig.Env) > 0 then
      FProcess.Environment := BuildEnv(FConfig.Env);
    {$endif}
    { Separate stderr (no poStderrToOutput) so the tail is captured, not merged
      into the response stream. }
    FProcess.Options := [poUsePipes];
    try
      FProcess.Execute;
    except
      on E: Exception do
      begin
        AError := 'spawn failed: ' + E.Message;
        FreeAndNil(FProcess);
        Exit(False);
      end;
    end;
  except
    on E: Exception do
    begin
      AError := 'spawn failed: ' + E.Message;
      FreeAndNil(FProcess);
      Exit(False);
    end;
  end;
  FStarted := True;
  FExited := False;
  Result := True;
end;

procedure TStdioChild.DrainStderr;
var
  Tmp: array[0..4095] of Byte;
  N: Integer;
  Chunk: AnsiString;
begin
  if (FProcess = nil) or (FProcess.Stderr = nil) then
    Exit;
  repeat
    N := fpRead(FProcess.Stderr.Handle, @Tmp, SizeOf(Tmp));
    if N > 0 then
    begin
      SetLength(Chunk, N);
      Move(Tmp[0], Chunk[1], N);
      FStderr := FStderr + Chunk;
      if Length(FStderr) > FMaxStderrBytes then
        Delete(FStderr, 1, Length(FStderr) - FMaxStderrBytes);
    end;
  until N <= 0;
end;

function TStdioChild.ReadLine(out ALine: string; ATimeoutMs: Integer;
  out AReason: TStdioReadResult): Boolean;
var
  Deadline, Remaining: Int64;
  FD: TFDSet;
  TV: TTimeVal;
  OutH, ErrH, MaxFd, N: Integer;
  Tmp: array[0..4095] of Byte;
  Chunk: AnsiString;
begin
  ALine := '';
  AReason := srError;
  if (not FStarted) or (FProcess = nil) or (FProcess.Output = nil) then
  begin
    AReason := srEof;
    Exit(False);
  end;
  OutH := FProcess.Output.Handle;
  if FProcess.Stderr <> nil then
    ErrH := FProcess.Stderr.Handle
  else
    ErrH := -1;
  if ATimeoutMs <= 0 then
    ATimeoutMs := FConfig.ReadTimeoutMs;
  Deadline := NowMs + ATimeoutMs;
  repeat
    if ExtractLine(FOutBuf, ALine) then
    begin
      AReason := srOk;
      Exit(True);
    end;
    if FExited then
    begin
      AReason := srEof;
      Exit(False);
    end;
    Remaining := Deadline - NowMs;
    if Remaining <= 0 then
    begin
      AReason := srTimeout;
      Exit(False);
    end;
    fpFD_ZERO(FD);
    fpFD_SET(OutH, FD);
    if ErrH >= 0 then
      fpFD_SET(ErrH, FD);
    if ErrH > OutH then
      MaxFd := ErrH
    else
      MaxFd := OutH;
    TV.tv_sec := Remaining div 1000;
    TV.tv_usec := (Remaining mod 1000) * 1000;
    N := fpSelect(MaxFd + 1, @FD, nil, nil, @TV);
    if N < 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      AReason := srError;
      Exit(False);
    end;
    if N = 0 then
    begin
      AReason := srTimeout;
      Exit(False);
    end;
    if (ErrH >= 0) and (fpFD_ISSET(ErrH, FD) <> 0) then
      DrainStderr;
    if fpFD_ISSET(OutH, FD) <> 0 then
    begin
      N := fpRead(OutH, @Tmp, SizeOf(Tmp));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        Move(Tmp[0], Chunk[1], N);
        FOutBuf := FOutBuf + Chunk;
        if Length(FOutBuf) > FMaxLineBytes then
        begin
          AReason := srTooLong;
          Exit(False);
        end;
      end
      else if (N < 0) and (fpGetErrno = ESysEINTR) then
        Continue
      else
      begin
        FProcess.WaitOnExit;
        FExitCode := NormalizeExit(FProcess.ExitStatus);
        FExited := True;
        AReason := srEof;
        Exit(False);
      end;
    end;
  until False;
end;

function TStdioChild.WriteLine(const ALine: string; out AError: string): Boolean;
var
  Data: AnsiString;
  Off, N: Integer;
begin
  AError := '';
  Result := False;
  if (not FStarted) or (FProcess = nil) then
  begin
    AError := 'child not started';
    Exit;
  end;
  if FExited then
  begin
    AError := 'child has exited';
    Exit;
  end;
  if Pos(#10, ALine) > 0 then
  begin
    AError := 'line contains a newline';
    Exit;
  end;
  if FProcess.Input = nil then
  begin
    AError := 'no stdin pipe';
    Exit;
  end;
  Data := AnsiString(ALine) + #10;
  Off := 1;
  while Off <= Length(Data) do
  begin
    N := fpWrite(FProcess.Input.Handle, @Data[Off], Length(Data) - Off + 1);
    if N > 0 then
      Inc(Off, N)
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else
    begin
      AError := 'write failed (pipe closed)';
      Exit;
    end;
  end;
  Result := True;
end;

function TStdioChild.Alive: Boolean;
begin
  Result := FStarted and (not FExited) and (FProcess <> nil) and
    FProcess.Running;
end;

function TStdioChild.ExitCode: Integer;
begin
  Result := FExitCode;
end;

function TStdioChild.StderrTail: string;
begin
  Result := string(FStderr);
end;

procedure TStdioChild.Close;
begin
  if FProcess = nil then
    Exit;
  try
    if FStarted and not FExited then
    begin
      { Close stdin so the child sees EOF, then wait a bounded grace period
        using the non-blocking reaper. Running only reflects an exit after a
        wait, so poll WaitOnExit rather than the Running property.
        ponytail: TProcess.CloseInput does not always deliver EOF to the child,
        so a child that does not exit on its own falls through to SIGTERM after
        the full grace (bounded, leak-clean). Upgrade by closing the raw pipe fd
        if per-server teardown latency ever matters. }
      try
        FProcess.CloseInput;
      except
        on E: Exception do ;
      end;
      if not FProcess.WaitOnExit(FConfig.CloseTimeoutMs) then
      begin
        { Still alive: SIGTERM, a brief grace, then SIGKILL. }
        fpKill(FProcess.ProcessID, SIGTERM);
        if not FProcess.WaitOnExit(500) then
        begin
          fpKill(FProcess.ProcessID, SIGKILL);
          FProcess.WaitOnExit;   // reap the killed child
        end;
      end;
      FExitCode := NormalizeExit(FProcess.ExitStatus);
      FExited := True;
    end;
  finally
    FreeAndNil(FProcess);
    FStarted := False;
    FOutBuf := '';
    FStderr := '';
  end;
end;

end.
