unit hildegard.helper.session.runtime;
{ The per-session headless runtime.

  The runtime owns one session's agent loop and serves the wire protocol over an
  AF_UNIX socket: `bind` is the acquisition (a live socket is the liveness
  proof), the ledger is the durable truth, and the wire carries the live turn
  only. It runs turns on TTurnWorker and bridges approvals through
  TApprovalGate, exactly as the TUI does in-process.

  The wire client (TSessionClient) and the transport primitives live in
  hildegard.helper.session.client and .socket, so a UI client can link the
  client half without the loop or this server.

  Single-threaded runtime loop: one select over the listen socket and the
  attached clients, with the worker's queue drained each pass. No callback
  crosses threads on the server side. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, SyncObjs,
  {$ifdef unix}BaseUnix, Sockets,{$endif}
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.protocol, hildegard.helper.session.socket,
  hildegard.helper.harness.session, hildegard.helper.harness.view,
  hildegard.helper.harness.turn,
  hildegard.helper.harness.turn.worker;

type
  TSessionRuntimeConfig = record
    SessionId: string;          // '' => create a new session
    WorkspacePath: string;      // '' => env / cwd
    StorePath: string;          // required (the runtime is store-backed)
    IdleExitMs: Integer;        // 0 => DefaultIdleExitMs
    { Exit this long after the last client disconnects (ms). 0 => the default;
      negative => never (a runtime outlives its clients). }
    ClientExitGraceMs: Integer;
    Model: string;              // '' => resolved from env/.env
    Endpoint: string;
    Transport: TLLMTransport;   // test seam
  end;

  { One attached client connection. Owned by the runtime's list. }
  TClientConn = class
  public
    Fd: Integer;
    Id: string;
    Role: TSessionRole;
    InBuf: AnsiString;
    OutBuf: AnsiString;
    LastSentSeq: Int64;
    Closing: Boolean;           // close once OutBuf drains
    destructor Destroy; override;
  end;

  TSessionRuntime = class
  private
    FConfig: TSessionRuntimeConfig;
    FSession: THarnessSession;
    FSessionId: string;
    FLoopId: string;
    FSocketPath: string;
    FIdleExitMs: Integer;
    FClientExitGraceMs: Integer;
    FLastClientCount: Integer;
    FListenFd: Integer;
    FClients: TObjectList;
    FStop: Boolean;
    FSignalStop: Boolean;
    FExitReason: string;
    FSeq: Int64;
    FTurnActive: Boolean;
    FWorker: TTurnWorker;
    FDriver: string;
    FPendingDriver: string;
    FPendingSince: Int64;
    FNextClientId: Integer;
    FIdleDeadline: Int64;
    FLoopStarted: TSessionEvent;
    FReplay: array of TSessionEvent;
    FReadSet, FWriteSet: TFDSet;
    FMaxFd: Integer;
    function Bind: Boolean;
    function Hwm: Int64;
    procedure RegisterRow;
    procedure UnregisterRow;
    procedure EmitLoopStarted;
    function EmitEvent(AKind: TSessionEventKind): TSessionEvent;
    procedure Broadcast(const AEvent: TSessionEvent);
    procedure ReplyTo(AClient: TClientConn; const AId: string; AOk: Boolean;
      const AErrorCode: string);
    procedure QueueLine(AClient: TClientConn; const ALine: string);
    procedure FlushConn(AClient: TClientConn);
    procedure DropSlow(AClient: TClientConn);
    procedure SendHello(AClient: TClientConn);
    procedure SendError(AClient: TClientConn; const ACode, AMessage,
      ADetail: string);
    procedure ReplayTo(AClient: TClientConn; AFromSeq: Int64);
    function FindClient(const AId: string): TClientConn;
    procedure BuildSets;
    function NextTimeout: Integer;
    procedure AcceptClient;
    procedure HandleClients;
    procedure ReadClient(AClient: TClientConn);
    procedure HandleLine(AClient: TClientConn; const ALine: string);
    procedure HandleAttach(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandleCommand(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandlePrompt(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandleApprove(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandleInterrupt(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandleClaim(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure HandleRelease(AClient: TClientConn;
      const ACommand: TSessionCommand);
    procedure StartTurn(const AText: string);
    procedure FinishTurn;
    procedure DrainTurn;
    procedure HandleTurnEvent(const AEvent: TTurnEvent);
    procedure ReapClosing;
    procedure PromoteIfPending;
    procedure Shutdown;
  public
    { Resolves the workspace, opens the store, and builds the loop as
      THarnessSession does. Returns nil with AError on failure. }
    class function Open(const AConfig: TSessionRuntimeConfig;
      out AError: string): TSessionRuntime;
    destructor Destroy; override;
    { Bind, then accept and serve until stopped or idle-exit. Blocking. Returns
      the process exit code: 0 on idle-exit or "another runtime is live". }
    function Serve: Integer;
    procedure Stop;
    property SessionId: string read FSessionId;
    property SocketPath: string read FSocketPath;
  end;

const
  DefaultIdleExitMs = 300000;
  { Exit this long after the last client disconnects. Short so a quit TUI does
    not strand a runtime, but long enough to cancel on a quick reattach. }
  DefaultClientExitGraceMs = 2000;
  DefaultDriveRequestMs = 30000;
  { Per-client outbound ceiling; a slower observer is dropped with a gap. }
  DefaultMaxOutBytes = 262144;

{ Parse `--session-runtime` argv and run the runtime. Returns the exit code. }
function RunSessionRuntime(const AArgs: array of string): Integer;

{ The select timeout (ms) for the runtime loop. 0 means "poll without blocking",
  which is only correct when the loop is about to exit; any other value blocks
  (bounded), so an idle runtime does not spin. A client attached keeps the
  runtime up regardless of the idle deadline, so it must block there too. }
function RuntimeSelectTimeout(ATurnActive: Boolean; AClientCount: Integer;
  ARemainingMs: Int64): Integer;

implementation

const
  TurnPollMs = 10;
  IdlePollMs = 200;
  SocketBacklog = 16;

{ --- TClientConn -------------------------------------------------------- }

destructor TClientConn.Destroy;
begin
  {$ifdef unix}
  if Fd >= 0 then
    CloseSocket(Fd);
  {$endif}
  inherited Destroy;
end;

{ --- TSessionRuntime ---------------------------------------------------- }

class function TSessionRuntime.Open(const AConfig: TSessionRuntimeConfig;
  out AError: string): TSessionRuntime;
var
  Runtime: TSessionRuntime;
  HConfig: THarnessSessionConfig;
begin
  Result := nil;
  AError := '';
  if AConfig.StorePath = '' then
  begin
    AError := 'runtime requires a store path';
    Exit;
  end;
  Runtime := TSessionRuntime.Create;
  try
    Runtime.FConfig := AConfig;
    Runtime.FSessionId := AConfig.SessionId;
    Runtime.FIdleExitMs := AConfig.IdleExitMs;
    if Runtime.FIdleExitMs <= 0 then
      Runtime.FIdleExitMs := DefaultIdleExitMs;
    Runtime.FClientExitGraceMs := AConfig.ClientExitGraceMs;
    if Runtime.FClientExitGraceMs = 0 then
      Runtime.FClientExitGraceMs := DefaultClientExitGraceMs;
    Runtime.FClients := TObjectList.Create(True);
    Runtime.FListenFd := -1;
    Runtime.FSeq := 0;
    Runtime.FNextClientId := 0;

    HConfig := Default(THarnessSessionConfig);
    HConfig.WorkspacePath := AConfig.WorkspacePath;
    HConfig.StorePath := AConfig.StorePath;
    HConfig.SessionId := AConfig.SessionId;
    HConfig.Model := AConfig.Model;
    HConfig.Endpoint := AConfig.Endpoint;
    HConfig.Transport := AConfig.Transport;
    Runtime.FSession := THarnessSession.Open(HConfig, AError);
    if Runtime.FSession = nil then
    begin
      Runtime.Free;
      Exit(nil);
    end;
    Runtime.FSessionId := Runtime.FSession.View.SessionId;
    Runtime.FSocketPath := SocketPathFor(Runtime.FSessionId);
    Runtime.FLoopId := NewSessionId;
  except
    on E: Exception do
    begin
      Runtime.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := Runtime;
end;

destructor TSessionRuntime.Destroy;
begin
  Stop;
  if FWorker <> nil then
  begin
    FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  FClients.Free;
  FSession.Free;
  inherited Destroy;
end;

procedure TSessionRuntime.Stop;
begin
  FStop := True;
end;

function TSessionRuntime.Hwm: Int64;
var
  Err: TStoreError;
begin
  Result := 0;
  if not FSession.View.Store.MessageHighWaterMark(FSessionId, Result, Err) then
    Result := 0;
end;

procedure TSessionRuntime.RegisterRow;
var
  Row: TSessionRuntimeRow;
  Err: TStoreError;
begin
  Row := Default(TSessionRuntimeRow);
  Row.SessionId := FSessionId;
  {$ifdef unix}
  Row.Pid := fpGetPid;
  {$else}
  Row.Pid := 0;
  {$endif}
  Row.SocketPath := FSocketPath;
  Row.Status := rsRunning;
  Row.StartedAt := NowMs;
  Row.UpdatedAt := NowMs;
  FSession.View.Store.RegisterRuntime(Row, Err);
end;

procedure TSessionRuntime.UnregisterRow;
var
  Err: TStoreError;
begin
  FSession.View.Store.ClearRuntime(FSessionId, Err);
end;

procedure TSessionRuntime.EmitLoopStarted;
begin
  FLoopStarted := Default(TSessionEvent);
  Inc(FSeq);
  FLoopStarted.Seq := FSeq;
  FLoopStarted.Ts := NowMs;
  FLoopStarted.Kind := ekLoopStarted;
  FLoopStarted.LoopId := FLoopId;
  FLoopStarted.SessionId := FSessionId;
  SetLength(FReplay, 1);
  FReplay[0] := FLoopStarted;
end;

function TSessionRuntime.EmitEvent(AKind: TSessionEventKind): TSessionEvent;
begin
  Inc(FSeq);
  Result := Default(TSessionEvent);
  Result.Seq := FSeq;
  Result.Ts := NowMs;
  Result.Kind := AKind;
end;

procedure TSessionRuntime.Broadcast(const AEvent: TSessionEvent);
var
  I: Integer;
  M: TSessionMessage;
  Line: string;
  C: TClientConn;
begin
  if AEvent.Kind <> ekGap then
  begin
    SetLength(FReplay, Length(FReplay) + 1);
    FReplay[High(FReplay)] := AEvent;
  end;
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event := AEvent;
  Line := TSessionCodec.Encode(M);
  for I := 0 to FClients.Count - 1 do
  begin
    C := TClientConn(FClients[I]);
    if C.Closing then
      Continue;
    C.LastSentSeq := AEvent.Seq;
    QueueLine(C, Line);
  end;
end;

procedure TSessionRuntime.ReplyTo(AClient: TClientConn; const AId: string;
  AOk: Boolean; const AErrorCode: string);
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkReply;
  M.ReplyId := AId;
  M.Ok := AOk;
  M.ErrorCode := AErrorCode;
  QueueLine(AClient, TSessionCodec.Encode(M));
end;

procedure TSessionRuntime.QueueLine(AClient: TClientConn;
  const ALine: string);
begin
  if AClient.Closing then
    Exit;
  AClient.OutBuf := AClient.OutBuf + AnsiString(ALine);
  FlushConn(AClient);
  if Length(AClient.OutBuf) > DefaultMaxOutBytes then
    DropSlow(AClient);
end;

procedure TSessionRuntime.FlushConn(AClient: TClientConn);
var
  N: Integer;
begin
  while AClient.OutBuf <> '' do
  begin
    N := fpSend(AClient.Fd, @AClient.OutBuf[1], Length(AClient.OutBuf),
      SendFlags);
    if N > 0 then
      Delete(AClient.OutBuf, 1, N)
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else if (N < 0) and ((fpGetErrno = ESysEAGAIN) or
      (fpGetErrno = ESysEWOULDBLOCK)) then
      Break
    else
    begin
      { A hard send error means the peer is gone; drop the backlog so the
        connection is reaped instead of lingering forever. }
      AClient.OutBuf := '';
      AClient.Closing := True;
      Break;
    end;
  end;
end;

procedure TSessionRuntime.DropSlow(AClient: TClientConn);
var
  M: TSessionMessage;
begin
  AClient.OutBuf := '';
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event := Default(TSessionEvent);
  M.Event.Seq := FSeq;
  M.Event.Ts := NowMs;
  M.Event.Kind := ekGap;
  M.Event.FromSeq := AClient.LastSentSeq + 1;
  M.Event.ToSeq := AClient.LastSentSeq;
  AClient.OutBuf := AClient.OutBuf + AnsiString(TSessionCodec.Encode(M));
  M := Default(TSessionMessage);
  M.Kind := mkDetached;
  M.Reason := 'slow observer';
  AClient.OutBuf := AClient.OutBuf + AnsiString(TSessionCodec.Encode(M));
  AClient.Closing := True;
  FlushConn(AClient);
end;

procedure TSessionRuntime.SendHello(AClient: TClientConn);
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkHello;
  M.Hello.Protocol := SessionProtocolName;
  M.Hello.Version := SessionProtocolVersion;
  M.Hello.SessionId := FSessionId;
  M.Hello.LoopId := FLoopId;
  M.Hello.Caps := [srObserve, srDrive];
  QueueLine(AClient, TSessionCodec.Encode(M));
end;

procedure TSessionRuntime.SendError(AClient: TClientConn; const ACode,
  AMessage, ADetail: string);
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkError;
  M.ErrorCode := ACode;
  M.ErrorMessage := AMessage;
  M.Detail := ADetail;
  QueueLine(AClient, TSessionCodec.Encode(M));
end;

procedure TSessionRuntime.ReplayTo(AClient: TClientConn; AFromSeq: Int64);
var
  I: Integer;
  M: TSessionMessage;
begin
  for I := 0 to High(FReplay) do
  begin
    if FReplay[I].Seq < AFromSeq then
      Continue;
    M := Default(TSessionMessage);
    M.Kind := mkEvent;
    M.Event := FReplay[I];
    AClient.LastSentSeq := FReplay[I].Seq;
    QueueLine(AClient, TSessionCodec.Encode(M));
  end;
end;

function TSessionRuntime.FindClient(const AId: string): TClientConn;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FClients.Count - 1 do
    if TClientConn(FClients[I]).Id = AId then
      Exit(TClientConn(FClients[I]));
end;

function TSessionRuntime.Bind: Boolean;
var
  Addr: TUnixSockAddr;
  Len: TSockLen;
begin
  Result := False;
  {$ifdef unix}
  ForceDirectories(RuntimeDir);
  fpChmod(RuntimeDir, &700);
  if FileExists(FSocketPath) then
  begin
    if ConnectProbe(FSocketPath) then
      Exit(False);                       // another runtime is live
    fpUnlink(PAnsiChar(AnsiString(FSocketPath)));
  end;
  FListenFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FListenFd < 0 then
    raise Exception.Create('could not create runtime socket');
  SetNoSigPipe(FListenFd);
  if not MakeUnixAddr(FSocketPath, Addr, Len) then
    raise Exception.Create('runtime socket path is too long: ' + FSocketPath);
  if fpBind(FListenFd, PSockAddr(@Addr), Len) <> 0 then
  begin
    if ConnectProbe(FSocketPath) then
      Exit(False);                       // lost a race; another is live
    raise Exception.Create('could not bind runtime socket: ' + FSocketPath);
  end;
  if fpListen(FListenFd, SocketBacklog) <> 0 then
    raise Exception.Create('could not listen on runtime socket');
  SetNonBlocking(FListenFd);
  Result := True;
  {$else}
  raise Exception.Create('session runtimes require Unix sockets');
  {$endif}
end;

procedure TSessionRuntime.BuildSets;
var
  I: Integer;
  C: TClientConn;
begin
  fpFD_ZERO(FReadSet);
  fpFD_ZERO(FWriteSet);
  FMaxFd := FListenFd;
  fpFD_SET(FListenFd, FReadSet);
  for I := 0 to FClients.Count - 1 do
  begin
    C := TClientConn(FClients[I]);
    if C.Fd > FMaxFd then
      FMaxFd := C.Fd;
    if not C.Closing then
      fpFD_SET(C.Fd, FReadSet);
    if C.OutBuf <> '' then
      fpFD_SET(C.Fd, FWriteSet);
  end;
end;

function RuntimeSelectTimeout(ATurnActive: Boolean; AClientCount: Integer;
  ARemainingMs: Int64): Integer;
begin
  if ATurnActive then
    Exit(TurnPollMs);
  { A client keeps the runtime up, so the idle deadline is irrelevant: block on
    select rather than poll. Returning 0 here (the old behaviour) spun the loop
    at 100% CPU once the deadline passed with a client attached. }
  if AClientCount > 0 then
    Exit(IdlePollMs);
  if ARemainingMs <= 0 then
    Exit(0);
  if ARemainingMs > IdlePollMs then
    Result := IdlePollMs
  else
    Result := ARemainingMs;
end;

function TSessionRuntime.NextTimeout: Integer;
begin
  Result := RuntimeSelectTimeout(FTurnActive, FClients.Count,
    FIdleDeadline - NowMs);
end;

{ The signal handler for SIGTERM/SIGINT: async-signal-safe, it only sets a
  flag. The serve loop observes it like FStop. }
var
  GSignalStop: Boolean = False;

procedure RuntimeSignalHandler(ASig: cint); cdecl;
begin
  GSignalStop := True;
end;

procedure InstallRuntimeSignals;
var
  Act: SigActionRec;
begin
  {$ifdef unix}
  FillChar(Act, SizeOf(Act), 0);
  Act.sa_handler := SigActionHandler(@RuntimeSignalHandler);
  fpSigAction(SIGTERM, @Act, nil);
  fpSigAction(SIGINT, @Act, nil);
  {$endif}
end;

procedure TSessionRuntime.AcceptClient;
var
  Addr: TUnixSockAddr;
  Len: TSockLen;
  Fd: Integer;
  C: TClientConn;
begin
  {$ifdef unix}
  Len := SizeOf(Addr);
  Fd := fpAccept(FListenFd, PSockAddr(@Addr), @Len);
  if Fd < 0 then
    Exit;
  SetNoSigPipe(Fd);
  SetNonBlocking(Fd);
  C := TClientConn.Create;
  C.Fd := Fd;
  Inc(FNextClientId);
  C.Id := 'c' + IntToStr(FNextClientId);
  FClients.Add(C);
  SendHello(C);
  {$endif}
end;

procedure TSessionRuntime.ReadClient(AClient: TClientConn);
var
  Tmp: array[0..4095] of Byte;
  N: Integer;
  Line: string;
begin
  {$ifdef unix}
  while True do
  begin
    N := fpRecv(AClient.Fd, @Tmp, SizeOf(Tmp), 0);
    if N > 0 then
    begin
      SetLength(AClient.InBuf, Length(AClient.InBuf) + N);
      Move(Tmp, AClient.InBuf[Length(AClient.InBuf) - N + 1], N);
    end
    else if (N < 0) and (fpGetErrno = ESysEINTR) then
      Continue
    else if (N < 0) and ((fpGetErrno = ESysEAGAIN) or
      (fpGetErrno = ESysEWOULDBLOCK)) then
      Break
    else
    begin
      AClient.Closing := True;
      Break;
    end;
  end;
  while ExtractLine(AClient.InBuf, Line) do
    HandleLine(AClient, Line);
  {$endif}
end;

procedure TSessionRuntime.HandleClients;
var
  I: Integer;
  C: TClientConn;
begin
  for I := FClients.Count - 1 downto 0 do
  begin
    C := TClientConn(FClients[I]);
    if (not C.Closing) and (fpFD_ISSET(C.Fd, FReadSet) <> 0) then
      ReadClient(C);
    if C.OutBuf <> '' then
      FlushConn(C);
  end;
end;

procedure TSessionRuntime.HandleLine(AClient: TClientConn; const ALine: string);
var
  M: TSessionMessage;
begin
  if not TSessionCodec.Decode(ALine, M) then
  begin
    SendError(AClient, 'bad_message', 'could not parse message', '');
    AClient.Closing := True;
    Exit;
  end;
  case M.Kind of
    mkAttach:
      HandleAttach(AClient, M.Command);
    mkDetach:
      AClient.Closing := True;
    mkCmd:
      HandleCommand(AClient, M.Command);
    mkPing:
      begin
        M := Default(TSessionMessage);
        M.Kind := mkPong;
        QueueLine(AClient, TSessionCodec.Encode(M));
      end;
  else
    SendError(AClient, 'bad_message', 'unexpected message', '');
  end;
end;

procedure TSessionRuntime.HandleAttach(AClient: TClientConn;
  const ACommand: TSessionCommand);
var
  Granted: TSessionRole;
  M: TSessionMessage;
begin
  if ACommand.FromSeq < 0 then
  begin
    SendError(AClient, 'bad_message', 'from_seq must be >= 0', '');
    AClient.Closing := True;
    Exit;
  end;

  Granted := srObserve;
  if ACommand.Role = srDrive then
    if (FDriver = '') or (FDriver = AClient.Id) then
    begin
      FDriver := AClient.Id;
      Granted := srDrive;
    end;
  AClient.Role := Granted;

  M := Default(TSessionMessage);
  M.Kind := mkAttached;
  M.Attached.Role := Granted;
  M.Attached.Driver := FDriver;
  M.Attached.LastSeq := FSeq;
  M.Attached.StoreHwm := Hwm;
  QueueLine(AClient, TSessionCodec.Encode(M));
  ReplayTo(AClient, ACommand.FromSeq);
end;

procedure TSessionRuntime.HandleCommand(AClient: TClientConn;
  const ACommand: TSessionCommand);
begin
  case ACommand.Kind of
    scPrompt:
      HandlePrompt(AClient, ACommand);
    scApprove:
      HandleApprove(AClient, ACommand);
    scInterrupt:
      HandleInterrupt(AClient, ACommand);
    scClaimDrive:
      HandleClaim(AClient, ACommand);
    scReleaseDrive:
      HandleRelease(AClient, ACommand);
    scPing:
      ReplyTo(AClient, ACommand.Id, True, '');
    scShutdown:
      begin
        if AClient.Role <> srDrive then
        begin
          ReplyTo(AClient, ACommand.Id, False, 'not_driver');
          Exit;
        end;
        ReplyTo(AClient, ACommand.Id, True, '');
        FExitReason := 'shutdown_command';
        FStop := True;
      end;
    scAttach, scDetach:
      SendError(AClient, 'unknown_cmd', 'unknown command', '');
  end;
end;

procedure TSessionRuntime.HandlePrompt(AClient: TClientConn;
  const ACommand: TSessionCommand);
begin
  if AClient.Role <> srDrive then
  begin
    ReplyTo(AClient, ACommand.Id, False, 'not_driver');
    Exit;
  end;
  if FWorker <> nil then
    FWorker.QueuePrompt(ACommand.Text)
  else
    StartTurn(ACommand.Text);
  ReplyTo(AClient, ACommand.Id, True, '');
end;

procedure TSessionRuntime.HandleApprove(AClient: TClientConn;
  const ACommand: TSessionCommand);
var
  E: TSessionEvent;
begin
  if AClient.Role <> srDrive then
  begin
    ReplyTo(AClient, ACommand.Id, False, 'not_driver');
    Exit;
  end;
  FSession.Gate.Answer(StrToIntDef(ACommand.AskId, 0), ACommand.Choice);
  E := EmitEvent(ekApprovalResolved);
  E.AskId := ACommand.AskId;
  E.Choice := ACommand.Choice;
  Broadcast(E);
  ReplyTo(AClient, ACommand.Id, True, '');
end;

procedure TSessionRuntime.HandleInterrupt(AClient: TClientConn;
  const ACommand: TSessionCommand);
begin
  if AClient.Role <> srDrive then
  begin
    ReplyTo(AClient, ACommand.Id, False, 'not_driver');
    Exit;
  end;
  if FWorker <> nil then
    FWorker.RequestCancel;
  ReplyTo(AClient, ACommand.Id, True, '');
end;

procedure TSessionRuntime.HandleClaim(AClient: TClientConn;
  const ACommand: TSessionCommand);
var
  E: TSessionEvent;
begin
  if FDriver = AClient.Id then
  begin
    ReplyTo(AClient, ACommand.Id, True, '');
    Exit;
  end;
  if FDriver = '' then
  begin
    FDriver := AClient.Id;
    AClient.Role := srDrive;
    FPendingDriver := '';
    E := EmitEvent(ekDriveGranted);
    E.Client := FDriver;
    Broadcast(E);
    ReplyTo(AClient, ACommand.Id, True, '');
    Exit;
  end;
  { Held: ask the driver. A driver is never evicted without consent. }
  FPendingDriver := AClient.Id;
  FPendingSince := NowMs;
  E := EmitEvent(ekDriveRequested);
  E.Client := AClient.Id;
  Broadcast(E);
  ReplyTo(AClient, ACommand.Id, False, 'drive_held');
end;

procedure TSessionRuntime.HandleRelease(AClient: TClientConn;
  const ACommand: TSessionCommand);
var
  OldDriver: string;
  E: TSessionEvent;
begin
  if FDriver <> AClient.Id then
  begin
    ReplyTo(AClient, ACommand.Id, False, 'not_driver');
    Exit;
  end;
  OldDriver := FDriver;
  FDriver := '';
  AClient.Role := srObserve;
  if FPendingDriver <> '' then
    PromoteIfPending
  else
  begin
    E := EmitEvent(ekDriveReleased);
    E.Client := OldDriver;
    Broadcast(E);
  end;
  ReplyTo(AClient, ACommand.Id, True, '');
end;

procedure TSessionRuntime.PromoteIfPending;
var
  C: TClientConn;
  E: TSessionEvent;
begin
  if FPendingDriver = '' then
    Exit;
  C := FindClient(FPendingDriver);
  if C = nil then
  begin
    FPendingDriver := '';
    Exit;
  end;
  FDriver := FPendingDriver;
  FPendingDriver := '';
  C.Role := srDrive;
  E := EmitEvent(ekDriveGranted);
  E.Client := FDriver;
  Broadcast(E);
end;

procedure TSessionRuntime.StartTurn(const AText: string);
var
  E: TSessionEvent;
begin
  E := EmitEvent(ekUserMessage);
  E.Text := AText;
  Broadcast(E);
  FTurnActive := True;
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText);
  FWorker.Start;
end;

procedure TSessionRuntime.FinishTurn;
begin
  if FWorker <> nil then
  begin
    FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  FTurnActive := False;
  SetLength(FReplay, 1);
  FReplay[0] := FLoopStarted;
  FIdleDeadline := NowMs + FIdleExitMs;
end;

procedure TSessionRuntime.DrainTurn;
var
  Ev: TTurnEvent;
begin
  while FSession.Queue.Pop(Ev) do
    HandleTurnEvent(Ev);
end;

procedure TSessionRuntime.HandleTurnEvent(const AEvent: TTurnEvent);
var
  E: TSessionEvent;
  Turn: TTurnRecord;
begin
  case AEvent.Kind of
    teUserMessage, tePromptQueued:
      begin
        E := EmitEvent(ekUserMessage);
        E.Text := AEvent.Text;
        Broadcast(E);
      end;
    teAssistantDelta:
      begin
        E := EmitEvent(ekAssistantDelta);
        E.Text := AEvent.Text;
        Broadcast(E);
      end;
    teReasoningDelta:
      begin
        E := EmitEvent(ekReasoningDelta);
        E.Text := AEvent.Text;
        Broadcast(E);
      end;
    teReasoningDone:
      begin
        E := EmitEvent(ekReasoningDone);
        E.ElapsedMs := AEvent.ElapsedMs;
        Broadcast(E);
      end;
    teToolCall:
      begin
        E := EmitEvent(ekToolCall);
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.ToolArguments := AEvent.ToolArguments;
        E.ToolReason := AEvent.ToolReason;
        Broadcast(E);
      end;
    teToolResult:
      begin
        E := EmitEvent(ekToolResult);
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.Text := AEvent.Text;
        E.ToolOk := AEvent.ToolOk;
        Broadcast(E);
      end;
    teToolOutput:
      begin
        E := EmitEvent(ekToolOutput);
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.Text := AEvent.Text;
        Broadcast(E);
      end;
    teApprovalAsk:
      begin
        E := EmitEvent(ekApprovalRequest);
        E.AskId := IntToStr(AEvent.RequestId);
        E.Ask := AEvent.Ask;
        Broadcast(E);
      end;
    teDone:
      begin
        E := EmitEvent(ekTurnFinished);
        Turn := FSession.View.LastTurn;
        E.FinishReason := Turn.FinishReason;
        if E.FinishReason = '' then
          E.FinishReason := 'stop';
        E.Usage := Turn.Usage;
        E.ElapsedMs := AEvent.ElapsedMs;
        Broadcast(E);
        FinishTurn;
      end;
    teError:
      begin
        E := EmitEvent(ekError);
        E.ErrorCode := SessionErrorCodeToWire(AEvent.ErrorCode);
        E.Text := AEvent.Text;
        E.Detail := AEvent.Detail;
        E.Dropped := AEvent.Dropped;
        Broadcast(E);
        E := EmitEvent(ekTurnFinished);
        E.FinishReason := 'error';
        E.ElapsedMs := AEvent.ElapsedMs;
        Broadcast(E);
        FinishTurn;
      end;
  end;
end;

procedure TSessionRuntime.ReapClosing;
var
  I: Integer;
  C: TClientConn;
  Reaped: Boolean;
begin
  Reaped := False;
  for I := FClients.Count - 1 downto 0 do
  begin
    C := TClientConn(FClients[I]);
    if C.Closing and (C.OutBuf = '') then
    begin
      if C.Id = FDriver then
      begin
        FDriver := '';
        FClients.Delete(I);
        PromoteIfPending;
        Reaped := True;
        Continue;
      end;
      FClients.Delete(I);
      Reaped := True;
    end;
  end;
  { The idle clock runs from when the runtime becomes idle, not from startup or
    the last turn: start it when the last client leaves, so a reconnect within
    the timeout reuses this runtime. }
  if Reaped and (FClients.Count = 0) then
    FIdleDeadline := NowMs + FIdleExitMs;
end;

procedure TSessionRuntime.Shutdown;
var
  I: Integer;
  C: TClientConn;
  M: TSessionMessage;
  E: TSessionEvent;
  Line: string;
  Deadline: Int64;
  Drained: Boolean;
begin
  E := EmitEvent(ekLoopExited);
  if FExitReason <> '' then
    E.Reason := FExitReason
  else if FStop then
    E.Reason := 'stopped'
  else
    E.Reason := 'idle';
  Broadcast(E);

  M := Default(TSessionMessage);
  M.Kind := mkDetached;
  M.Reason := 'loop exited';
  Line := TSessionCodec.Encode(M);
  for I := 0 to FClients.Count - 1 do
    TClientConn(FClients[I]).OutBuf := TClientConn(FClients[I]).OutBuf +
      AnsiString(Line);

  Deadline := NowMs + 500;
  repeat
    Drained := True;
    for I := 0 to FClients.Count - 1 do
    begin
      C := TClientConn(FClients[I]);
      FlushConn(C);
      if C.OutBuf <> '' then
        Drained := False;
    end;
  until Drained or (NowMs >= Deadline);

  FClients.Clear;
  {$ifdef unix}
  if FListenFd >= 0 then
  begin
    CloseSocket(FListenFd);
    FListenFd := -1;
  end;
  fpUnlink(PAnsiChar(AnsiString(FSocketPath)));
  {$endif}
  UnregisterRow;
end;

function TSessionRuntime.Serve: Integer;
var
  N: Integer;
begin
  Result := 0;
  try
    if not Bind then
      Exit(0);                          // another runtime is live
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'session runtime: ' + E.Message);
      Exit(1);
    end;
  end;
  RegisterRow;
  EmitLoopStarted;
  InstallRuntimeSignals;
  try
    FIdleDeadline := NowMs + FIdleExitMs;
    FLastClientCount := 0;
    while not FStop do
    begin
      if GSignalStop then
      begin
        FExitReason := 'signal';
        Break;
      end;
      BuildSets;
      N := fpSelect(FMaxFd + 1, @FReadSet, @FWriteSet, nil, NextTimeout);
      if N < 0 then
      begin
        if fpGetErrno = ESysEINTR then
          Continue;
        Break;
      end;
      if N > 0 then
      begin
        if fpFD_ISSET(FListenFd, FReadSet) <> 0 then
          AcceptClient;
        HandleClients;
      end;
      DrainTurn;
      ReapClosing;
      if FStop then
        Break;
      { No-clients exit: the last client left and no turn is active; exit after
        the grace (a reattach resets the deadline; a negative grace disables). }
      if (FClients.Count <> FLastClientCount) then
      begin
        FLastClientCount := FClients.Count;
        if (FClients.Count = 0) and (FClientExitGraceMs > 0) then
        begin
          FIdleDeadline := NowMs + FClientExitGraceMs;
          FExitReason := 'no_clients';
        end
        else if FClients.Count > 0 then
        begin
          FIdleDeadline := NowMs + FIdleExitMs;
          FExitReason := '';   { a live client cancels a pending reason }
        end;
      end;
      if (not FTurnActive) and (FClients.Count = 0) and
        (NowMs >= FIdleDeadline) then
        Break;
      if (FPendingDriver <> '') and
        (NowMs - FPendingSince > DefaultDriveRequestMs) then
        FPendingDriver := '';
    end;
  finally
    Shutdown;
  end;
end;

{ --- RunSessionRuntime -------------------------------------------------- }

function RunSessionRuntime(const AArgs: array of string): Integer;
var
  I: Integer;
  SessionId, Workspace, Store, Model, Endpoint: string;
  IdleMs: Integer;
  Cfg: TSessionRuntimeConfig;
  Runtime: TSessionRuntime;
  Err: string;
begin
  SessionId := '';
  Workspace := '';
  Store := '';
  Model := '';
  Endpoint := '';
  IdleMs := 0;
  I := 0;
  while I <= High(AArgs) do
  begin
    if AArgs[I] = '--session-runtime' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        SessionId := AArgs[I];
    end
    else if AArgs[I] = '--workspace' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        Workspace := AArgs[I];
    end
    else if AArgs[I] = '--store' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        Store := AArgs[I];
    end
    else if AArgs[I] = '--model' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        Model := AArgs[I];
    end
    else if AArgs[I] = '--endpoint' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        Endpoint := AArgs[I];
    end
    else if AArgs[I] = '--idle-ms' then
    begin
      Inc(I);
      if I <= High(AArgs) then
        IdleMs := StrToIntDef(AArgs[I], 0);
    end;
    Inc(I);
  end;

  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := SessionId;
  Cfg.WorkspacePath := Workspace;
  Cfg.StorePath := Store;
  Cfg.Model := Model;
  Cfg.Endpoint := Endpoint;
  Cfg.IdleExitMs := IdleMs;
  if Cfg.IdleExitMs <= 0 then
    Cfg.IdleExitMs := StrToIntDef(
      GetEnvironmentVariable('HILDEGARD_RUNTIME_IDLE_MS'), 0);
  Runtime := TSessionRuntime.Open(Cfg, Err);
  if Runtime = nil then
  begin
    WriteLn(StdErr, 'session runtime: ' + Err);
    Exit(1);
  end;
  try
    Result := Runtime.Serve;
  finally
    Runtime.Free;
  end;
end;

end.
