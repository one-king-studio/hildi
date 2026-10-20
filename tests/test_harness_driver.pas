unit test_harness_driver;
{ fpcunit tests for hildegard.helper.harness.driver: the local driver over the
  in-process worker, and the remote driver over a real runtime + fake LLM
  transport. No terminal. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.protocol, hildegard.helper.session.socket,
  hildegard.helper.session.client, hildegard.helper.session.runtime,
  hildegard.helper.harness.session, hildegard.helper.harness.view,
  hildegard.helper.harness.turn,
  hildegard.helper.harness.driver,
  hildegard.helper.harness.driver.local,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.chat,
  hildegard.helper.harness.app,
  hildegard.helper.workspace, llm_fakes;

type
  { Runs Gate.Ask on its own thread so the driver can answer it. }
  TGateAskThread = class(TThread)
  private
    FGate: TApprovalGate;
    FAsk: TApprovalAsk;
  public
    Choice: TApprovalChoice;
    constructor Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
    procedure Execute; override;
  end;

  { Sleeps after every stream chunk, so a turn stays in flight long enough to
    interrupt. }
  TSlowChunks = class
  private
    FMs: Integer;
  public
    constructor Create(AMs: Integer);
    procedure AfterChunk(Sender: TObject);
  end;

  { Runs Serve on its own thread. }
  TRuntimeThread = class(TThread)
  private
    FRuntime: TSessionRuntime;
  public
    ExitCode: Integer;
    constructor Create(ARuntime: TSessionRuntime);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  THarnessDriverTest = class(TTestCase)
  private
    FDir, FWs, FDbPath: string;
    function StoreConfig: TStoreConfig;
    function Config(ATransport: TLLMTransport = nil): THarnessSessionConfig;
    function NewSession: string;
    function MakeRuntime(const ASessionId: string;
      ATransport: TLLMTransport; AIdleMs: Integer = 60000): TSessionRuntime;
    function ClientConfig(const ASessionId: string;
      ASpawn: Boolean = False): TSessionClientConfig;
    function WaitForSocket(const ASessionId: string;
      ATimeoutMs: Integer): Boolean;
    procedure DeleteSocket(const ASessionId: string);
    function DrainKind(ADriver: ISessionDriver; AKind: TTurnEventKind;
      ATimeoutMs: Integer): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestLocalDriverEmitsUserMessageThenDone;
    procedure TestLocalDriverNormalisesQueuedPrompt;
    procedure TestLocalDriverApprovalAskCarriesRefAndResolvesGate;
    procedure TestRemoteDriverRendersATurn;
    procedure TestRemoteDriverApprovalRoundTrip;
    procedure TestRemoteDriverInterrupt;
    procedure TestRemoteDriverReconnectsAfterRuntimeExit;
    procedure TestAppRemoteTurnRenders;
    procedure TestAppRemoteFailedTurnEndsInErrorWithoutDivider;
  end;

implementation

uses
  DateUtils;

constructor TGateAskThread.Create(AGate: TApprovalGate;
  const AAsk: TApprovalAsk);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FGate := AGate;
  FAsk := AAsk;
end;

procedure TGateAskThread.Execute;
begin
  Choice := FGate.Ask(FAsk);
end;

constructor TSlowChunks.Create(AMs: Integer);
begin
  inherited Create;
  FMs := AMs;
end;

procedure TSlowChunks.AfterChunk(Sender: TObject);
begin
  Sleep(FMs);
end;

constructor TRuntimeThread.Create(ARuntime: TSessionRuntime);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRuntime := ARuntime;
end;

destructor TRuntimeThread.Destroy;
begin
  FRuntime.Free;
  inherited Destroy;
end;

procedure TRuntimeThread.Execute;
begin
  ExitCode := FRuntime.Serve;
end;

{ THarnessDriverTest }

procedure THarnessDriverTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhdrv_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  FWs := IncludeTrailingPathDelimiter(FDir) + 'ws';
  ForceDirectories(FWs);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure THarnessDriverTest.TearDown;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FWs);
  RemoveDir(FDir);
