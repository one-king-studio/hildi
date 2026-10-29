unit hildi.session.client;
{ The session wire client: connect to (or spawn) a session's headless runtime and
  turn the wire into ISessionSink callbacks on its own reader thread. Nothing
  here links the agent, the tools, or the runtime server, so a UI client can
  depend on it without pulling the loop. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  {$ifdef unix}BaseUnix, Sockets,{$endif}
  Process,
  hildi.session.socket, hildi.session.protocol;

type
  { The consumer's mapping target: the CLI implements this today, the TUI next. }
  ISessionSink = interface
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TSessionClientConfig = record
    SessionId: string;
    WorkspacePath: string;      // for spawning a runtime
    StorePath: string;
    Role: TSessionRole;
    FromSeq: Int64;             // 0 => the whole live turn
    Spawn: Boolean;             // connect-or-spawn
    SpawnTimeoutMs: Integer;    // 0 => default
    RuntimeCommand: string;     // the executable used to spawn a runtime
    IdleExitMs: Integer;        // passed to a spawned runtime; 0 => default
    { The lineage root whose approval scope the spawned session resolves against
      (a subagent's parent). '' => the session's own id. }
    ApprovalRootSessionId: string;
  end;

  TSessionClient = class;

  TClientReader = class(TThread)
  private
    FClient: TSessionClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TSessionClient);
  end;

  TSessionClient = class
  private
    FConfig: TSessionClientConfig;
    FSink: ISessionSink;
    FFd: Integer;
    FRole: TSessionRole;
    FHello: TSessionHello;
    FAttached: TSessionAttached;
    FInBuf: AnsiString;
    FLock: TCriticalSection;
    FReplyEvent: TSimpleEvent;
    FWaitId: string;
    FReplyReady: Boolean;
    FReply: TSessionMessage;
    FClosed: Boolean;
    FSpawned: Boolean;
    FReader: TClientReader;
    procedure HandleIncoming(const AMessage: TSessionMessage);
  public
    class function Open(const AConfig: TSessionClientConfig;
      const ASink: ISessionSink; out AError: string): TSessionClient;
    destructor Destroy; override;
    { Send a command and return immediately. False when the connection is gone. }
    function Send(const ACommand: TSessionCommand): Boolean;
    { Blocking helper: send and wait for the correlated reply. }
    function SendAndWait(const ACommand: TSessionCommand; ATimeoutMs: Integer;
      out AReply: TSessionMessage): Boolean;
    { True once the reader thread has exited (or there is none). Non-blocking:
      lets an owner reap a finished client without joining a thread it may be
      running on. }
    function ReaderDone: Boolean;
    property Role: TSessionRole read FRole;
    property Hello: TSessionHello read FHello;
    property Attached: TSessionAttached read FAttached;
    procedure Close;
  end;

const
  DefaultSpawnTimeoutMs = 5000;
  { The headless agent binary a client spawns when none is named. }
  DefaultRuntimeBinary = 'hildi-agent';

{ The runtime binary to spawn: AExplicit (from HILDI_RUNTIME_BIN) when it
  names a file, else a sibling of AExecutable named DefaultRuntimeBinary. ''
  when neither exists, so the caller can fail with a clear message. }
function ResolveRuntimeBinary(const AExplicit, AExecutable: string): string;

implementation

{$ifdef unix}
function SpawnDetached(const ACommand, ASessionId, AWorkspace,
  AStore, ALogPath, AApprovalRoot: string; AIdleExitMs: Integer): Boolean;
var
  P: TProcess;
  Inner, Script: string;
begin
  Result := False;
  Inner := ShellQuote(ACommand) + ' --session-runtime ' +
    ShellQuote(ASessionId) + ' --workspace ' + ShellQuote(AWorkspace) +
    ' --store ' + ShellQuote(AStore);
  if AApprovalRoot <> '' then
    Inner := Inner + ' --approval-root ' + ShellQuote(AApprovalRoot);
  if AIdleExitMs > 0 then
    Inner := Inner + ' --idle-ms ' + IntToStr(AIdleExitMs);
  { ponytail: nohup + sh is the portable detach idiom on macOS and Linux.
    Ceiling: relies on /bin/sh and nohup. Upgrade path: a native fork/setsid
    when we want to avoid the shell. }
  Script := 'nohup ' + Inner + ' >> ' + ShellQuote(ALogPath) +
    ' 2>&1 < /dev/null &';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Script);
    P.Options := [poWaitOnExit];
    try
      P.Execute;
      P.WaitOnExit;
      Result := True;
    except
      Result := False;
    end;
  finally
    P.Free;
  end;
end;
{$endif}

function ResolveRuntimeBinary(const AExplicit, AExecutable: string): string;
var
  Sibling: string;
begin
  Result := '';
  if (AExplicit <> '') and FileExists(AExplicit) then
    Exit(AExplicit);
  Sibling := IncludeTrailingPathDelimiter(ExtractFilePath(AExecutable)) +
    DefaultRuntimeBinary;
  if FileExists(Sibling) then
    Result := Sibling;
end;

{ --- TClientReader ------------------------------------------------------ }

constructor TClientReader.Create(AClient: TSessionClient);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
end;

procedure TClientReader.Execute;
var
  Tmp: array[0..4095] of Byte;
  N: Integer;
  Line: string;
  M: TSessionMessage;
begin
  while not Terminated do
  begin
    N := fpRecv(FClient.FFd, @Tmp, SizeOf(Tmp), 0);
    if N > 0 then
    begin
      FClient.FLock.Acquire;
      try
        SetLength(FClient.FInBuf, Length(FClient.FInBuf) + N);
        Move(Tmp, FClient.FInBuf[Length(FClient.FInBuf) - N + 1], N);
      finally
        FClient.FLock.Release;
      end;
    end
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else
      Break;
    while True do
    begin
      FClient.FLock.Acquire;
      try
        if not ExtractLine(FClient.FInBuf, Line) then
          Break;
      finally
        FClient.FLock.Release;
      end;
      if TSessionCodec.Decode(Line, M) then
        FClient.HandleIncoming(M);
    end;
  end;
  if (not Terminated) and (FClient.FSink <> nil) then
    FClient.FSink.OnDetached('connection closed');
end;

{ --- TSessionClient ----------------------------------------------------- }

class function TSessionClient.Open(const AConfig: TSessionClientConfig;
  const ASink: ISessionSink; out AError: string): TSessionClient;
var
  Client: TSessionClient;
  SockPath: string;
  Fd: Integer;
  Deadline: Int64;
  SpawnTimeout: Integer;
  Line: string;
  M: TSessionMessage;
  Attach: TSessionMessage;
  HandshakeTimeout: Integer;
begin
  Result := nil;
  AError := '';
  if AConfig.SessionId = '' then
  begin
    AError := 'session id is required';
    Exit;
  end;
  Client := TSessionClient.Create;
  try
    Client.FConfig := AConfig;
    Client.FSink := ASink;
    Client.FFd := -1;
    Client.FLock := TCriticalSection.Create;
    Client.FReplyEvent := TSimpleEvent.Create;
    SpawnTimeout := AConfig.SpawnTimeoutMs;
    if SpawnTimeout <= 0 then
      SpawnTimeout := DefaultSpawnTimeoutMs;
    HandshakeTimeout := DefaultSpawnTimeoutMs;

    SockPath := SocketPathFor(AConfig.SessionId);
    Deadline := NowMs + SpawnTimeout;
    Fd := -1;
    while True do
    begin
      Fd := ConnectFd(SockPath);
      if Fd >= 0 then
        Break;
      if (not AConfig.Spawn) or (NowMs >= Deadline) then
      begin
        if AConfig.Spawn then
          AError := 'runtime did not start in time'
        else
          AError := 'no runtime for session ' + AConfig.SessionId;
        Client.Free;
        Exit(nil);
      end;
      if not Client.FSpawned then
      begin
        if AConfig.RuntimeCommand = '' then
        begin
          AError := 'no runtime binary; set HILDI_RUNTIME_BIN';
          Client.Free;
          Exit(nil);
        end;
        ForceDirectories(RuntimeDir);
        if not SpawnDetached(AConfig.RuntimeCommand, AConfig.SessionId,
          AConfig.WorkspacePath, AConfig.StorePath,
          RuntimeDir + AConfig.SessionId + '.log',
          AConfig.ApprovalRootSessionId, AConfig.IdleExitMs) then
        begin
          AError := 'could not spawn a runtime';
          Client.Free;
          Exit(nil);
        end;
        Client.FSpawned := True;
      end;
      Sleep(25);
    end;
    Client.FFd := Fd;

    if not ReadLineTimeout(Fd, HandshakeTimeout, Client.FInBuf, Line) then
    begin
      AError := 'runtime did not greet';
      Client.Free;
      Exit(nil);
    end;
    if (not TSessionCodec.Decode(Line, M)) or (M.Kind <> mkHello) then
    begin
      AError := 'unexpected greeting';
      Client.Free;
      Exit(nil);
    end;
    if M.Hello.Version <> SessionProtocolVersion then
    begin
      Attach := Default(TSessionMessage);
      Attach.Kind := mkError;
      Attach.ErrorCode := 'bad_version';
      Attach.ErrorMessage := 'unsupported protocol version';
      Attach.Detail := IntToStr(M.Hello.Version);
      SendAll(Fd, AnsiString(TSessionCodec.Encode(Attach)));
      AError := 'unsupported protocol version ' + IntToStr(M.Hello.Version);
      Client.Free;
      Exit(nil);
    end;
    Client.FHello := M.Hello;
    if ASink <> nil then
      ASink.OnHello(M.Hello);

    Attach := Default(TSessionMessage);
    Attach.Kind := mkAttach;
    Attach.Command.Kind := scAttach;
    Attach.Command.FromSeq := AConfig.FromSeq;
    Attach.Command.Role := AConfig.Role;
    if not SendAll(Fd, AnsiString(TSessionCodec.Encode(Attach))) then
    begin
      AError := 'could not attach';
      Client.Free;
      Exit(nil);
    end;

    if not ReadLineTimeout(Fd, HandshakeTimeout, Client.FInBuf, Line) then
    begin
      AError := 'runtime did not reply to attach';
      Client.Free;
      Exit(nil);
    end;
    if (not TSessionCodec.Decode(Line, M)) or (M.Kind <> mkAttached) then
    begin
      AError := 'attach was refused';
      Client.Free;
      Exit(nil);
    end;
    Client.FRole := M.Attached.Role;
    Client.FAttached := M.Attached;
    if ASink <> nil then
      ASink.OnAttached(M.Attached);

    Client.FReader := TClientReader.Create(Client);
    Client.FReader.Start;
  except
    on E: Exception do
    begin
      Client.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := Client;
end;

destructor TSessionClient.Destroy;
begin
  Close;
  FReplyEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TSessionClient.HandleIncoming(const AMessage: TSessionMessage);
begin
  case AMessage.Kind of
    mkEvent:
      if FSink <> nil then
        FSink.OnEvent(AMessage.Event);
    mkReply:
      begin
        FLock.Acquire;
        try
          if (FWaitId <> '') and (AMessage.ReplyId = FWaitId) then
          begin
            FReply := AMessage;
            FReplyReady := True;
            FReplyEvent.SetEvent;
          end;
        finally
          FLock.Release;
        end;
      end;
    mkDetached:
      if FSink <> nil then
        FSink.OnDetached(AMessage.Reason);
    mkError:
      if FSink <> nil then
        FSink.OnError(AMessage.ErrorCode, AMessage.ErrorMessage);
  else
    ;
  end;
end;

function TSessionClient.Send(const ACommand: TSessionCommand): Boolean;
var
  M: TSessionMessage;
begin
  FLock.Acquire;
  try
    Result := (not FClosed) and (FFd >= 0);
    if not Result then
      Exit;
    M := Default(TSessionMessage);
    case ACommand.Kind of
      scAttach:
        begin
          M.Kind := mkAttach;
          M.Command := ACommand;
        end;
      scDetach:
        begin
          M.Kind := mkDetach;
          M.Command := ACommand;
        end;
      scPing:
        begin
          M.Kind := mkPing;
          M.Command := ACommand;
        end;
    else
      begin
        M.Kind := mkCmd;
        M.Command := ACommand;
      end;
    end;
    Result := SendAll(FFd, AnsiString(TSessionCodec.Encode(M)));
  finally
    FLock.Release;
  end;
end;

function TSessionClient.SendAndWait(const ACommand: TSessionCommand;
  ATimeoutMs: Integer; out AReply: TSessionMessage): Boolean;
begin
  AReply := Default(TSessionMessage);
  FLock.Acquire;
  try
    FWaitId := ACommand.Id;
    FReplyReady := False;
    FReplyEvent.ResetEvent;
  finally
    FLock.Release;
  end;
  if not Send(ACommand) then
    Exit(False);
  if FReplyEvent.WaitFor(ATimeoutMs) <> wrSignaled then
    Exit(False);
  FLock.Acquire;
  try
    AReply := FReply;
    Result := FReplyReady;
  finally
    FLock.Release;
  end;
end;

function TSessionClient.ReaderDone: Boolean;
begin
  Result := (FReader = nil) or FReader.Finished;
end;

procedure TSessionClient.Close;
begin  FLock.Acquire;
  try
    if FClosed then
      Exit;
    FClosed := True;
  finally
    FLock.Release;
  end;
  {$ifdef unix}
  if FFd >= 0 then
    fpshutdown(FFd, 2);                 // SHUT_RDWR: wake the reader
  {$endif}
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FReader.Free;
    FReader := nil;
  end;
  {$ifdef unix}
  if FFd >= 0 then
  begin
    CloseSocket(FFd);
    FFd := -1;
  end;
  {$endif}
end;

end.
