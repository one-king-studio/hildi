unit hildegard.helper.subagent.supervisor;
{ The runtime-side subagent supervisor.

  The parent session's runtime owns one supervisor. It spawns a child session
  per delegated task (a new session row with lineage, plus a child runtime
  reached over the session client), drives the child as its sole driver, and
  surfaces the child's events to the runtime loop through a thread-safe queue.

  Threading: each child's reader thread pushes events into the supervisor's
  queue under a lock; the runtime loop drains it with Poll on the runtime
  thread, exactly as it drains the turn queue. No callback mutates runtime state
  off the runtime thread.

  The client is created through an injectable factory (TSubagentClientFactory)
  so tests can attach to an in-process child runtime instead of spawning a
  process; the default factory spawns a real one. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, SyncObjs,
  hildegard.helper.session, hildegard.helper.session.protocol,
  hildegard.helper.session.client, hildegard.helper.store,
  hildegard.helper.approval, hildegard.helper.subagent;

type
  TSubagentEventKind = (
    sekSpawned,        // the child's runtime is up
    sekResult,         // the child's turn finished; Result holds its final text
    sekAborted,        // the child was aborted (operator or parent)
    sekApprovalAsk,    // the child is blocked on an approval ask
    sekGone            // the child's runtime exited / detached
  );

  TSubagentEvent = record
    Kind: TSubagentEventKind;
    SessionId: string;
    LabelText: string;
    Result: string;    // sekResult: the child's final assistant text
    ElapsedMs: Int64;  // sekResult: the task duration
    Status: string;    // sekResult: completed/failed; sekGone: gone; sekAborted: aborted
    AskId: string;     // sekApprovalAsk: the child's ask id
    Ask: TApprovalAsk; // sekApprovalAsk
    Error: string;     // sekGone
  end;

  TSubagentSupervisorConfig = record
    WorkspacePath: string;
    StorePath: string;
    RuntimeCommand: string;    // the child runtime binary ('' => sibling)
    ParentSessionId: string;
    ParentWorkspaceId: Integer;
    ParentDepth: Integer;      // the parent's own depth (children are +1)
    { The lineage root the child's approvals resolve against (the parent's own
      approval root). '' => ParentSessionId. }
    ParentApprovalRoot: string;
    MaxChildren: Integer;      // 0 => DefaultMaxChildren
    MaxDepth: Integer;         // 0 => DefaultMaxDepth
    IdleExitMs: Integer;       // 0 => the client default
    AutoDenyMs: Int64;         // 0 => DefaultAutoDenyMs
  end;

  { The injectable client seam. Default: TSessionClient.Open (spawns). }
  TSubagentClientFactory = function(const AConfig: TSessionClientConfig;
    const ASink: ISessionSink; out AError: string): TSessionClient of object;

  TSubagentSupervisor = class;

  { One child's sink: tags every event with its child so the supervisor's shared
    queue can tell them apart. }
  TChildSink = class(TInterfacedObject, ISessionSink)
  private
    FOwner: TSubagentSupervisor;
    FSessionId: string;
  public
    constructor Create(AOwner: TSubagentSupervisor; const ASessionId: string);
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TChild = class
  public
    SessionId: string;
    LabelText: string;
    Client: TSessionClient;
    Sink: TChildSink;
    SinkRef: ISessionSink;
    Status: string;          // 'spawned'|'running'|'completed'|'failed'|'gone'
    LastAssistant: string;
    StartedMs: Int64;
    PendingAskId: string;
    PendingDeadline: Int64;
    Active: Boolean;         // still holds a slot
    destructor Destroy; override;
  end;

  TSubagentSupervisor = class(TInterfacedObject, ISubagentService)
  private
    FConfig: TSubagentSupervisorConfig;
    FStore: TSqliteStore;      // borrowed; the runtime owns it
    FFactory: TSubagentClientFactory;
    FLock: TCriticalSection;
    FListLock: TCriticalSection;
    FGraveyard: TObjectList;
    FEvents: array of TSubagentEvent;
    FChildren: TObjectList;
    FHasClient: Boolean;
    function Find(const ASessionId: string): TChild;
    function ActiveCount: Integer;
    function FreeSlots: Integer;
    function LastAssistantText(const ASessionId: string): string;
    procedure Push(const AEvent: TSubagentEvent);
    procedure HandleChildEvent(const ASessionId: string;
      const AEvent: TSessionEvent);
    procedure HandleDetached(const ASessionId, AReason: string);
    procedure RemoveChild(const ASessionId: string; AActive: Boolean);
    function MakeClientConfig(const ASessionId: string;
      out AError: string): TSessionClientConfig;
    function GetCanDelegate: Boolean;
    procedure DeferReap(AChild: TChild);
    procedure ReapPending;
    function DefaultFactory(const AConfig: TSessionClientConfig;
      const ASink: ISessionSink; out AError: string): TSessionClient;
  public
    constructor Create(const AConfig: TSubagentSupervisorConfig;
      AStore: TSqliteStore);
    destructor Destroy; override;

    { Drain one queued child event (non-blocking). }
    function Poll(out AEvent: TSubagentEvent): Boolean;

    { ISubagentService. }
    function Delegate(const ATask, AContext, ALabel, ATitle: string;
      out AResult: TSubagentSpawnResult): Boolean;
    function Message(const ASessionId, AText: string;
      out AError: string): Boolean;
    function Abort(const ASessionId: string; out AError: string): Boolean;
    function Release(const ASessionId: string; out AError: string): Boolean;
    function Status(const ASessionId: string): string;

    { Relay the operator's decision for a child ask down to the child. }
    procedure AnswerChildAsk(const ASessionId, AAskId: string;
      const AChoice: TApprovalChoice);

    { Auto-deny expired child asks when no interactive client is attached. }
    procedure TickAutoDeny(ANowMs: Int64);

    { Terminate every supervised child (bounded). Called on parent shutdown. }
    procedure TerminateAll;

    property Available: Integer read FreeSlots;
    property Max: Integer read FConfig.MaxChildren;
    { True when this session is below the depth cap, so it may spawn children
      (and should advertise the delegation tools). }
    property CanDelegate: Boolean read GetCanDelegate;
    property HasClient: Boolean read FHasClient write FHasClient;
    { Test seam: replace the client factory. }
    property Factory: TSubagentClientFactory read FFactory write FFactory;
  end;

const
  DefaultMaxChildren = 10;
  DefaultMaxDepth = 1;
  DefaultAutoDenyMs = 60000;

implementation

function MakeEvent(AKind: TSubagentEventKind; const AId, ALabel, AResult: string;
  AElapsed: Int64): TSubagentEvent; forward;

{ --- TChildSink --------------------------------------------------------- }

constructor TChildSink.Create(AOwner: TSubagentSupervisor;
  const ASessionId: string);
begin
  inherited Create;
  FOwner := AOwner;
  FSessionId := ASessionId;
end;

procedure TChildSink.OnHello(const AHello: TSessionHello);
begin
end;

procedure TChildSink.OnAttached(const AAttached: TSessionAttached);
begin
end;

procedure TChildSink.OnEvent(const AEvent: TSessionEvent);
begin
  FOwner.HandleChildEvent(FSessionId, AEvent);
end;

procedure TChildSink.OnDetached(const AReason: string);
begin
  FOwner.HandleDetached(FSessionId, AReason);
end;

procedure TChildSink.OnError(const ACode, AMessage: string);
begin
  FOwner.HandleDetached(FSessionId, AMessage);
end;

{ --- TChild ------------------------------------------------------------- }

destructor TChild.Destroy;
begin
  SinkRef := nil;
  Sink := nil;
  Client.Free;
  inherited Destroy;
end;

{ --- TSubagentSupervisor ------------------------------------------------ }

constructor TSubagentSupervisor.Create(const AConfig: TSubagentSupervisorConfig;
  AStore: TSqliteStore);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.MaxChildren <= 0 then
    FConfig.MaxChildren := DefaultMaxChildren;
  if FConfig.MaxDepth <= 0 then
    FConfig.MaxDepth := DefaultMaxDepth;
  if FConfig.AutoDenyMs <= 0 then
    FConfig.AutoDenyMs := DefaultAutoDenyMs;
  FStore := AStore;
  FLock := TCriticalSection.Create;
  FListLock := TCriticalSection.Create;
  FChildren := TObjectList.Create(False);   // non-owning: we free explicitly
  FGraveyard := TObjectList.Create(False);  // (an owning list's Delete would
                                            //  free on unlink and double-free)
  FHasClient := False;
  FFactory := DefaultFactory;
end;

destructor TSubagentSupervisor.Destroy;
var
  I: Integer;
begin
  TerminateAll;
  ReapPending;
  { Any child still parked (its reader never exited) is freed here. }
  for I := 0 to FGraveyard.Count - 1 do
    TChild(FGraveyard[I]).Free;
  for I := 0 to FChildren.Count - 1 do
    TChild(FChildren[I]).Free;
  FGraveyard.Free;
  FChildren.Free;
  FListLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSubagentSupervisor.DefaultFactory(const AConfig: TSessionClientConfig;
  const ASink: ISessionSink; out AError: string): TSessionClient;
begin
  Result := TSessionClient.Open(AConfig, ASink, AError);
end;

function TSubagentSupervisor.Find(const ASessionId: string): TChild;
var
  I: Integer;
begin
  Result := nil;
  FListLock.Acquire;
  try
    for I := 0 to FChildren.Count - 1 do
      if TChild(FChildren[I]).SessionId = ASessionId then
      begin
        Result := TChild(FChildren[I]);
        Exit;
      end;
  finally
    FListLock.Release;
  end;
end;

function TSubagentSupervisor.ActiveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  FListLock.Acquire;
  try
    for I := 0 to FChildren.Count - 1 do
      if TChild(FChildren[I]).Active then
        Inc(Result);
  finally
    FListLock.Release;
  end;
end;

function TSubagentSupervisor.FreeSlots: Integer;
begin
  Result := FConfig.MaxChildren - ActiveCount;
  if Result < 0 then
    Result := 0;
end;

function TSubagentSupervisor.GetCanDelegate: Boolean;
begin
  Result := FConfig.ParentDepth + 1 <= FConfig.MaxDepth;
end;

{ The child's final assistant text, read from the durable store (the runtime
  does not stream block text for a completed turn). }