end;

function THarnessDriverTest.StoreConfig: TStoreConfig;
begin
  Result := Default(TStoreConfig);
  Result.DatabasePath := FDbPath;
  Result.BusyTimeoutMs := 5000;
end;

function THarnessDriverTest.Config(ATransport: TLLMTransport): THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FWs;
  Result.StorePath := FDbPath;
  Result.Transport := ATransport;
end;

function THarnessDriverTest.NewSession: string;
var
  S: TSqliteStore;
  Ws: TWorkspace;
  WsErr: string;
  Id: Integer;
  Err: TStoreError;
begin
  Result := '';
  Ws := TWorkspace.Open(FWs, WsErr);
  if Ws = nil then
    raise Exception.Create('workspace: ' + WsErr);
  try
    S := TSqliteStore.Create(StoreConfig);
    try
      if not S.Open(Err) then
        raise Exception.Create('store: ' + Err.Message);
      S.EnsureWorkspace(Ws.Root, Id, Err);
      if not S.CreateSession(Id, Result, Err) then
        raise Exception.Create('session: ' + Err.Message);
    finally
      S.Close;
      S.Free;
    end;
  finally
    Ws.Free;
  end;
end;

function THarnessDriverTest.MakeRuntime(const ASessionId: string;
  ATransport: TLLMTransport; AIdleMs: Integer): TSessionRuntime;
var
  Cfg: TSessionRuntimeConfig;
  Err: string;
begin
  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := ASessionId;
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.IdleExitMs := AIdleMs;
  Cfg.Transport := ATransport;
  Result := TSessionRuntime.Open(Cfg, Err);
  if Result = nil then
    raise Exception.Create('runtime: ' + Err);
end;

function THarnessDriverTest.ClientConfig(const ASessionId: string;
  ASpawn: Boolean): TSessionClientConfig;
begin
  Result := Default(TSessionClientConfig);
  Result.SessionId := ASessionId;
  Result.WorkspacePath := FWs;
  Result.StorePath := FDbPath;
  Result.Role := srDrive;
  Result.Spawn := ASpawn;
  Result.SpawnTimeoutMs := 3000;
  Result.RuntimeCommand := ExpandFileName(ParamStr(0));
  Result.IdleExitMs := 1500;
end;

