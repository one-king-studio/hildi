unit hildi.subagent;
{ The delegation tool family: delegate_task, message_task, abort_task, and
  release_task. Each is an ordinary tool the parent loop advertises; each
  resolves its own approval ask through the shared engine (ref
  `subagent:<verb>`, tool-level in v1) exactly as run_command and the file tools
  do, and then calls an injected ISubagentService.

  The tools own no state beyond the service handle: the runtime-side supervisor
  (hildi.subagent.supervisor) implements ISubagentService. Splitting
  the two keeps this unit free of sockets, threads, and the store, so the tool
  contract is unit-testable with a fake service. }

{$mode delphi}{$H+}

interface

uses
  hildi.agent, hildi.llm, hildi.approval;

const
  SubagentDelegateTool = 'delegate_task';
  SubagentMessageTool  = 'message_task';
  SubagentAbortTool    = 'abort_task';
  SubagentReleaseTool  = 'release_task';

  { Subagent defaults, overridable via env. }
  DefaultSubagentMax = 10;
  DefaultSubagentDepth = 1;
  DefaultSubagentAutoDenyMs = 60000;

{ Resolve a subagent knob from its raw env value ('' => default; an invalid or
  out-of-range value falls back to the default). Pure, so it is unit-testable. }
function ResolveSubagentMax(const ARaw: string): Integer;
function ResolveSubagentDepth(const ARaw: string): Integer;
function ResolveSubagentAutoDenyMs(const ARaw: string): Int64;