function TSubagentSupervisor.LastAssistantText(
  const ASessionId: string): string;
var
  Recs: TMessageRecordArray;
  Err: TStoreError;
  I: Integer;
begin
  Result := '';
  if (FStore = nil) or not FStore.QueryMessages(ASessionId, Recs, Err) then
    Exit;
  for I := High(Recs) downto 0 do
    if (Recs[I].Role = mrAssistant) and (Recs[I].Content <> '') then
      Exit(Recs[I].Content);
end;

procedure TSubagentSupervisor.Push(const AEvent: TSubagentEvent);
begin
  FLock.Acquire;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := AEvent;
  finally
    FLock.Release;
  end;
end;

procedure TSubagentSupervisor.DeferReap(AChild: TChild);
begin
  FListLock.Acquire;
  try
    FGraveyard.Add(AChild);
  finally
    FListLock.Release;
  end;
end;

{ Close and free children whose reader threads have finished. Called from the
  runtime loop (Poll), never from a reader callback, so a child's client is
  never closed from its own reader thread (which would self-join). }
procedure TSubagentSupervisor.ReapPending;
var
  I: Integer;
  Child: TChild;
  Ready: TObjectList;
begin
  Ready := TObjectList.Create(False);   // non-owning; we move items out
  try
    FListLock.Acquire;
    try
      for I := FGraveyard.Count - 1 downto 0 do
      begin
        Child := TChild(FGraveyard[I]);
        if Child.Client.ReaderDone then
        begin
          FGraveyard.Delete(I);
          Ready.Add(Child);
        end;
      end;
    finally
      FListLock.Release;
    end;
    for I := 0 to Ready.Count - 1 do
    begin
      Child := TChild(Ready[I]);
      Child.Client.Close;
      Child.Free;
    end;
  finally
    Ready.Free;
  end;
