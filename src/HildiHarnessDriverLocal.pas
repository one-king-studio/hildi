unit HildiHarnessDriverLocal;
{ The in-process driver: runs the loop over a session's queue/gate via
  TTurnWorker, the original pre-headless path. Kept for tests and demos. It
  links the agent, so UI clients use HildiHarnessDriver (the remote
  driver) instead. }

{$mode delphi}{$H+}

interface

uses
  HildiApproval, HildiHarnessTurn,
  HildiHarnessDriver, HildiHarnessSession,
  HildiSession, HildiSkills,
  HildiMCPConfig, HildiMCPClient,
  HildiStore;

{ The in-process driver over a session that has a built loop. }
function LocalDriver(ASession: THarnessSession): ISessionDriver;

implementation

uses
  SysUtils,
  HildiHarnessTurnWorker;

type
  TLocalDriver = class(TInterfacedObject, ISessionDriver)
  private
    FSession: THarnessSession;
    FWorker: TTurnWorker;
    { The turn in flight is a checkpoint turn: on completion the driver records a
      checkpoint from the assistant's reply. }
    FCheckpointTurn: Boolean;
    { One server's connection, read from the manager's live set. }
    function ConnectionOf(const AName: string): TMcpConnection;
    { The stored rows, or False when the session has no store to read them from. }
    function RowsNow(out ARows: TMcpServerRowArray): Boolean;
    { Build rows via the SHARED McpRowOf and push them as one event. AOnly ''
      means every server; AError is attached to the single row when present. }
    procedure PushMcpRows(const ARows: TMcpServerRowArray;
      AKind: TTurnEventKind; const AOnly: string; const AError: string);
  public
    constructor Create(ASession: THarnessSession);
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    procedure AbortSubagent(const ASessionId: string);
    procedure ReleaseSubagent(const ASessionId: string);
    procedure Undo(ATurnId: Int64 = 0);
    { Redo what an undo took away, oldest first. ATurnId 0 means the oldest
      undone turn. }
    procedure Redo(ATurnId: Int64 = 0);
    { The session's skill keys. In-process, so this reads the registry directly
      rather than waiting for an event. }
    procedure SkillKeys(out AKeys: TStringArray);
    { The subset in context. In-process, so this is the registry's derived answer. }
    procedure SkillLoadedKeys(out AKeys: TStringArray);
    { One skill's detail, pushed as an event so the app has one code path for the
      dialog whether the driver is local or remote. }
    procedure SkillDetail(const AKey: string);
    { Load a skill by key. LoadSkillByName records the session approval first, so
      an operator-typed load does not prompt. A refusal is pushed as an error. }
    procedure LoadSkill(const AKey: string);
    { The MCP list, built in-process from the same shared McpRowOf the runtime
      uses, and pushed as an event so the app has ONE code path whether the
      driver is local or remote. }
    procedure McpList;
    { A fresh connection read. In-process there is no round trip to make: the
      provider's live state already IS the probe. }
    procedure McpProbe(const AKey: string);
    { Reopen one dropped transport. Never touches OpenNames, so activation is
      unchanged - reconnecting is not loading. }
    procedure McpReconnect(const AKey: string);
    procedure Checkpoint;
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function Dropped: Int64;
    procedure Close;
  end;

constructor TLocalDriver.Create(ASession: THarnessSession);
begin
  inherited Create;
  FSession := ASession;
end;

procedure TLocalDriver.StartTurn(const AText: string);
var
  E: TTurnEvent;
begin
  { The previous turn's worker has finished (the app only starts a turn when it
    is not busy), but it may still be unwinding after emitting teDone; join and
    free it before replacing it, or it leaks. }
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  { Echo the prompt as the first event, so the app handles it the same way as
    the remote path. }
  E := Default(TTurnEvent);
  E.Kind := teUserMessage;
  E.Text := AText;
  FSession.Queue.Push(E);
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText,
    FSession.TurnPool);
  FWorker.Start;
end;

procedure TLocalDriver.QueuePrompt(const AText: string);
begin
  if FWorker <> nil then
    FWorker.QueuePrompt(AText);
end;

procedure TLocalDriver.Interrupt;
begin
  if FWorker <> nil then
    FWorker.RequestCancel;
  { Release any tool call blocked in the approval gate, so the interrupt is not
    held up until the approval timeout. }
  if FSession <> nil then
    FSession.Gate.Cancel;
end;

procedure TLocalDriver.AnswerAsk(const AAskRef: string;
  const AChoice: TApprovalChoice);
begin
  FSession.Gate.Answer(StrToIntDef(AAskRef, 0), AChoice);
end;

procedure TLocalDriver.AbortSubagent(const ASessionId: string);
begin
  { The in-process local driver has no runtime supervisor; subagents are a
    runtime feature. }
end;

procedure TLocalDriver.ReleaseSubagent(const ASessionId: string);
begin
end;

procedure TLocalDriver.Checkpoint;
var
  E: TTurnEvent;
begin
  { The checkpoint is an ordinary (ambient) turn, exactly as over the wire: the
    summarization instruction is queued as an ambient message and the assistant's
    reply is the document. The checkpoint is recorded when the turn completes
    (see PopEvent). }
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  if FSession.View.Store = nil then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'checkpoint needs a store';
    FSession.Queue.Push(E);
    Exit;
  end;
  FSession.Loop.PromptQueue.PushAmbient(CheckpointInstruction, '',
    'checkpoint', 'checkpoint', 'running', 0);
  FCheckpointTurn := True;
  FWorker := TTurnWorker.CreateAmbient(FSession.Loop, FSession.Queue,
    FSession.TurnPool);
  FWorker.Start;
end;

procedure TLocalDriver.Undo(ATurnId: Int64);
var
  E: TTurnEvent;
  Detail: string;
  Id: Int64;
begin
  { In-process, the session is right here, so this acts directly rather than
    sending a command. Same rules as the runtime handler: refuse a busy turn, and
    surface UndoTurn's refusal reason as an error event so the operator sees WHY
    rather than a silent no-op. }
  if (FWorker <> nil) and (not FWorker.Finished) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: a turn is in progress';
    FSession.Queue.Push(E);
    Exit;
  end;
  Id := ATurnId;
  if Id <= 0 then
  begin
    if FSession.View.LastTurn.Status = tsCompleted then
      Id := FSession.View.LastTurn.Id;
  end;
  if Id <= 0 then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: no completed turn to undo';
    FSession.Queue.Push(E);
    Exit;
  end;
  if not FSession.UndoTurn(Id, Detail) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: ' + Detail;
    FSession.Queue.Push(E);
  end
  else
  begin
    { Tell the app the transcript moved, so it rebuilds the stream and hands the
      prompt back to the composer - the cancel behaviour. The runtime broadcasts
      ekUndone for remote clients; without this the in-process path would undo
      the store and leave the screen unchanged, which is exactly the "undo did
      nothing" the operator reported. }
    E := Default(TTurnEvent);
    E.Kind := teUndone;
    E.ElapsedMs := Id;
    FSession.Queue.Push(E);
  end;
end;

procedure TLocalDriver.Redo(ATurnId: Int64);
var
  E: TTurnEvent;
  Detail: string;
  Id: Int64;
begin
  { The mirror of Undo, with the same two refusals for the same reasons. }
  if (FWorker <> nil) and (not FWorker.Finished) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: a turn is in progress';
    FSession.Queue.Push(E);
    Exit;
  end;
  Id := ATurnId;
  if Id <= 0 then
    { The oldest REDOABLE turn: undone and above the redo floor. Resolved by the
      session so this and the runtime cannot disagree - picking the oldest
      undone turn without the floor would select one a later prompt abandoned. }
    Id := FSession.OldestRedoableTurn;
  if Id <= 0 then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: nothing is undone';
    FSession.Queue.Push(E);
    Exit;
  end;
  if not FSession.RedoTurn(Id, Detail) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: ' + Detail;
    FSession.Queue.Push(E);
  end;
end;

procedure TLocalDriver.SkillKeys(out AKeys: TStringArray);
begin
  AKeys := nil;
  if FSession.Skills <> nil then
    AKeys := FSession.Skills.Keys;
end;

procedure TLocalDriver.SkillDetail(const AKey: string);
var
  E: TTurnEvent;
  S: TSkill;
begin
  { In-process there is no round trip: the registry has the answer now. It is
    still pushed as an event rather than returned, so the app has ONE code path
    for the dialog whether the driver is local or remote. }
  if FSession.Skills <> nil then
  begin
    E := Default(TTurnEvent);
    E.Kind := teSkillDetail;
    S := FSession.Skills.SkillOf(AKey);
    E.SkillDetailKey := S.Key;
    E.SkillName := S.Name;
    E.SkillDescription := S.Description;
    E.SkillLicense := S.License;
    E.SkillCompatibility := S.Compatibility;
    E.SkillAllowedTools := S.AllowedTools;
    E.SkillLocation := S.Location;
    E.SkillResources := S.Resources;
    E.SkillBody := S.Instructions;
    E.SkillIsLoaded := FSession.Skills.StateOf(S.Key) = ssLoaded;
    FSession.Queue.Push(E);
  end;
end;

procedure TLocalDriver.SkillLoadedKeys(out AKeys: TStringArray);
begin
  { In-process, so this asks the registry - which derives the answer from the
    store, so it already reflects a /checkpoint rebuild. }
  AKeys := nil;
  if FSession.Skills <> nil then
    AKeys := FSession.Skills.LoadedKeys;
end;

procedure TLocalDriver.LoadSkill(const AKey: string);
var
  E: TTurnEvent;
  Detail: string;
begin
  { In-process, so this loads directly. LoadSkillByName records the session-scope
    approval first, so an operator-typed load does not prompt - typing the key is
    the consent. }
  Detail := '';
  if not FSession.LoadSkillByName(AKey, Detail) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'skill load refused: ' + Detail;
    FSession.Queue.Push(E);
    Exit;
  end;
  { Tell the app the catalogue moved, so the composer line redraws. }
  E := Default(TTurnEvent);
  E.Kind := teSkills;
  E.SkillKeys := FSession.Skills.Keys;
  E.SkillLoadedKeys := FSession.Skills.LoadedKeys;
  FSession.Queue.Push(E);
end;

function TLocalDriver.ConnectionOf(const AName: string): TMcpConnection;
var
  State: TMcpServerState;
begin
  { Not knowing a server is UNKNOWN, never disconnected: "we do not hold it" is a
    different claim from "its transport is down", and a list must not invent the
    stronger one. }
  if FSession.McpProvider = nil then
    Exit(mcUnknown);
  if not FSession.McpProvider.TransportStateOf(AName, State) then
    Exit(mcUnknown);
  if State = mssConnected then
    Result := mcConnected
  else
    Result := mcDisconnected;
end;

function TLocalDriver.RowsNow(out ARows: TMcpServerRowArray): Boolean;
var
  Err: TStoreError;
begin
  ARows := nil;
  Result := False;
  if (FSession.View = nil) or (FSession.View.Store = nil) then
    Exit;
  Result := FSession.View.Store.ListMcpServers(ARows, Err);
end;

procedure TLocalDriver.PushMcpRows(const ARows: TMcpServerRowArray;
  AKind: TTurnEventKind; const AOnly: string; const AError: string);
var
  E: TTurnEvent;
  Live: TStringArray;
  I, N: Integer;

  procedure AddOne(const ARow: TMcpServerRow);
  begin
    SetLength(E.McpRows, N + 1);
    E.McpRows[N] := McpRowOf(ARow, Live, ConnectionOf(ARow.Name));
    Inc(N);
  end;

begin
  Live := nil;
  if FSession.McpProvider <> nil then
    Live := FSession.McpProvider.OpenNames;
  E := Default(TTurnEvent);
  E.Kind := AKind;
  N := 0;
  if AOnly = '' then
  begin
    for I := 0 to High(ARows) do
      AddOne(ARows[I]);
  end
  else
    for I := 0 to High(ARows) do
      if SameText(ARows[I].Name, AOnly) then
      begin
        AddOne(ARows[I]);
        Break;
      end;
  if (AError <> '') and (N > 0) then
    E.McpRows[N - 1].Error := AError;
  FSession.Queue.Push(E);
end;

procedure TLocalDriver.McpList;
var
  Rows: TMcpServerRowArray;
begin
  if not RowsNow(Rows) then
  begin
    { No store means no servers to list. Say nothing rather than a misleading
      empty list the dialog would render as "you have none". }
    Exit;
  end;
  { mcUnknown for every row: nobody has probed, so no row may claim an answer. }
  PushMcpRows(Rows, teMcpList, '', '');
end;

procedure TLocalDriver.McpProbe(const AKey: string);
var
  Rows: TMcpServerRowArray;
begin
  if not RowsNow(Rows) then
    Exit;
  PushMcpRows(Rows, teMcpProbeResult, AKey, '');
end;

procedure TLocalDriver.McpReconnect(const AKey: string);
var
  Rows: TMcpServerRowArray;
  Err: string;
  I, Found: Integer;
begin
  if not RowsNow(Rows) then
    Exit;
  Found := -1;
  for I := 0 to High(Rows) do
    if SameText(Rows[I].Name, AKey) then
    begin
      Found := I;
      Break;
    end;
  Err := '';
  if Found < 0 then
    Err := 'unknown mcp server: ' + AKey
  else if not Rows[Found].Enabled then
    { Enabling is a config change, not a reconnect. Refuse rather than quietly
      opening a server the operator turned off. }
    Err := 'not enabled'
  else if FSession.McpProvider = nil then
    Err := 'no mcp provider'
  else
    FSession.McpProvider.Reconnect(AKey, Err);
  PushMcpRows(Rows, teMcpReconnectDone, AKey, Err);
end;

function TLocalDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
var
  Seq: Int64;
  StoreErr: TStoreError;
  E: TTurnEvent;
begin
  Result := FSession.Queue.Pop(AEvent);
  if not Result then
    Exit;
  { Normalise onto the remote vocabulary: a queued prompt is a user message,
    and an approval ask carries its reference. }
  if AEvent.Kind = tePromptQueued then
    AEvent.Kind := teUserMessage;
  if AEvent.Kind = teApprovalAsk then
    AEvent.AskRef := IntToStr(AEvent.RequestId);
  { A completed checkpoint turn: record the checkpoint at the boundary from the
    assistant's reply, then surface it. }
  if FCheckpointTurn and (AEvent.Kind in [teDone, teError]) then
  begin
    FCheckpointTurn := False;
    if (AEvent.Kind = teDone) and (FSession.View.Store <> nil) and
      FSession.View.Store.SaveCheckpoint(FSession.View.SessionId, AEvent.Answer,
        Seq, StoreErr) then
    begin
      E := Default(TTurnEvent);
      E.Kind := teCheckpointCommitted;
      E.ElapsedMs := Seq;
      FSession.Queue.Push(E);
    end;
  end;
end;

function TLocalDriver.Dropped: Int64;
begin
  Result := FSession.Queue.Dropped;
end;

procedure TLocalDriver.Close;
begin
  if FSession = nil then
    Exit;
  FSession.Gate.Cancel;
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
end;

function LocalDriver(ASession: THarnessSession): ISessionDriver;
begin
  Result := TLocalDriver.Create(ASession);
end;

end.