function THarnessDriverTest.WaitForSocket(const ASessionId: string;
  ATimeoutMs: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if SessionSocketReady(ASessionId) then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure THarnessDriverTest.DeleteSocket(const ASessionId: string);
begin
  DeleteFile(SocketPathFor(ASessionId));
  DeleteFile(RuntimeDir + ASessionId + '.log');
end;

function THarnessDriverTest.DrainKind(ADriver: ISessionDriver;
  AKind: TTurnEventKind; ATimeoutMs: Integer): Boolean;
var
  E: TTurnEvent;
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    while ADriver.PopEvent(E) do
      if E.Kind = AKind then
        Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure THarnessDriverTest.TestLocalDriverEmitsUserMessageThenDone;
var
  Session: THarnessSession;
  Driver: ISessionDriver;
  Fake: TFakeTransport;
  Err: string;
  E: TTurnEvent;
  SawUser, SawDelta, SawDone: Boolean;
  Deadline: Int64;
  Text: string;
begin
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([TextDelta('hello'), FinishFrame('stop'), DoneFrame]);
    Session := THarnessSession.Open(Config(Fake), Err);
    AssertTrue('session: ' + Err, Session <> nil);
    try
      Driver := LocalDriver(Session);
      try
        Driver.StartTurn('hi');
        SawUser := False;
        SawDelta := False;
        SawDone := False;
        Text := '';
        Deadline := GetTickCount64 + 5000;
        repeat
          while Driver.PopEvent(E) do
            case E.Kind of
              teUserMessage:
                begin
                  SawUser := True;
                  AssertEquals('user text', 'hi', E.Text);
                end;
              teAssistantDelta:
                begin
                  SawDelta := True;
                  Text := Text + E.Text;
                end;
              teDone:
                SawDone := True;
            else
              ;
            end;
          Sleep(5);
        until SawDone or (GetTickCount64 >= Deadline);
        AssertTrue('user message first', SawUser);
        AssertTrue('deltas', SawDelta);
        AssertEquals('answer text', 'hello', Text);
        AssertTrue('done', SawDone);
      finally
        Driver.Close;
        Driver := nil;
      end;
    finally
      Session.Free;
    end;
  finally
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestLocalDriverNormalisesQueuedPrompt;
var
  Session: THarnessSession;
  Driver: ISessionDriver;
  Fake: TFakeTransport;
  Err: string;
  E: TTurnEvent;
  SawUser: Boolean;
  Deadline: Int64;
  Slow: TSlowChunks;
begin
  Fake := TFakeTransport.Create;
  Slow := TSlowChunks.Create(60);
  try
    Fake.AfterChunk := Slow.AfterChunk;
    Fake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
    Fake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);
    Session := THarnessSession.Open(Config(Fake), Err);
    AssertTrue('session: ' + Err, Session <> nil);
    try
      Driver := LocalDriver(Session);
      try
        Driver.StartTurn('first');
        { Wait for the turn to be in flight, then queue a second prompt. }
        Sleep(60);
        Driver.QueuePrompt('second');
        SawUser := False;
        Deadline := GetTickCount64 + 8000;
        repeat
          while Driver.PopEvent(E) do
            if (E.Kind = teUserMessage) and (E.Text = 'second') then
              SawUser := True;
          Sleep(5);
        until SawUser or (GetTickCount64 >= Deadline);
        AssertTrue('a queued prompt surfaces as a user message', SawUser);
      finally
        Driver.Close;
        Driver := nil;
      end;
    finally
      Session.Free;
    end;
  finally
    Slow.Free;
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestLocalDriverApprovalAskCarriesRefAndResolvesGate;
var
  Session: THarnessSession;
  Driver: ISessionDriver;
  Err: string;
  E: TTurnEvent;
  Ask: TApprovalAsk;
  Thread: TGateAskThread;
  AskRef: string;
  Choice: TApprovalChoice;
  Deadline: Int64;
begin
  Session := THarnessSession.Open(Config, Err);
  AssertTrue('session: ' + Err, Session <> nil);
  try
    Driver := LocalDriver(Session);
    try
      Ask := Default(TApprovalAsk);
      Ask.Summary := 'run cat?';
      Thread := TGateAskThread.Create(Session.Gate, Ask);
      Thread.Start;
      AskRef := '';
      Deadline := GetTickCount64 + 3000;
      repeat
        while Driver.PopEvent(E) do
          if E.Kind = teApprovalAsk then
            AskRef := E.AskRef;
        if AskRef = '' then
          Sleep(5);
      until (AskRef <> '') or (GetTickCount64 >= Deadline);
      AssertTrue('ask carries a ref', AskRef <> '');

      Choice := Default(TApprovalChoice);
      Choice.Allowed := True;
      Choice.OptionKey := 'once';
      Driver.AnswerAsk(AskRef, Choice);

      Thread.WaitFor;
      AssertTrue('the gate was resolved', Thread.Choice.Allowed);
      AssertEquals('option key', 'once', Thread.Choice.OptionKey);
      Thread.Free;
    finally
      Driver.Close;
      Driver := nil;
    end;
  finally
    Session.Free;
  end;
end;