end;

function TSubagentSupervisor.Poll(out AEvent: TSubagentEvent): Boolean;
begin
  ReapPending;
  FLock.Acquire;
  try
    Result := Length(FEvents) > 0;
    if Result then
    begin
      AEvent := FEvents[0];
      FEvents := Copy(FEvents, 1, Length(FEvents) - 1);
    end;
  finally
    FLock.Release;
  end;
end;

function TSubagentSupervisor.MakeClientConfig(const ASessionId: string;
  out AError: string): TSessionClientConfig;
begin
  Result := Default(TSessionClientConfig);
  Result.SessionId := ASessionId;
  Result.WorkspacePath := FConfig.WorkspacePath;
  Result.StorePath := FConfig.StorePath;
  Result.Role := srDrive;
  Result.FromSeq := 0;
  Result.Spawn := True;
  Result.RuntimeCommand := FConfig.RuntimeCommand;
  Result.IdleExitMs := FConfig.IdleExitMs;
  { The child resolves approvals against the parent's lineage root, so a grant
    is in force across the whole lineage. }
  if FConfig.ParentApprovalRoot <> '' then
    Result.ApprovalRootSessionId := FConfig.ParentApprovalRoot
  else
    Result.ApprovalRootSessionId := FConfig.ParentSessionId;
  AError := '';
