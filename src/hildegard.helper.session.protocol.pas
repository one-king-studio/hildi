unit hildegard.helper.session.protocol;
{ The wire contract for headless sessions: the typed schema shared by the
  runtime and its clients, plus a pure NDJSON codec (record <-> one line).

  The schema is transport-agnostic - nothing here knows about sockets. v1 binds
  it to NDJSON over AF_UNIX in hildegard.helper.session.runtime, but a JSON-RPC
  codec or an SSE/WebSocket transport can re-bind the same types.

  Framing: one UTF-8 JSON object per line, terminated by '\n'. Encode returns
  the line including its terminator; Decode tolerates (and strips) one. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.approval, hildegard.helper.llm;

type
  { The row ids a tool call's changes carry. The event transports these, never
    the patches - the client reads diffs from the store by id. }
  TChangeIdArray = array of Integer;

  TSessionRole = (srObserve, srDrive);

  TSessionCaps = set of TSessionRole;

  TSessionEventKind = (
    ekLoopStarted, ekTurnStarted, ekUserMessage,
    ekAssistantDelta, ekAssistantBlock, ekReasoningDelta,
    ekToolCall, ekToolResult,
    ekApprovalRequest, ekApprovalResolved,
    ekDriveRequested, ekDriveGranted, ekDriveReleased,
    ekTurnFinished, ekError, ekGap, ekLoopExited,
    { The reasoning phase of a response ended; elapsed_ms is its duration.
      Appended last so stored ordinals are unchanged. }
    ekReasoningDone,
    { A streamed chunk of a tool's output. Appended last for the same reason. }
    ekToolOutput,
    { Subagent events, appended last so stored ordinals are unchanged:
      ekAmbient is a delivered subagent result; ekSubagent is a roster update;
      ekSubagentAsk is a child's approval ask relayed up. }
    ekAmbient, ekSubagent, ekSubagentAsk,
    { Context checkpoint: a draft is ready (Text), and a checkpoint was committed
      (TurnSeq = the checkpoint boundary seq). Appended last. }
    ekCheckpointCommitted,
    { A tool call's recorded file changes: the ROW IDS only, never the patches.
      A patch on every event would put kilobytes of diff on the wire per call,
      and the client already holds a store handle. Appended last so stored
      ordinals are unchanged. }
    ekChanges);

  { One streamed event. A flat record with optional fields, the same shape as
    TTurnEvent: only the fields named by Kind are meaningful. }
  TSessionEvent = record
    Seq: Int64;                 // monotonic per loop
    Ts: Int64;                  // epoch ms
    Kind: TSessionEventKind;
    Text: string;               // message/delta/block/result text; error message
    Detail: string;             // error detail
    LoopId: string;             // loop_started
    SessionId: string;          // loop_started
    TurnSeq: Int64;             // turn_started: the per-session turn sequence
    ToolId: string;
    ToolName: string;
    ToolArguments: string;      // raw JSON
    ToolReason: string;
    ToolOk: Boolean;
    AskId: string;              // approval_request / approval_resolved
    Ask: TApprovalAsk;          // approval_request payload
    Choice: TApprovalChoice;    // approval_resolved
    FinishReason: string;       // turn_finished
    Usage: TTokenUsage;         // turn_finished
    ElapsedMs: Int64;           // turn_finished
    ErrorCode: string;          // error
    Dropped: Boolean;           // error: the turn was cancelled with no commit
    FromSeq: Int64;             // gap: first missing seq
    ToSeq: Int64;               // gap: last delivered seq
    Client: string;             // drive_*: client id
    Reason: string;             // loop_exited
    { Subagent: the child session an ambient/roster/ask event refers to, and the
      roster status. }
    SubSessionId: string;
    SubStatus: string;
    { ekChanges: the tool call whose changes these are, and the ids of its
      recorded change rows. The patches are read from the store by id - they are
      deliberately not on the wire. }
    ChangeCallId: string;
    ChangeIds: TChangeIdArray;
  end;

  TSessionCommandKind = (
    scAttach, scDetach, scPrompt, scApprove, scInterrupt,
    scClaimDrive, scReleaseDrive, scPing,
    { Ask the runtime to stop gracefully. Driver-only. Appended last so stored
      ordinals are unchanged. }
    scShutdown,
    { Operator subagent actions, appended last. }
    scAbortSubagent, scReleaseSubagent,
    { Context checkpoint: request a draft, then commit an edited one. Driver-only.
      Appended last so stored ordinals are unchanged. }
    scCheckpoint,
    { Undo a turn: revert its files and rewind its transcript. Driver-only. The
      runtime owns the workspace, so this is the only party that may do it - the
      client only asks. Appended last so stored ordinals are unchanged. }
    scUndo);

  { One client command. Id is echoed in the reply. }
  TSessionCommand = record
    Id: string;
    Kind: TSessionCommandKind;
    FromSeq: Int64;             // attach
    Role: TSessionRole;         // attach
    Text: string;               // prompt
    AskId: string;              // approve
    Choice: TApprovalChoice;    // approve
    { The child session an abort/release subagent command acts on. }
    SessionId: string;
    { scUndo: which turn to undo. 0 means the newest completed one. }
    TurnId: Int64;
    { scCheckpoint: no payload; it starts a checkpoint turn. }
  end;

  TSessionHello = record
    Protocol: string;           // 'hildegard-session'
    Version: Integer;           // 1
    SessionId: string;
    LoopId: string;
    Caps: TSessionCaps;
  end;

  TSessionAttached = record
    Role: TSessionRole;         // granted role
    Driver: string;             // current driver client id ('' when none)
    LastSeq: Int64;
    StoreHwm: Int64;
  end;

  { The in-memory form of any wire message. }
  TSessionMessageKind = (mkHello, mkAttached, mkEvent, mkReply, mkDetached,
    mkError, mkAttach, mkDetach, mkCmd, mkPing, mkPong);

  TSessionMessage = record
    Kind: TSessionMessageKind;
    Hello: TSessionHello;
    Attached: TSessionAttached;
    Event: TSessionEvent;
    Command: TSessionCommand;
    ReplyId: string;            // reply
    Ok: Boolean;                // reply
    ErrorCode: string;          // error / reply
    ErrorMessage: string;
    Detail: string;
    Reason: string;             // detached
  end;

  { Pure codec: record <-> one NDJSON line. No sockets, no state. }
  TSessionCodec = class
  public
    { Returns the JSON line, including its trailing '\n'. }
    class function Encode(const AMessage: TSessionMessage): string;
    { Parses one line (a trailing newline is tolerated). Returns False - with
      AMessage zeroed - on malformed JSON, an unknown type, an unknown event
      kind, or an oversize line. }
    class function Decode(const ALine: string;
      out AMessage: TSessionMessage): Boolean;
  end;

const
  SessionProtocolName = 'hildegard-session';
  SessionProtocolVersion = 1;
  { Framing ceiling: a longer line is rejected and the connection closed, which
    bounds memory against a hostile or garbled peer. }
  DefaultMaxLineBytes = 1048576;

function SessionRoleToWire(ARole: TSessionRole): string;
function SessionRoleFromWire(const AValue: string;
  out ARole: TSessionRole): Boolean;
function SessionEventKindToWire(AKind: TSessionEventKind): string;
function SessionEventKindFromWire(const AValue: string;
  out AKind: TSessionEventKind): Boolean;
function SessionCommandKindToWire(AKind: TSessionCommandKind): string;
function SessionCommandKindFromWire(const AValue: string;
  out AKind: TSessionCommandKind): Boolean;
{ The wire spelling of a loop error code (the `error` event's `code`). }
function SessionErrorCodeToWire(ACode: TLLMErrorCode): string;
function SessionErrorCodeFromWire(const AValue: string): TLLMErrorCode;

implementation

uses
  fpjson, jsonparser;

{ A comma-joined list of row ids. The event carries ids, never patches: the
  client reads the diffs from the store, so a big change costs one string of
  numbers on the wire instead of kilobytes of diff. }
function JoinIds(const AIds: array of Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AIds) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(AIds[I]);
  end;
end;

function SplitIds(const AText: string): TChangeIdArray;
var
  P, Start, N: Integer;
  Part: string;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for P := 1 to Length(AText) + 1 do
    if (P > Length(AText)) or (AText[P] = ',') then
    begin
      Part := Trim(Copy(AText, Start, P - Start));
      Start := P + 1;
      if Part = '' then
        Continue;
      SetLength(Result, N + 1);
      Result[N] := StrToIntDef(Part, 0);
      if Result[N] > 0 then
        Inc(N)
      else
        SetLength(Result, N);
    end;
end;

const
  EventKindNames: array[TSessionEventKind] of string = (
    'loop_started', 'turn_started', 'user_message',
    'assistant_delta', 'assistant_block', 'reasoning_delta',
    'tool_call', 'tool_result',
    'approval_request', 'approval_resolved',
    'drive_requested', 'drive_granted', 'drive_released',
    'turn_finished', 'error', 'gap', 'loop_exited', 'reasoning_done',
    'tool_output', 'ambient', 'subagent', 'subagent_ask',
    'checkpoint_committed', 'changes');

  MessageKindNames: array[TSessionMessageKind] of string = (
    'hello', 'attached', 'event', 'reply', 'detached', 'error',
    'attach', 'detach', 'cmd', 'ping', 'pong');

  { The `cmd` names. attach/detach/ping are top-level message types, not cmd
    names, so they are absent here. }
  CommandKindNames: array[TSessionCommandKind] of string = (
    'attach', 'detach', 'prompt', 'approve', 'interrupt',
    'claim_drive', 'release_drive', 'ping', 'shutdown',
    'abort_subagent', 'release_subagent', 'checkpoint', 'undo');

{ --- enum <-> wire ------------------------------------------------------ }

function SessionRoleToWire(ARole: TSessionRole): string;
begin
  if ARole = srDrive then
    Result := 'drive'
  else
    Result := 'observe';
end;

function SessionRoleFromWire(const AValue: string;
  out ARole: TSessionRole): Boolean;
begin
  ARole := srObserve;
  if AValue = 'observe' then
    Result := True
  else if AValue = 'drive' then
  begin
    ARole := srDrive;
    Result := True;
  end
  else
    Result := False;
end;

function SessionEventKindToWire(AKind: TSessionEventKind): string;
begin
  Result := EventKindNames[AKind];
end;

function SessionEventKindFromWire(const AValue: string;
  out AKind: TSessionEventKind): Boolean;
var
  K: TSessionEventKind;
begin
  for K := Low(TSessionEventKind) to High(TSessionEventKind) do
    if EventKindNames[K] = AValue then
    begin
      AKind := K;
      Exit(True);
    end;
  AKind := ekError;
  Result := False;
end;

function SessionCommandKindToWire(AKind: TSessionCommandKind): string;
begin
  Result := CommandKindNames[AKind];
end;

function SessionCommandKindFromWire(const AValue: string;
  out AKind: TSessionCommandKind): Boolean;
var
  K: TSessionCommandKind;
begin
  for K := Low(TSessionCommandKind) to High(TSessionCommandKind) do
    if CommandKindNames[K] = AValue then
    begin
      AKind := K;
      Exit(True);
    end;
  AKind := scPrompt;
  Result := False;
end;

const
  ErrorCodeNames: array[TLLMErrorCode] of string = (
    'ok', 'config', 'network', 'http_status', 'auth', 'rate_limit',
    'malformed_stream', 'provider', 'cancelled', 'loop', 'truncated');

function SessionErrorCodeToWire(ACode: TLLMErrorCode): string;
begin
  Result := ErrorCodeNames[ACode];
end;

function SessionErrorCodeFromWire(const AValue: string): TLLMErrorCode;
var
  C: TLLMErrorCode;
begin
  for C := Low(TLLMErrorCode) to High(TLLMErrorCode) do
    if ErrorCodeNames[C] = AValue then
      Exit(C);
  Result := leProvider;
end;

{ --- JSON field helpers ------------------------------------------------- }

procedure PutStr(O: TJSONObject; const AName, AValue: string);
begin
  if AValue <> '' then
    O.Add(AName, AValue);
end;

procedure PutInt(O: TJSONObject; const AName: string; AValue: Int64);
begin
  if AValue <> 0 then
    O.Add(AName, AValue);
end;

procedure PutBool(O: TJSONObject; const AName: string; AValue: Boolean);
begin
  if AValue then
    O.Add(AName, True);
end;

function NodeOf(O: TJSONObject; const AName: string): TJSONData;
begin
  Result := O.Find(AName);
end;

function OptStr(O: TJSONObject; const AName: string): string;
var
  D: TJSONData;
begin
  D := NodeOf(O, AName);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ''
  else
    Result := D.AsString;
end;

function OptInt64(O: TJSONObject; const AName: string; ADefault: Int64): Int64;
var
  D: TJSONData;
begin
  D := NodeOf(O, AName);
  if (D = nil) or (D.JSONType <> jtNumber) then
    Result := ADefault
  else
    Result := D.AsInt64;
end;

function OptBool(O: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  D: TJSONData;
begin
  D := NodeOf(O, AName);
  if (D = nil) or (D.JSONType <> jtBoolean) then
    Result := ADefault
  else
    Result := D.AsBoolean;
end;

function IsIntField(O: TJSONObject; const AName: string): Boolean;
var
  D: TJSONData;
begin
  D := NodeOf(O, AName);
  Result := (D <> nil) and (D.JSONType = jtNumber);
end;

{ --- caps --------------------------------------------------------------- }

function EncodeCaps(ACaps: TSessionCaps): TJSONArray;
begin
  Result := TJSONArray.Create;
  if srObserve in ACaps then
    Result.Add(SessionRoleToWire(srObserve));
  if srDrive in ACaps then
    Result.Add(SessionRoleToWire(srDrive));
end;

function DecodeCaps(O: TJSONObject; out ACaps: TSessionCaps): Boolean;
var
  D: TJSONData;
  Arr: TJSONArray;
  I: Integer;
  Role: TSessionRole;
begin
  ACaps := [];
  Result := True;
  D := NodeOf(O, 'caps');
  if D = nil then
    Exit;
  if not (D is TJSONArray) then
    Exit(False);
  Arr := TJSONArray(D);
  for I := 0 to Arr.Count - 1 do
    if SessionRoleFromWire(Arr.Strings[I], Role) then
      Include(ACaps, Role);
end;

{ --- usage -------------------------------------------------------------- }

function EncodeUsage(const AUsage: TTokenUsage): TJSONObject;
begin
  Result := TJSONObject.Create;
  PutInt(Result, 'prompt', AUsage.PromptTokens);
  PutInt(Result, 'completion', AUsage.CompletionTokens);
  PutInt(Result, 'total', AUsage.TotalTokens);
  PutInt(Result, 'cached', AUsage.CachedTokens);
  PutInt(Result, 'reasoning', AUsage.ReasoningTokens);
end;

procedure DecodeUsage(O: TJSONObject; out AUsage: TTokenUsage);
begin
  AUsage := Default(TTokenUsage);
  AUsage.PromptTokens := OptInt64(O, 'prompt', 0);
  AUsage.CompletionTokens := OptInt64(O, 'completion', 0);
  AUsage.TotalTokens := OptInt64(O, 'total', 0);
  AUsage.CachedTokens := OptInt64(O, 'cached', 0);
  AUsage.ReasoningTokens := OptInt64(O, 'reasoning', 0);
end;

{ --- approval choice ---------------------------------------------------- }

function ScopeToWire(AScope: TApprovalScope): string;
begin
  case AScope of
    asGlobal: Result := 'global';
    asWorkspace: Result := 'workspace';
    asSession: Result := 'session';
  end;
end;

function ScopeFromWire(const AValue: string): TApprovalScope;
begin
  if AValue = 'global' then
    Result := asGlobal
  else if AValue = 'session' then
    Result := asSession
  else
    Result := asWorkspace;
end;

function EncodeChoice(const AChoice: TApprovalChoice): TJSONObject;
begin
  Result := TJSONObject.Create;
  PutBool(Result, 'allowed', AChoice.Allowed);
  PutStr(Result, 'option', AChoice.OptionKey);
  Result.Add('scope', ScopeToWire(AChoice.Scope));
end;

function DecodeChoice(O: TJSONObject; out AChoice: TApprovalChoice): Boolean;
begin
  AChoice := Default(TApprovalChoice);
  if (O = nil) or not (O is TJSONObject) then
    Exit(False);
  AChoice.Allowed := OptBool(O, 'allowed', False);
  AChoice.OptionKey := OptStr(O, 'option');
  AChoice.Scope := ScopeFromWire(OptStr(O, 'scope'));
  Result := True;
end;

function EncodeOptions(const AOptions: TApprovalOptionArray): TJSONArray;
var
  I: Integer;
  Item: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AOptions) do
  begin
    Item := TJSONObject.Create;
    Item.Add('key', AOptions[I].Key);
    Item.Add('caption', AOptions[I].Caption);
    Result.Add(Item);
  end;
end;

procedure DecodeOptions(O: TJSONObject; var AAsk: TApprovalAsk);
var
  D: TJSONData;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONData;
  Opt: TApprovalOption;
begin
  AAsk.Options := nil;
  D := NodeOf(O, 'options');
  if not (D is TJSONArray) then
    Exit;
  Arr := TJSONArray(D);
  SetLength(AAsk.Options, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    Opt := Default(TApprovalOption);
    Item := Arr.Items[I];
    if Item is TJSONObject then
    begin
      Opt.Key := OptStr(TJSONObject(Item), 'key');
      Opt.Caption := OptStr(TJSONObject(Item), 'caption');
    end;
    AAsk.Options[I] := Opt;
  end;
end;

{ --- events ------------------------------------------------------------- }

procedure AddEventFields(O: TJSONObject; const E: TSessionEvent);
begin
  PutInt(O, 'seq', E.Seq);
  PutInt(O, 'ts', E.Ts);
  O.Add('kind', SessionEventKindToWire(E.Kind));
  case E.Kind of
    ekLoopStarted:
      begin
        PutStr(O, 'loop', E.LoopId);
        PutStr(O, 'session', E.SessionId);
      end;
    ekTurnStarted:
      PutInt(O, 'turn_seq', E.TurnSeq);
    ekUserMessage, ekAssistantDelta, ekAssistantBlock, ekReasoningDelta:
      PutStr(O, 'text', E.Text);
    ekToolCall:
      begin
        PutStr(O, 'tool_id', E.ToolId);
        PutStr(O, 'name', E.ToolName);
        PutStr(O, 'arguments', E.ToolArguments);
        PutStr(O, 'reason', E.ToolReason);
      end;
    ekToolResult:
      begin
        PutStr(O, 'tool_id', E.ToolId);
        PutStr(O, 'name', E.ToolName);
        PutBool(O, 'ok', E.ToolOk);
        PutStr(O, 'text', E.Text);
      end;
    ekApprovalRequest:
      begin
        PutStr(O, 'ask_id', E.AskId);
        PutStr(O, 'summary', E.Ask.Summary);
        PutStr(O, 'reason', E.Ask.Reason);
        { Additive: an older client still renders Summary when the script is
          absent. }
        if E.Ask.Script <> '' then
          PutStr(O, 'script', E.Ask.Script);
        if E.Ask.FocusLen > 0 then
        begin
          PutInt(O, 'focus_start', E.Ask.FocusStart);
          PutInt(O, 'focus_len', E.Ask.FocusLen);
        end;
        O.Add('options', EncodeOptions(E.Ask.Options));
      end;
    ekApprovalResolved:
      begin
        PutStr(O, 'ask_id', E.AskId);
        O.Add('choice', EncodeChoice(E.Choice));
      end;
    ekDriveRequested, ekDriveGranted, ekDriveReleased:
      PutStr(O, 'client', E.Client);
    ekTurnFinished:
      begin
        PutStr(O, 'finish_reason', E.FinishReason);
        O.Add('usage', EncodeUsage(E.Usage));
        PutInt(O, 'elapsed_ms', E.ElapsedMs);
      end;
    ekError:
      begin
        PutStr(O, 'code', E.ErrorCode);
        PutStr(O, 'message', E.Text);
        PutStr(O, 'detail', E.Detail);
        PutBool(O, 'dropped', E.Dropped);
      end;
    ekGap:
      begin
        PutInt(O, 'from_seq', E.FromSeq);
        PutInt(O, 'to_seq', E.ToSeq);
      end;
    ekLoopExited:
      PutStr(O, 'reason', E.Reason);
    ekReasoningDone:
      PutInt(O, 'elapsed_ms', E.ElapsedMs);
    ekToolOutput:
      begin
        PutStr(O, 'tool_id', E.ToolId);
        PutStr(O, 'name', E.ToolName);
        PutStr(O, 'text', E.Text);
      end;
    ekAmbient:
      begin
        PutStr(O, 'session', E.SubSessionId);
        PutStr(O, 'text', E.Text);
        PutInt(O, 'elapsed_ms', E.ElapsedMs);
      end;
    ekSubagent:
      begin
        PutStr(O, 'session', E.SubSessionId);
        PutStr(O, 'label', E.Text);
        PutStr(O, 'status', E.SubStatus);
      end;
    ekSubagentAsk:
      begin
        PutStr(O, 'session', E.SubSessionId);
        PutStr(O, 'ask_id', E.AskId);
        PutStr(O, 'summary', E.Ask.Summary);
        PutStr(O, 'reason', E.Ask.Reason);
        { Additive: an older client still renders Summary when the script is
          absent. }
        if E.Ask.Script <> '' then
          PutStr(O, 'script', E.Ask.Script);
        if E.Ask.FocusLen > 0 then
        begin
          PutInt(O, 'focus_start', E.Ask.FocusStart);
          PutInt(O, 'focus_len', E.Ask.FocusLen);
        end;
        O.Add('options', EncodeOptions(E.Ask.Options));
      end;
    ekCheckpointCommitted:
      PutInt(O, 'turn_seq', E.TurnSeq);
    ekChanges:
      begin
        PutStr(O, 'tool_id', E.ChangeCallId);
        PutStr(O, 'change_ids', JoinIds(E.ChangeIds));
      end;
  end;
end;

function DecodeEvent(O: TJSONObject; out E: TSessionEvent): Boolean;
var
  KindStr: string;
  D: TJSONData;
begin
  E := Default(TSessionEvent);
  if not (NodeOf(O, 'kind') is TJSONData) then
    Exit(False);
  KindStr := OptStr(O, 'kind');
  if not SessionEventKindFromWire(KindStr, E.Kind) then
    Exit(False);
  E.Seq := OptInt64(O, 'seq', 0);
  E.Ts := OptInt64(O, 'ts', 0);
  case E.Kind of
    ekLoopStarted:
      begin
        E.LoopId := OptStr(O, 'loop');
        E.SessionId := OptStr(O, 'session');
      end;
    ekTurnStarted:
      E.TurnSeq := OptInt64(O, 'turn_seq', 0);
    ekUserMessage, ekAssistantDelta, ekAssistantBlock, ekReasoningDelta:
      E.Text := OptStr(O, 'text');
    ekToolCall:
      begin
        E.ToolId := OptStr(O, 'tool_id');
        E.ToolName := OptStr(O, 'name');
        E.ToolArguments := OptStr(O, 'arguments');
        E.ToolReason := OptStr(O, 'reason');
      end;
    ekToolResult:
      begin
        E.ToolId := OptStr(O, 'tool_id');
        E.ToolName := OptStr(O, 'name');
        E.ToolOk := OptBool(O, 'ok', False);
        E.Text := OptStr(O, 'text');
      end;
    ekApprovalRequest:
      begin
        E.AskId := OptStr(O, 'ask_id');
        E.Ask := Default(TApprovalAsk);
        E.Ask.Summary := OptStr(O, 'summary');
        E.Ask.Reason := OptStr(O, 'reason');
        E.Ask.Script := OptStr(O, 'script');
        E.Ask.FocusStart := OptInt64(O, 'focus_start', 0);
        E.Ask.FocusLen := OptInt64(O, 'focus_len', 0);
        DecodeOptions(O, E.Ask);
      end;
    ekApprovalResolved:
      begin
        E.AskId := OptStr(O, 'ask_id');
        D := NodeOf(O, 'choice');
        if not (D is TJSONObject) then
          Exit(False);
        if not DecodeChoice(TJSONObject(D), E.Choice) then
          Exit(False);
      end;
    ekDriveRequested, ekDriveGranted, ekDriveReleased:
      E.Client := OptStr(O, 'client');
    ekTurnFinished:
      begin
        E.FinishReason := OptStr(O, 'finish_reason');
        D := NodeOf(O, 'usage');
        if D is TJSONObject then
          DecodeUsage(TJSONObject(D), E.Usage);
        E.ElapsedMs := OptInt64(O, 'elapsed_ms', 0);
      end;
    ekError:
      begin
        E.ErrorCode := OptStr(O, 'code');
        E.Text := OptStr(O, 'message');
        E.Detail := OptStr(O, 'detail');
        E.Dropped := OptBool(O, 'dropped', False);
      end;
    ekGap:
      begin
        E.FromSeq := OptInt64(O, 'from_seq', 0);
        E.ToSeq := OptInt64(O, 'to_seq', 0);
      end;
    ekLoopExited:
      E.Reason := OptStr(O, 'reason');
    ekReasoningDone:
      E.ElapsedMs := OptInt64(O, 'elapsed_ms', 0);
    ekToolOutput:
      begin
        E.ToolId := OptStr(O, 'tool_id');
        E.ToolName := OptStr(O, 'name');
        E.Text := OptStr(O, 'text');
      end;
    ekAmbient:
      begin
        E.SubSessionId := OptStr(O, 'session');
        E.Text := OptStr(O, 'text');
        E.ElapsedMs := OptInt64(O, 'elapsed_ms', 0);
      end;
    ekSubagent:
      begin
        E.SubSessionId := OptStr(O, 'session');
        E.Text := OptStr(O, 'label');
        E.SubStatus := OptStr(O, 'status');
      end;
    ekSubagentAsk:
      begin
        E.SubSessionId := OptStr(O, 'session');
        E.AskId := OptStr(O, 'ask_id');
        E.Ask := Default(TApprovalAsk);
        E.Ask.Summary := OptStr(O, 'summary');
        E.Ask.Reason := OptStr(O, 'reason');
        E.Ask.Script := OptStr(O, 'script');
        E.Ask.FocusStart := OptInt64(O, 'focus_start', 0);
        E.Ask.FocusLen := OptInt64(O, 'focus_len', 0);
        DecodeOptions(O, E.Ask);
      end;
    ekCheckpointCommitted:
      E.TurnSeq := OptInt64(O, 'turn_seq', 0);
    ekChanges:
      begin
        E.ChangeCallId := OptStr(O, 'tool_id');
        E.ChangeIds := SplitIds(OptStr(O, 'change_ids'));
      end;
  end;
  Result := True;
end;

{ --- commands ----------------------------------------------------------- }

procedure AddCommandFields(O: TJSONObject; const C: TSessionCommand);
begin
  O.Add('name', SessionCommandKindToWire(C.Kind));
  case C.Kind of
    scPrompt:
      PutStr(O, 'text', C.Text);
    scApprove:
      begin
        PutStr(O, 'ask_id', C.AskId);
        O.Add('choice', EncodeChoice(C.Choice));
      end;
    scAbortSubagent, scReleaseSubagent:
      PutStr(O, 'session', C.SessionId);
    scAttach, scDetach, scInterrupt, scClaimDrive, scReleaseDrive, scPing,
    scUndo:
      PutInt(O, 'turn_id', C.TurnId);
    scShutdown, scCheckpoint:
      ;   // no payload beyond the name
  end;
end;

function DecodeCommandFields(O: TJSONObject;
  var C: TSessionCommand): Boolean;
var
  NameStr: string;
  D: TJSONData;
begin
  if not (NodeOf(O, 'name') is TJSONData) then
    Exit(False);
  NameStr := OptStr(O, 'name');
  if not SessionCommandKindFromWire(NameStr, C.Kind) then
    Exit(False);
  { attach/detach have dedicated message types; they are not cmd names. }
  if C.Kind in [scAttach, scDetach] then
    Exit(False);
  case C.Kind of
    scPrompt:
      C.Text := OptStr(O, 'text');
    scApprove:
      begin
        C.AskId := OptStr(O, 'ask_id');
        D := NodeOf(O, 'choice');
        if not (D is TJSONObject) then
          Exit(False);
        if not DecodeChoice(TJSONObject(D), C.Choice) then
          Exit(False);
      end;
    scAbortSubagent, scReleaseSubagent:
      C.SessionId := OptStr(O, 'session');
    scUndo:
      C.TurnId := OptInt64(O, 'turn_id', 0);
    scAttach, scDetach, scInterrupt, scClaimDrive, scReleaseDrive, scPing,
    scShutdown, scCheckpoint:
      ;
  end;
  Result := True;
end;

{ --- TSessionCodec ------------------------------------------------------ }

class function TSessionCodec.Encode(const AMessage: TSessionMessage): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('v', SessionProtocolVersion);
    case AMessage.Kind of
      mkHello:
        begin
          O.Add('type', MessageKindNames[mkHello]);
          O.Add('protocol', AMessage.Hello.Protocol);
          O.Add('version', AMessage.Hello.Version);
          O.Add('session', AMessage.Hello.SessionId);
          O.Add('loop', AMessage.Hello.LoopId);
          O.Add('caps', EncodeCaps(AMessage.Hello.Caps));
        end;
      mkAttached:
        begin
          O.Add('type', MessageKindNames[mkAttached]);
          O.Add('role', SessionRoleToWire(AMessage.Attached.Role));
          PutStr(O, 'driver', AMessage.Attached.Driver);
          PutInt(O, 'last_seq', AMessage.Attached.LastSeq);
          PutInt(O, 'store_hwm', AMessage.Attached.StoreHwm);
        end;
      mkEvent:
        begin
          O.Add('type', MessageKindNames[mkEvent]);
          AddEventFields(O, AMessage.Event);
        end;
      mkReply:
        begin
          O.Add('type', MessageKindNames[mkReply]);
          O.Add('id', AMessage.ReplyId);
          O.Add('ok', AMessage.Ok);
          PutStr(O, 'error', AMessage.ErrorCode);
        end;
      mkDetached:
        begin
          O.Add('type', MessageKindNames[mkDetached]);
          PutStr(O, 'reason', AMessage.Reason);
        end;
      mkError:
        begin
          O.Add('type', MessageKindNames[mkError]);
          PutStr(O, 'code', AMessage.ErrorCode);
          PutStr(O, 'message', AMessage.ErrorMessage);
          PutStr(O, 'detail', AMessage.Detail);
        end;
      mkAttach:
        begin
          O.Add('type', MessageKindNames[mkAttach]);
          PutInt(O, 'from_seq', AMessage.Command.FromSeq);
          O.Add('role', SessionRoleToWire(AMessage.Command.Role));
        end;
      mkDetach:
        O.Add('type', MessageKindNames[mkDetach]);
      mkCmd:
        begin
          O.Add('type', MessageKindNames[mkCmd]);
          O.Add('id', AMessage.Command.Id);
          AddCommandFields(O, AMessage.Command);
        end;
      mkPing:
        O.Add('type', MessageKindNames[mkPing]);
      mkPong:
        O.Add('type', MessageKindNames[mkPong]);
    end;
    Result := O.AsJSON + #10;
  finally
    O.Free;
  end;
end;

class function TSessionCodec.Decode(const ALine: string;
  out AMessage: TSessionMessage): Boolean;
var
  Trimmed, TypeStr, RoleStr: string;
  Data: TJSONData;
  O: TJSONObject;
  D: TJSONData;
  Role: TSessionRole;
begin
  AMessage := Default(TSessionMessage);
  Result := False;
  Trimmed := Trim(ALine);
  if (Trimmed = '') or (Length(Trimmed) > DefaultMaxLineBytes) then
    Exit;

  Data := nil;
  try
    try
      Data := GetJSON(Trimmed);
    except
      Exit(False);
    end;
    if not (Data is TJSONObject) then
      Exit;
    O := TJSONObject(Data);
    if not IsIntField(O, 'v') then
      Exit;
    TypeStr := OptStr(O, 'type');
    if TypeStr = '' then
      Exit;

    if TypeStr = MessageKindNames[mkHello] then
    begin
      AMessage.Kind := mkHello;
      AMessage.Hello.Protocol := OptStr(O, 'protocol');
      AMessage.Hello.Version := OptInt64(O, 'version', 0);
      AMessage.Hello.SessionId := OptStr(O, 'session');
      AMessage.Hello.LoopId := OptStr(O, 'loop');
      if not DecodeCaps(O, AMessage.Hello.Caps) then
        Exit;
    end
    else if TypeStr = MessageKindNames[mkAttached] then
    begin
      AMessage.Kind := mkAttached;
      if not SessionRoleFromWire(OptStr(O, 'role'), Role) then
        Exit;
      AMessage.Attached.Role := Role;
      AMessage.Attached.Driver := OptStr(O, 'driver');
      AMessage.Attached.LastSeq := OptInt64(O, 'last_seq', 0);
      AMessage.Attached.StoreHwm := OptInt64(O, 'store_hwm', 0);
    end
    else if TypeStr = MessageKindNames[mkEvent] then
    begin
      AMessage.Kind := mkEvent;
      if not DecodeEvent(O, AMessage.Event) then
        Exit;
    end
    else if TypeStr = MessageKindNames[mkReply] then
    begin
      AMessage.Kind := mkReply;
      AMessage.ReplyId := OptStr(O, 'id');
      AMessage.Ok := OptBool(O, 'ok', False);
      AMessage.ErrorCode := OptStr(O, 'error');
    end
    else if TypeStr = MessageKindNames[mkDetached] then
    begin
      AMessage.Kind := mkDetached;
      AMessage.Reason := OptStr(O, 'reason');
    end
    else if TypeStr = MessageKindNames[mkError] then
    begin
      AMessage.Kind := mkError;
      AMessage.ErrorCode := OptStr(O, 'code');
      AMessage.ErrorMessage := OptStr(O, 'message');
      AMessage.Detail := OptStr(O, 'detail');
    end
    else if TypeStr = MessageKindNames[mkAttach] then
    begin
      AMessage.Kind := mkAttach;
      AMessage.Command.Kind := scAttach;
      AMessage.Command.FromSeq := OptInt64(O, 'from_seq', 0);
      if not SessionRoleFromWire(OptStr(O, 'role'), Role) then
        Exit;
      AMessage.Command.Role := Role;
    end
    else if TypeStr = MessageKindNames[mkDetach] then
    begin
      AMessage.Kind := mkDetach;
      AMessage.Command.Kind := scDetach;
    end
    else if TypeStr = MessageKindNames[mkCmd] then
    begin
      AMessage.Kind := mkCmd;
      AMessage.Command.Id := OptStr(O, 'id');
      if not DecodeCommandFields(O, AMessage.Command) then
        Exit;
    end
    else if TypeStr = MessageKindNames[mkPing] then
    begin
      AMessage.Kind := mkPing;
      AMessage.Command.Kind := scPing;
    end
    else if TypeStr = MessageKindNames[mkPong] then
      AMessage.Kind := mkPong
    else
      Exit;
    Result := True;
  finally
    Data.Free;
  end;
end;

end.