procedure THarnessDriverTest.TestRemoteDriverRendersATurn;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: ISessionDriver;
  Err, Text: string;
  E: TTurnEvent;
  SawUser, SawDone: Boolean;
  Deadline: Int64;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([TextDelta('hello '), TextDelta('world'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Driver := RemoteDriver(ClientConfig(Id), Err);
      AssertNotNull('driver connects: ' + Err, Driver);
      try
        Driver.StartTurn('hi');
        SawUser := False;
        SawDone := False;
        Text := '';
        Deadline := GetTickCount64 + 6000;
        repeat
          while Driver.PopEvent(E) do
            case E.Kind of
              teUserMessage:
                SawUser := True;
              teAssistantDelta:
                Text := Text + E.Text;
              teDone:
                SawDone := True;
            else
              ;
            end;
          Sleep(5);
        until SawDone or (GetTickCount64 >= Deadline);
        AssertTrue('user message', SawUser);
        AssertEquals('streamed answer', 'hello world', Text);
        AssertTrue('done', SawDone);
      finally
        Driver.Close;
        Driver := nil;
      end;
    finally
      Rt.Stop;
      Th.WaitFor;
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestRemoteDriverApprovalRoundTrip;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: ISessionDriver;
  Err, AskRef: string;
  E: TTurnEvent;
  Choice: TApprovalChoice;
  Deadline: Int64;
  SawDone: Boolean;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([ToolNameFrame(0, 'call_1', 'run_command'),
      ToolArgsFrame(0, '{"command":"ls","reason":"test"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    Fake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Driver := RemoteDriver(ClientConfig(Id), Err);
      AssertNotNull('driver connects: ' + Err, Driver);
      try
        Driver.StartTurn('run it');
        AskRef := '';
        Deadline := GetTickCount64 + 6000;
        repeat
          while Driver.PopEvent(E) do
            if E.Kind = teApprovalAsk then
              AskRef := E.AskRef;
          if AskRef = '' then
            Sleep(5);
        until (AskRef <> '') or (GetTickCount64 >= Deadline);
        AssertTrue('ask reached the driver', AskRef <> '');

        { Deny it so no command runs. }
        Choice := Default(TApprovalChoice);
        Choice.Allowed := False;
        Driver.AnswerAsk(AskRef, Choice);

        SawDone := False;
        Deadline := GetTickCount64 + 6000;
        repeat
          while Driver.PopEvent(E) do
            if E.Kind = teDone then
              SawDone := True;
          if not SawDone then
            Sleep(5);
        until SawDone or (GetTickCount64 >= Deadline);
        AssertTrue('turn finished after the decision', SawDone);
      finally
        Driver.Close;
        Driver := nil;
      end;
    finally
      Rt.Stop;
      Th.WaitFor;
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestRemoteDriverInterrupt;
var
  Id: string;
  Fake: TFakeTransport;
  Slow: TSlowChunks;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: ISessionDriver;
  Err: string;
  E: TTurnEvent;
  SawCancel: Boolean;
  Deadline: Int64;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  Slow := TSlowChunks.Create(80);
  try
    Fake.AfterChunk := Slow.AfterChunk;
    Fake.AddResponse([TextDelta('one'), TextDelta('two'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Driver := RemoteDriver(ClientConfig(Id), Err);
      AssertNotNull('driver connects: ' + Err, Driver);
      try
        Driver.StartTurn('hi');
        Sleep(80);
        Driver.Interrupt;
        SawCancel := False;
        Deadline := GetTickCount64 + 6000;
        repeat
          while Driver.PopEvent(E) do
            if (E.Kind = teError) and (E.ErrorCode = leCancelled) then
              SawCancel := True;
          if not SawCancel then
            Sleep(5);
        until SawCancel or (GetTickCount64 >= Deadline);
        AssertTrue('the turn was cancelled', SawCancel);
      finally
        Driver.Close;
        Driver := nil;
      end;
    finally
      Rt.Stop;
      Th.WaitFor;
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Slow.Free;
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestRemoteDriverReconnectsAfterRuntimeExit;
var
  Id: string;
  FakeA, FakeB: TFakeTransport;
  RtA, RtB: TSessionRuntime;
  ThA, ThB: TRuntimeThread;
  Driver: ISessionDriver;
  Err, Text: string;
  E: TTurnEvent;
  SawDetach, SawDone: Boolean;
  Deadline: Int64;
begin
  Id := NewSession;
  FakeA := TFakeTransport.Create;
  FakeB := TFakeTransport.Create;
  try
    FakeA.AddResponse([TextDelta('first'), FinishFrame('stop'), DoneFrame]);
    FakeB.AddResponse([TextDelta('second'), FinishFrame('stop'), DoneFrame]);

    RtA := MakeRuntime(Id, FakeA);
    ThA := TRuntimeThread.Create(RtA);
    ThA.Start;
    AssertTrue('bound A', WaitForSocket(Id, 5000));
    Driver := RemoteDriver(ClientConfig(Id), Err);
    AssertNotNull('driver connects: ' + Err, Driver);
    try
      Driver.StartTurn('one');
      AssertTrue('turn one ran', DrainKind(Driver, teDone, 5000));

      { Stop the runtime; the driver detaches. }
      RtA.Stop;
      ThA.WaitFor;
      ThA.Free;
      DeleteSocket(Id);

      SawDetach := False;
      Deadline := GetTickCount64 + 3000;
      repeat
        while Driver.PopEvent(E) do
          if E.Kind = teError then
            SawDetach := True;
        if not SawDetach then
          Sleep(5);
      until SawDetach or (GetTickCount64 >= Deadline);
      AssertTrue('driver noticed the exit', SawDetach);

      { A new runtime for the same session; the driver reconnects on demand. }
      RtB := MakeRuntime(Id, FakeB);
      ThB := TRuntimeThread.Create(RtB);
      try
        ThB.Start;
        AssertTrue('bound B', WaitForSocket(Id, 5000));
        Driver.StartTurn('two');
        SawDone := False;
        Text := '';
        Deadline := GetTickCount64 + 6000;
        repeat
          while Driver.PopEvent(E) do
          begin
            if E.Kind = teAssistantDelta then
              Text := Text + E.Text;
            if E.Kind = teDone then
              SawDone := True;
          end;
          if not SawDone then
            Sleep(5);
        until SawDone or (GetTickCount64 >= Deadline);
        AssertTrue('reconnected and ran', SawDone);
        AssertEquals('the new runtime served it', 'second', Text);
      finally
        RtB.Stop;
        ThB.WaitFor;
        ThB.Free;
        DeleteSocket(Id);
      end;
    finally
      Driver.Close;
      Driver := nil;
    end;
  finally
    FakeB.Free;
    FakeA.Free;
  end;
end;

procedure THarnessDriverTest.TestAppRemoteTurnRenders;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: ISessionDriver;
  Session: TSessionView;
  Cfg: THarnessSessionConfig;
  Surface: TSurfaceMemory;
  Input: TInputSourceScripted;
  App: THarnessApp;
  Err, Text: string;
  Deadline: Int64;
  I: Integer;
  E: TInputEvent;
  SawBusy, BlankUser, SawDivider: Boolean;
  UserBlocks: Integer;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([TextDelta('remote '), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Driver := RemoteDriver(ClientConfig(Id), Err);
      AssertNotNull('driver connects: ' + Err, Driver);
      try
        { The app's handle: the same session, no loop. }
        Cfg := Config(Fake);
        Cfg.SessionId := Id;
        Session := TSessionView.Open(Cfg, Err);
        AssertTrue('session handle: ' + Err, Session <> nil);
        try
          Surface := TSurfaceMemory.Create(60, 20);
          Input := TInputSourceScripted.Create;
          App := THarnessApp.Create(Surface, Input, Session, Driver);
          try
            App.Step;
            for I := 1 to Length('hi') do
            begin
              E := Default(TInputEvent);
              E.Kind := ikKey;
              E.Key.Kind := kkChar;
              E.Key.Ch := UnicodeString('hi'[I]);
              Input.Push(E);
            end;
            E := Default(TInputEvent);
            E.Kind := ikKey;
            E.Key.Kind := kkEnter;
            Input.Push(E);

            Deadline := GetTickCount64 + 6000;
            SawBusy := False;
            repeat
              App.Step;
              if App.Busy then
                SawBusy := True;
              Sleep(2);
            until (SawBusy and not App.Busy) or (GetTickCount64 >= Deadline);

            Text := App.ConversationText;
            AssertTrue('the streamed answer rendered: ' + Text,
              Pos('remote answer', Text) > 0);

            { Exactly one user block, and never a blank one: a default-mapped
              wire event (loop_started, approval_resolved, ...) must not draw a
              blank user message. }
            UserBlocks := 0;
            BlankUser := False;
            for I := 0 to App.Panel.Stream.Count - 1 do
              if App.Panel.Stream.ItemAt(I).Kind = ckUser then
              begin
                Inc(UserBlocks);
                if App.Panel.Stream.ItemAt(I).Text = '' then
                  BlankUser := True;
              end;
            AssertEquals('exactly one user block', 1, UserBlocks);
            AssertFalse('no blank user block', BlankUser);

            { A successful remote loop ends with its metrics divider. }
            SawDivider := False;
            for I := 0 to App.Panel.Stream.Count - 1 do
              if App.Panel.Stream.ItemAt(I).Kind = ckTurn then
                SawDivider := True;
            AssertTrue('the loop ends with a divider', SawDivider);
          finally
            App.Free;
            Input := nil;
            Surface := nil;
          end;
        finally
          Session.Free;
        end;
      finally
        Driver := nil;
      end;
    finally
      Rt.Stop;
      Th.WaitFor;
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure THarnessDriverTest.TestAppRemoteFailedTurnEndsInErrorWithoutDivider;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: ISessionDriver;
  Session: TSessionView;
  Cfg: THarnessSessionConfig;
  Surface: TSurfaceMemory;
  Input: TInputSourceScripted;
  App: THarnessApp;
  Err: string;
  Deadline: Int64;
  I: Integer;
  E: TInputEvent;
  SawBusy, SawDivider: Boolean;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.FailNetwork := True;
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Driver := RemoteDriver(ClientConfig(Id), Err);
      AssertNotNull('driver connects: ' + Err, Driver);
      try
        Cfg := Config(Fake);
        Cfg.SessionId := Id;
        Session := TSessionView.Open(Cfg, Err);
        AssertTrue('session handle: ' + Err, Session <> nil);
        try
          Surface := TSurfaceMemory.Create(60, 20);
          Input := TInputSourceScripted.Create;
          App := THarnessApp.Create(Surface, Input, Session, Driver);
          try
            App.Step;
            for I := 1 to Length('hi') do
            begin
              E := Default(TInputEvent);
              E.Kind := ikKey;
              E.Key.Kind := kkChar;
              E.Key.Ch := UnicodeString('hi'[I]);
              Input.Push(E);
            end;
            E := Default(TInputEvent);
            E.Kind := ikKey;
            E.Key.Kind := kkEnter;
            Input.Push(E);

            Deadline := GetTickCount64 + 6000;
            SawBusy := False;
            repeat
              App.Step;
              if App.Busy then
                SawBusy := True;
              Sleep(2);
            until (SawBusy and not App.Busy) or (GetTickCount64 >= Deadline);

            { The runtime emits turn_finished after the error too; it must not
              flip the failed turn back to ready, nor end it with a divider. }
            AssertEquals('the failed turn ends in error', 'error',
              App.StateText);
            SawDivider := False;
            for I := 0 to App.Panel.Stream.Count - 1 do
              if App.Panel.Stream.ItemAt(I).Kind = ckTurn then
                SawDivider := True;
            AssertFalse('no divider for a failed remote loop', SawDivider);
          finally
            App.Free;
            Input := nil;
            Surface := nil;
          end;
        finally
          Session.Free;
        end;
      finally
        Driver := nil;
      end;
    finally
      Rt.Stop;
      Th.WaitFor;
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

initialization
  RegisterTest(THarnessDriverTest);

end.