end;

function TSubagentSupervisor.Delegate(const ATask, AContext, ALabel, ATitle: string;
  out AResult: TSubagentSpawnResult): Boolean;
var
  ChildId, Err: string;
  Child: TChild;
  Cfg: TSessionClientConfig;
  Client: TSessionClient;
  Sink: TChildSink;
  SinkRef: ISessionSink;
  Cmd: TSessionCommand;
  Prompt: string;
  StoreErr: TStoreError;
begin
  AResult := Default(TSubagentSpawnResult);
  AResult.Max := FConfig.MaxChildren;
  AResult.Available := FreeSlots;
  Result := False;

  { Depth cap: a child at the cap must not delegate. }
  if FConfig.ParentDepth + 1 > FConfig.MaxDepth then
  begin
    AResult.Error := 'subagent depth limit reached';
    Exit;
  end;
  { Capacity cap: fail cleanly so the parent can release or abort. }
  if ActiveCount >= FConfig.MaxChildren then
  begin
    AResult.Error := Format('no subagent capacity: %d of %d in use',
      [ActiveCount, FConfig.MaxChildren]);
    Exit;
  end;

  { A child session is an ordinary session with lineage. }
  if FStore = nil then
  begin
    AResult.Error := 'no store configured';
    Exit;
  end;
  if not FStore.CreateChildSession(FConfig.ParentWorkspaceId,
    FConfig.ParentSessionId, FConfig.ParentDepth + 1, ALabel, ChildId,
    StoreErr) then
  begin
    AResult.Error := 'could not create subagent session: ' + StoreErr.Message;
    Exit;
  end;

  { The delegation REASON becomes the child's title. Delegation always carries a
    reason, and it is the only thing that says what the task is for - without it
    the child shows up as an untitled session and the list is unnavigable.
    `label` stays as the short handle; the title is the sentence. Best-effort:
    a title that fails to write must not fail the spawn. }
  if Trim(ATitle) <> '' then
    FStore.SetSessionTitle(ChildId, ATitle, StoreErr);

  Cfg := MakeClientConfig(ChildId, Err);
  Sink := TChildSink.Create(Self, ChildId);
  SinkRef := Sink;
  Client := FFactory(Cfg, SinkRef, Err);
  if Client = nil then
  begin
    SinkRef := nil;
    AResult.Error := 'could not start subagent runtime: ' + Err;
    Exit;
  end;

  Child := TChild.Create;
  Child.SessionId := ChildId;
  Child.LabelText := ALabel;
  Child.Client := Client;
  Child.Sink := Sink;
  Child.SinkRef := SinkRef;
  Child.Status := 'spawned';
  Child.StartedMs := GetTickCount64;
  Child.Active := True;
  FChildren.Add(Child);

  { The parent supplies the context; the child has none of the conversation. }
  Prompt := 'Context from the delegating agent:' + LineEnding + AContext +
    LineEnding + LineEnding + 'Your task:' + LineEnding + ATask;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scPrompt;
  Cmd.Id := 'd' + ChildId;
  Cmd.Text := Prompt;
  Client.Send(Cmd);

  Push(MakeEvent(sekSpawned, ChildId, ALabel, '', 0));

  AResult.Ok := True;
  AResult.SessionId := ChildId;
  AResult.LabelText := ALabel;
  AResult.Available := FreeSlots;
  Result := True;