type
  TSubagentVerb = (svDelegate, svMessage, svAbort, svRelease);

  { The outcome of a delegate call. Available/Max are the parent's capacity
    after the call, so the model can manage its delegation budget. }
  TSubagentSpawnResult = record
    Ok: Boolean;
    SessionId: string;
    LabelText: string;
    Error: string;
    Available: Integer;
    Max: Integer;
  end;

  { What the delegation tools may do. Implemented by the runtime-side
    supervisor; the tools never touch sockets or the store directly. }
  ISubagentService = interface
    { Spawn a child for a task. Non-blocking: returns once the child session
      exists and its runtime is spawned; its first turn runs asynchronously. }
    function Delegate(const ATask, AContext, ALabel, ATitle: string;
      out AResult: TSubagentSpawnResult): Boolean;
    { Send a follow-up message to an existing child by session id. }
    function Message(const ASessionId, AText: string;
      out AError: string): Boolean;
    { Abort a child and release its slot. }
    function Abort(const ASessionId: string; out AError: string): Boolean;
    { Detach from a child without aborting it; free its slot. }
    function Release(const ASessionId: string; out AError: string): Boolean;
    { The child's current status, for a tool acknowledgement. }
    function Status(const ASessionId: string): string;
  end;

  { One delegation tool. A single class parameterised by verb, so the four
    share their parsing, approval, and error handling. }
  TSubagentTool = class(TInterfacedObject, IApprovableTool)
  private
    FVerb: TSubagentVerb;
    FService: ISubagentService;
    FApproval: IApprovalService;
    function Approve(const ARef, ASummary, AReason: string;
      out AError: string): Boolean;
  public
    constructor Create(AVerb: TSubagentVerb; AService: ISubagentService;
      AApproval: IApprovalService);
    { Registers this verb's tool with the registry. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; registered by Register. Public for direct testing. }
    function Run(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ApprovalAsks(const AArgumentsJson: string): TApprovalAskArray;
  end;

  { Owns the four tool instances (the registry stores "of object" handlers that
    must outlive it) and registers them in one call. }
  TSubagentToolSet = class
  private
    FTools: array[TSubagentVerb] of TSubagentTool;
  public
    constructor Create(AService: ISubagentService;
      AApproval: IApprovalService);
    destructor Destroy; override;
    procedure Register(ATools: TToolRegistry);
  end;

function SubagentVerbName(AVerb: TSubagentVerb): string;
function SubagentApprovalRef(AVerb: TSubagentVerb): string;

implementation

uses
  SysUtils, fpjson, jsonparser;

function SubagentVerbName(AVerb: TSubagentVerb): string;
begin
  case AVerb of
    svDelegate: Result := SubagentDelegateTool;
    svMessage:  Result := SubagentMessageTool;
    svAbort:    Result := SubagentAbortTool;
    svRelease:  Result := SubagentReleaseTool;
  end;
end;

function ResolveSubagentMax(const ARaw: string): Integer;
begin
  if ARaw = '' then
    Exit(DefaultSubagentMax);
  Result := StrToIntDef(ARaw, DefaultSubagentMax);
  if Result < 1 then
    Result := DefaultSubagentMax;
end;

function ResolveSubagentDepth(const ARaw: string): Integer;
begin
  if ARaw = '' then
    Exit(DefaultSubagentDepth);
  Result := StrToIntDef(ARaw, DefaultSubagentDepth);
  if Result < 0 then
    Result := DefaultSubagentDepth;
end;

function ResolveSubagentAutoDenyMs(const ARaw: string): Int64;
begin
  if ARaw = '' then
    Exit(DefaultSubagentAutoDenyMs);
  Result := StrToInt64Def(ARaw, DefaultSubagentAutoDenyMs);
  if Result < 0 then
    Result := DefaultSubagentAutoDenyMs;
end;

function SubagentApprovalRef(AVerb: TSubagentVerb): string;
begin
  Result := 'subagent:' + SubagentVerbName(AVerb);
end;

{ --- helpers ------------------------------------------------------------ }

function ReadStringArg(ARoot: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  D: TJSONData;
begin
  D := ARoot.Find(AName);
  Result := (D <> nil) and (D.JSONType = jtString);
  if Result then
    AValue := D.AsString
  else
    AValue := '';
end;

function ParseRoot(const AArgumentsJson: string; out AData: TJSONData;
  out ARoot: TJSONObject): Boolean;
begin
  AData := nil;
  ARoot := nil;
  try
    AData := GetJSON(AArgumentsJson);
  except
    Exit(False);
  end;
  if not (AData is TJSONObject) then
  begin
    AData.Free;
    AData := nil;
    Exit(False);
  end;
  ARoot := TJSONObject(AData);
  Result := True;
end;

{ Adds the standard allow options (once / exact / any) to an ask. }
procedure AddAllowOptions(var AAsk: TApprovalAsk; const ARef: string);
var
  Opt: TApprovalOption;

  procedure Add(const AKey, ACaption: string; APersists, AAny: Boolean);
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := APersists;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := ARef;
    Opt.Rule.AnyParams := AAny;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
  end;

begin
  Add('once', 'allow once', False, False);
  Add('exact', 'always this operation', True, False);
  Add('any', 'always ' + ARef, True, True);
end;

function ToolSpecFor(AVerb: TSubagentVerb): TToolSpec;
begin
  Result := Default(TToolSpec);
  Result.Name := SubagentVerbName(AVerb);
  case AVerb of
    svDelegate:
      begin
        Result.Description :=
          'Delegate a task to a subagent that runs in its own session. Returns ' +
          'immediately with the subagent session id and your remaining ' +
          'capacity; you are notified when it finishes.';
        Result.ParametersJson :=
          '{"type":"object","properties":{' +
          '"task":{"type":"string","description":"The instruction for the subagent."},' +
          '"context":{"type":"string","description":"Context the subagent needs; it cannot see this conversation."},' +
          '"label":{"type":"string","description":"Short human label for this task."},' +
          '"reason":{"type":"string","description":"Short reason this delegation is needed."}' +
          '},"required":["task","context","label","reason"]}';
      end;
    svMessage:
      begin
        Result.Description :=
          'Send a follow-up message to a subagent by its session id.';
        Result.ParametersJson :=
          '{"type":"object","properties":{' +
          '"session_id":{"type":"string","description":"The subagent session id."},' +
          '"message":{"type":"string","description":"The follow-up message."},' +
          '"reason":{"type":"string","description":"Short reason this follow-up is needed."}' +
          '},"required":["session_id","message","reason"]}';
      end;
    svAbort:
      begin
        Result.Description :=
          'Abort a subagent by its session id, stopping its work and freeing ' +
          'your capacity.';
        Result.ParametersJson :=
          '{"type":"object","properties":{' +
          '"session_id":{"type":"string","description":"The subagent session id."},' +
          '"reason":{"type":"string","description":"Short reason this abort is needed."}' +
          '},"required":["session_id","reason"]}';
      end;
    svRelease:
      begin
        Result.Description :=
          'Detach from a subagent without aborting it (fire-and-forget), ' +
          'freeing your capacity while it keeps running.';
        Result.ParametersJson :=
          '{"type":"object","properties":{' +
          '"session_id":{"type":"string","description":"The subagent session id."},' +
          '"reason":{"type":"string","description":"Short reason this release is needed."}' +
          '},"required":["session_id","reason"]}';
      end;
  end;
end;

{ --- TSubagentTool ------------------------------------------------------ }

constructor TSubagentTool.Create(AVerb: TSubagentVerb;
  AService: ISubagentService; AApproval: IApprovalService);
begin
  inherited Create;
  FVerb := AVerb;
  FService := AService;
  FApproval := AApproval;
end;

procedure TSubagentTool.Register(ATools: TToolRegistry);
begin
  ATools.Add(ToolSpecFor(FVerb), Run);
end;

function TSubagentTool.Approve(const ARef, ASummary, AReason: string;
  out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
begin
  AError := '';
  if FApproval = nil then
  begin
    AError := 'no approval service configured';
    Exit(False);
  end;
  Ask := Default(TApprovalAsk);
  Ask.Summary := ASummary;
  Ask.Reason := AReason;
  Ask.Subject.Ref := ARef;
  Ask.Subject.Params := nil;   // v1: tool-level (ref alone)
  AddAllowOptions(Ask, ARef);
  SetLength(Asks, 1);
  Asks[0] := Ask;
  if not FApproval.Resolve(Asks, Batch) then
  begin
    AError := 'approval error: ' + Batch.Reason;
    Exit(False);
  end;
  if Batch.Denied then
  begin
    AError := Batch.Reason;
    Exit(False);
  end;
  Result := True;
end;

function TSubagentTool.ApprovalAsks(
  const AArgumentsJson: string): TApprovalAskArray;
var
  Data: TJSONData;
  Root: TJSONObject;
  Task, Sess, Lbl, Reason, ReasonError: string;
  Ask: TApprovalAsk;
begin
  Result := nil;
  Data := nil;
  if not ParseRoot(AArgumentsJson, Data, Root) then
    Exit;
  try
    Reason := '';
    ExtractToolReason(AArgumentsJson, Reason, ReasonError);
    Ask := Default(TApprovalAsk);
    Ask.Subject.Ref := SubagentApprovalRef(FVerb);
    Ask.Reason := Reason;
    case FVerb of
      svDelegate:
        begin
          if not ReadStringArg(Root, 'task', Task) then
            Exit;
          ReadStringArg(Root, 'label', Lbl);
          if Lbl <> '' then
            Ask.Summary := Lbl
          else
            Ask.Summary := Task;
        end;
    else
      begin
        if not ReadStringArg(Root, 'session_id', Sess) then
          Exit;
        Ask.Summary := SubagentVerbName(FVerb) + ' ' + Sess;
      end;
    end;
    AddAllowOptions(Ask, Ask.Subject.Ref);
    SetLength(Result, 1);
    Result[0] := Ask;
  finally
    Data.Free;
  end;
end;

function TSubagentTool.Run(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Task, Context, Lbl, Sess, Msg, Reason, ReasonError, Summary: string;
  Spawn: TSubagentSpawnResult;
  ServiceError: string;
begin
  Result := False;
  AResult := '';
  AError := '';
  if FService = nil then
  begin
    AError := 'no subagent service configured';
    Exit;
  end;
  Data := nil;
  if not ParseRoot(AArgumentsJson, Data, Root) then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    Reason := '';
    ExtractToolReason(AArgumentsJson, Reason, ReasonError);
    case FVerb of
      svDelegate:
        begin
          if not ReadStringArg(Root, 'task', Task) or (Trim(Task) = '') then
          begin
            AError := 'task is required';
            Exit;
          end;
          if not ReadStringArg(Root, 'context', Context) then
            Context := '';
          if not ReadStringArg(Root, 'label', Lbl) or (Trim(Lbl) = '') then
          begin
            AError := 'label is required';
            Exit;
          end;
          Summary := Lbl;
          if Summary = '' then
            Summary := Task;
          if not Approve(SubagentApprovalRef(FVerb), Summary, Reason, AError)
          then
            Exit;
          { The reason is required on every delegate call, and it is the best
            description of what the child is for - so it becomes the child's
            title. Lbl stays the short handle. }
          if not FService.Delegate(Task, Context, Lbl, Reason, Spawn) then
          begin
            AError := Spawn.Error;
            Exit;
          end;
          AResult := Format('subagent %s spawned for "%s"; %d of %d slots ' +
            'available. You will be notified when it finishes; use %s to ' +
            'follow up.', [Spawn.SessionId, Lbl, Spawn.Available, Spawn.Max,
            SubagentMessageTool]);
        end;
    else
      begin
        if not ReadStringArg(Root, 'session_id', Sess) or (Trim(Sess) = '') then
        begin
          AError := 'session_id is required';
          Exit;
        end;
        if FVerb = svMessage then
        begin
          if not ReadStringArg(Root, 'message', Msg) or (Trim(Msg) = '') then
          begin
            AError := 'message is required';
            Exit;
          end;
          Summary := 'message to subagent ' + Sess;
        end
        else
          Summary := SubagentVerbName(FVerb) + ' subagent ' + Sess;
        if not Approve(SubagentApprovalRef(FVerb), Summary, Reason, AError)
        then
          Exit;
        case FVerb of
          svMessage:
            begin
              if not FService.Message(Sess, Msg, ServiceError) then
              begin
                AError := ServiceError;
                Exit;
              end;
              AResult := 'follow-up queued to subagent ' + Sess + '.';
            end;
          svAbort:
            begin
              if not FService.Abort(Sess, ServiceError) then
              begin
                AError := ServiceError;
                Exit;
              end;
              AResult := 'subagent ' + Sess + ' aborted.';
            end;
          svRelease:
            begin
              if not FService.Release(Sess, ServiceError) then
              begin
                AError := ServiceError;
                Exit;
              end;
              AResult := 'subagent ' + Sess + ' released (still running).';
            end;
        else
          ;   // svDelegate is handled above
        end;
      end;
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- TSubagentToolSet --------------------------------------------------- }

constructor TSubagentToolSet.Create(AService: ISubagentService;
  AApproval: IApprovalService);
var
  V: TSubagentVerb;
begin
  inherited Create;
  for V := Low(TSubagentVerb) to High(TSubagentVerb) do
    FTools[V] := TSubagentTool.Create(V, AService, AApproval);
end;

destructor TSubagentToolSet.Destroy;
var
  V: TSubagentVerb;
begin
  for V := Low(TSubagentVerb) to High(TSubagentVerb) do
    FTools[V].Free;
  inherited Destroy;
end;

procedure TSubagentToolSet.Register(ATools: TToolRegistry);
var
  V: TSubagentVerb;
begin
  for V := Low(TSubagentVerb) to High(TSubagentVerb) do
    FTools[V].Register(ATools);
end;

end.