end;

function MakeEvent(AKind: TSubagentEventKind; const AId, ALabel, AResult: string;
  AElapsed: Int64): TSubagentEvent;
begin
  Result := Default(TSubagentEvent);
  Result.Kind := AKind;
  Result.SessionId := AId;
  Result.LabelText := ALabel;
  Result.Result := AResult;
  Result.ElapsedMs := AElapsed;
end;

function TSubagentSupervisor.Message(const ASessionId, AText: string;
  out AError: string): Boolean;
var
  Child: TChild;
  Cmd: TSessionCommand;
begin
  AError := '';
  Child := Find(ASessionId);
  if (Child = nil) or not Child.Active then
  begin
    AError := 'unknown or released subagent: ' + ASessionId;
    Exit(False);
  end;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scPrompt;
  Cmd.Id := 'm' + ASessionId;
  Cmd.Text := AText;
  if not Child.Client.Send(Cmd) then
  begin
    AError := 'could not reach subagent: ' + ASessionId;
    Exit(False);
  end;
  Result := True;
end;

function TSubagentSupervisor.Abort(const ASessionId: string;
  out AError: string): Boolean;
var
  Child: TChild;
  Cmd: TSessionCommand;
begin
  AError := '';
  Child := Find(ASessionId);
  if Child = nil then
  begin
    AError := 'unknown subagent: ' + ASessionId;
    Exit(False);
  end;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scInterrupt;
  Cmd.Id := 'a' + ASessionId;
  Child.Client.Send(Cmd);
  Push(MakeEvent(sekAborted, ASessionId, Child.LabelText, '', 0));
  FEvents[High(FEvents)].Status := 'aborted';
  RemoveChild(ASessionId, True);
  Result := True;
end;

function TSubagentSupervisor.Release(const ASessionId: string;
  out AError: string): Boolean;
begin
  AError := '';
  if Find(ASessionId) = nil then
  begin
    AError := 'unknown subagent: ' + ASessionId;
    Exit(False);
  end;
  { Detach without aborting: the child keeps running, its slot is freed, and it
    is no longer tracked (fire-and-forget). }
  RemoveChild(ASessionId, True);
  Result := True;
end;

function TSubagentSupervisor.Status(const ASessionId: string): string;
var
  Child: TChild;
begin
  Child := Find(ASessionId);
  if Child = nil then
    Result := 'gone'
  else
    Result := Child.Status;
end;

procedure TSubagentSupervisor.AnswerChildAsk(const ASessionId, AAskId: string;
  const AChoice: TApprovalChoice);
var
  Child: TChild;
  Cmd: TSessionCommand;
begin
  Child := Find(ASessionId);
  if Child = nil then
    Exit;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scApprove;
  Cmd.Id := 'p' + ASessionId;
  Cmd.AskId := AAskId;
  Cmd.Choice := AChoice;
  Child.Client.Send(Cmd);
  Child.PendingAskId := '';
  Child.PendingDeadline := 0;
end;

procedure TSubagentSupervisor.TickAutoDeny(ANowMs: Int64);
var
  I: Integer;
  Child: TChild;
  Deny: TApprovalChoice;
begin
  if FHasClient then
    Exit;   // an interactive operator is present; let them decide
  for I := 0 to FChildren.Count - 1 do
  begin
    Child := TChild(FChildren[I]);
    if (Child.PendingAskId <> '') and (Child.PendingDeadline > 0) and
      (ANowMs >= Child.PendingDeadline) then
    begin
      Deny := Default(TApprovalChoice);   // denied
      AnswerChildAsk(Child.SessionId, Child.PendingAskId, Deny);
      Child.Status := 'running';
    end;
  end;
end;

procedure TSubagentSupervisor.HandleChildEvent(const ASessionId: string;
  const AEvent: TSessionEvent);
var
  Child: TChild;
  E: TSubagentEvent;
begin
  Child := Find(ASessionId);
  if Child = nil then
    Exit;
  case AEvent.Kind of
    ekAssistantBlock:
      begin
        Child.LastAssistant := AEvent.Text;
        Child.Status := 'running';
      end;
    ekTurnFinished:
      begin
        Child.Status := 'completed';
        Child.LastAssistant := LastAssistantText(ASessionId);
        E := MakeEvent(sekResult, ASessionId, Child.LabelText,
          Child.LastAssistant, AEvent.ElapsedMs);
        E.Status := 'completed';
        Push(E);
        Child.Active := False;   // the slot frees; the child may be reused
      end;
    ekApprovalRequest:
      begin
        Child.PendingAskId := AEvent.AskId;
        Child.PendingDeadline := GetTickCount64 + FConfig.AutoDenyMs;
        E := Default(TSubagentEvent);
        E.Kind := sekApprovalAsk;
        E.SessionId := ASessionId;
        E.LabelText := Child.LabelText;
        E.AskId := AEvent.AskId;
        E.Ask := AEvent.Ask;
        Push(E);
      end;
    ekError:
      begin
        Child.Status := 'failed';
        Child.LastAssistant := LastAssistantText(ASessionId);
        E := MakeEvent(sekResult, ASessionId, Child.LabelText,
          Child.LastAssistant, AEvent.ElapsedMs);
        E.Status := 'failed';
        Push(E);
        Child.Active := False;
      end;
  else
    ;   // other events are not surfaced to the parent
  end;
end;

procedure TSubagentSupervisor.HandleDetached(const ASessionId,
  AReason: string);
var
  Child: TChild;
  E: TSubagentEvent;
begin
  Child := Find(ASessionId);
  if Child = nil then
    Exit;
  Child.Status := 'gone';
  E := MakeEvent(sekGone, ASessionId, Child.LabelText, '', 0);
  E.Status := 'gone';
  Push(E);
  RemoveChild(ASessionId, True);
end;

procedure TSubagentSupervisor.RemoveChild(const ASessionId: string;
  AActive: Boolean);
var
  I: Integer;
  Child: TChild;
begin
  Child := nil;
  FListLock.Acquire;
  try
    for I := FChildren.Count - 1 downto 0 do
      if TChild(FChildren[I]).SessionId = ASessionId then
      begin
        Child := TChild(FChildren[I]);
        FChildren.Delete(I);
        Break;
      end;
  finally
    FListLock.Release;
  end;
  { Never close the client here: this runs on the runtime thread (abort/release)
    or on a reader thread (OnDetached). Closing from the reader thread would
    self-join. Unlist, then defer close/free to ReapPending. }
  if Child <> nil then
  begin
    if AActive then
      Child.Active := False;
    DeferReap(Child);
  end;
end;

procedure TSubagentSupervisor.TerminateAll;
var
  I: Integer;
  Child: TChild;
begin
  FListLock.Acquire;
  try
    for I := 0 to FChildren.Count - 1 do
    begin
      Child := TChild(FChildren[I]);
      Child.Active := False;
      FGraveyard.Add(Child);
    end;
    FChildren.Clear;
  finally
    FListLock.Release;
  end;
end;

end.
