unit hildi.tasks.tools;
{ The task list's ten tools.

  Nine of them are ungated. Gating follows reach: every verb on your own claim
  changes only what you are doing, and a false `done` is visible and correctable.
  `task_reassign` takes work away from another agent mid-flight and `task_delete`
  destroys the record, so those two - and only those - ask.

  The claim is the feature. Everything else is CRUD; `task_claim`'s refusal - who
  holds it and since when - is the product, not an error string. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  hildi.llm, hildi.agent, hildi.approval,
  hildi.tasks, hildi.tasks.store;

type
  { Resolves a board question by id. A blocker names either a card or a question,
    and only the board can answer for the second; injecting the check keeps this
    unit free of a dependency on the board. }
  IBoardQuestionExists = function(AWorkspaceId, AId: Integer;
    out ATitle: string): Boolean of object;

  TTaskTool = class(TInterfacedObject, IToolProvider)
  private
    FStore: ITaskStore;
    FWorkspaceId: Integer;
    FSessionId, FLabel: string;
    FService: IApprovalService;
    FQuestionExists: IBoardQuestionExists;
    function Allow(const AOp, ATitle, AReason: string;
      out AError: string): Boolean;
    { Read, then translate a store refusal into something a model can act on. }
    function Load(AId: Integer; out ACard: TTaskCard; out AError: string):
      Boolean;
    function ResolveBlocker(AId: Integer; AKind: TBlockerKind;
      out AWhat: string; out AError: string): Boolean;
  public
    constructor Create(const AStore: ITaskStore; AWorkspaceId: Integer;
      const ASessionId, ALabel: string; AService: IApprovalService;
      AQuestionExists: IBoardQuestionExists);
    procedure Register(ATools: TToolRegistry);
    { IToolProvider: the tools are registered directly; the provider exists for
      the tail work queue, exactly as the board's does. }
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    { The tail work queue: '' when there is nothing to say, or when the store
      fails - a tail that cannot be built must not fail a turn. Capped at
      MaxTaskQueueBytes. }
    function QueueLine(out AError: string): string;
    { Public for direct testing, matching TToolHandler. }
    function ListCards(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function AddCard(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ClaimCard(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { release / block / unblock / done / drop, discriminated by `op`. }
    function TransitionCard(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function EditCard(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { reassign / delete, the two that ask. }
    function ModerateCard(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

const
  TaskListTool = 'task_list';
  TaskAddTool = 'task_add';
  TaskClaimTool = 'task_claim';
  TaskUpdateTool = 'task_update';
  TaskEditTool = 'task_edit';
  TaskModerateTool = 'task_moderate';

  { The tail budget. Larger than the board's 120 because a work queue is only
    useful if the cards are named. }
  MaxTaskQueueBytes = 400;

implementation

{ --- helpers ----------------------------------------------------------- }

function OneLine(const AText: string): string;
var
  P: Integer;
begin
  Result := Trim(AText);
  P := Pos(#10, Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

{ "14m" is what a model can act on; an absolute timestamp is not. }
function AgeLabel(const ASinceEpochSec, ANow: Int64): string;
var
  Sec: Int64;
begin
  Sec := ANow - ASinceEpochSec;
  if Sec < 0 then
    Sec := 0;
  if Sec < 60 then
    Result := IntToStr(Sec) + 's'
  else if Sec < 3600 then
    Result := IntToStr(Sec div 60) + 'm'
  else if Sec < 86400 then
    Result := IntToStr(Sec div 3600) + 'h'
  else
    Result := IntToStr(Sec div 86400) + 'd';
end;

function NowEpoch: Int64;
begin
  Result := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
end;

constructor TTaskTool.Create(const AStore: ITaskStore; AWorkspaceId: Integer;
  const ASessionId, ALabel: string; AService: IApprovalService;
  AQuestionExists: IBoardQuestionExists);
begin
  inherited Create;
  FStore := AStore;
  FWorkspaceId := AWorkspaceId;
  FSessionId := ASessionId;
  FLabel := ALabel;
  FService := AService;
  FQuestionExists := AQuestionExists;
end;

function TTaskTool.Load(AId: Integer; out ACard: TTaskCard;
  out AError: string): Boolean;
var
  Found: Boolean;
begin
  Result := False;
  AError := '';
  ACard := Default(TTaskCard);
  if not FStore.Get(FWorkspaceId, AId, ACard, Found, AError) then
  begin
    AError := 'could not read task ' + IntToStr(AId);
    Exit;
  end;
  if not Found then
  begin
    AError := 'no task card ' + IntToStr(AId) + ' in this workspace';
    Exit;
  end;
  Result := True;
end;

function TTaskTool.ResolveBlocker(AId: Integer; AKind: TBlockerKind;
  out AWhat: string; out AError: string): Boolean;
var
  Card: TTaskCard;
  Title: string;
begin
  Result := False;
  AWhat := '';
  AError := '';
  if AId = 0 then
  begin
    AError := 'blocked_on is required: a card id, or question:<board id>';
    Exit;
  end;
  case AKind of
    tbkCard:
      begin
        if not Load(AId, Card, AError) then
        begin
          AError := 'blocked_on: no task card ' + IntToStr(AId) + ' to wait on';
          Exit;
        end;
        AWhat := '#' + IntToStr(Card.Id) + ' ' + OneLine(Card.Title);
        Result := True;
      end;
    tbkQuestion:
      begin
        if not Assigned(FQuestionExists) then
        begin
          { There is no board here. Refusing by name beats silently recording a
            blocker that points at nothing. }
          AError := 'blocked_on question:' + IntToStr(AId) +
            ' cannot be resolved: no board is available in this session';
          Exit;
        end;
        if not FQuestionExists(FWorkspaceId, AId, Title) then
        begin
          AError := 'blocked_on: no board question ' + IntToStr(AId) +
            ' in this workspace';
          Exit;
        end;
        AWhat := 'question #' + IntToStr(AId) + ' ' + OneLine(Title);
        Result := True;
      end;
  else
    AError := 'blocked_on is required';
  end;
end;

function TTaskTool.Allow(const AOp, ATitle, AReason: string;
  out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
begin
  Result := False;
  AError := '';
  if FService = nil then
    Exit(True);                    // no gate wired: a test or a bare run
  Ask := Default(TApprovalAsk);
  Ask.Summary := 'task: ' + AOp + ' ' + OneLine(ATitle);
  Ask.Reason := AReason;
  Ask.Subject.Ref := 'task:moderate';
  SetLength(Ask.Options, 1);
  Ask.Options[0] := Default(TApprovalOption);
  Ask.Options[0].Key := 'once';
  Ask.Options[0].Caption := 'allow this once';
  Ask.Options[0].Persists := False;
  Ask.Options[0].Rule := DefaultApprovalRule(aeAllow);
  Ask.Options[0].Rule.Ref := 'task:moderate';
  SetLength(Asks, 1);
  Asks[0] := Ask;
  Batch := Default(TApprovalBatchResult);
  if not FService.Resolve(Asks, Batch) then
  begin
    AError := 'approval service failed';
    Exit;
  end;
  if Batch.Denied then
  begin
    if Batch.Reason <> '' then
      AError := 'task:moderate denied: ' + Batch.Reason
    else
      AError := 'task:moderate denied';
    Exit;
  end;
  Result := True;
end;

{ --- registration ------------------------------------------------------ }

procedure TTaskTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec := Default(TToolSpec);
  Spec.Name := TaskListTool;
  Spec.Description :=
    'List task cards in this workspace, newest activity first. A filter of '
    + '`mine` shows what this session holds; `parent` shows one card''s '
    + 'subtasks; `status` shows one column. Cards outlive a turn and a context '
    + 'reset, so this is how you find work started earlier - including your '
    + 'own. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"status":{"type":"string","enum":["open","claimed","blocked","done",' +
    '"dropped"]},' +
    '"mine":{"type":"boolean","description":"Only cards this session holds."},' +
    '"parent":{"type":"integer","description":"Only this card''s subtasks."},' +
    '"limit":{"type":"integer"},' +
    '"reason":{"type":"string"}' +
    '},"required":["reason"]}';
  ATools.Add(Spec, ListCards);

  Spec := Default(TToolSpec);
  Spec.Name := TaskAddTool;
  Spec.Description :=
    'Add a task card: durable work shared with any other agent in this '
    + 'workspace. `parent` nests it exactly one level under a top-level card. '
    + 'Adding does not claim it - claim it if you are about to do it. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"title":{"type":"string","description":"One line: what to do."},' +
    '"body":{"type":"string","description":"Acceptance criteria, context."},' +
    '"parent":{"type":"integer","description":"Parent card id (one level)."},' +
    '"reason":{"type":"string"}' +
    '},"required":["title","reason"]}';
  ATools.Add(Spec, AddCard);

  Spec := Default(TToolSpec);
  Spec.Name := TaskClaimTool;
  Spec.Description :=
    'Claim an open card, so others can see you are on it. Exactly one agent '
    + 'holds a card at a time; if someone else has it, the refusal names them '
    + 'and when they took it. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"id":{"type":"integer"},' +
    '"reason":{"type":"string"}' +
    '},"required":["id","reason"]}';
  ATools.Add(Spec, ClaimCard);

  Spec := Default(TToolSpec);
  Spec.Name := TaskUpdateTool;
  Spec.Description :=
    'Move a card you hold: release it back to open, block it on a card or a '
    + 'board question, unblock it, complete it with a summary, or drop it with '
    + 'a reason. `done` needs the claim; `drop` also works on an unclaimed card. '
    + 'Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"op":{"type":"string","enum":["release","block","unblock","done","drop"]},' +
    '"id":{"type":"integer"},' +
    '"blocked_on":{"type":"string","description":"For block: a card id, or ' +
    'question:<board entry id>."},' +
    '"note":{"type":"string","description":"For done: the summary. For drop: ' +
    'the reason, which is required."},' +
    '"reason":{"type":"string"}' +
    '},"required":["op","id","reason"]}';
  ATools.Add(Spec, TransitionCard);

  Spec := Default(TToolSpec);
  Spec.Name := TaskEditTool;
  Spec.Description :=
    'Change a card''s title or body. Status is deliberately not editable: every '
    + 'status change is a verb with an actor, so the card can answer who moved '
    + 'it and why - use task_update for that. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"id":{"type":"integer"},' +
    '"title":{"type":"string"},' +
    '"body":{"type":"string"},' +
    '"reason":{"type":"string"}' +
    '},"required":["id","reason"]}';
  ATools.Add(Spec, EditCard);

  Spec := Default(TToolSpec);
  Spec.Name := TaskModerateTool;
  Spec.Description :=
    'Reassign a card to another session, or delete one. These take work from '
    + 'another agent mid-flight or destroy the record, so each asks the operator '
    + 'for approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"op":{"type":"string","enum":["reassign","delete"]},' +
    '"id":{"type":"integer"},' +
    '"session":{"type":"string","description":"For reassign: the session to ' +
    'give it to."},' +
    '"reason":{"type":"string"}' +
    '},"required":["op","id","reason"]}';
  ATools.Add(Spec, ModerateCard);
end;

procedure TTaskTool.Prepare;
begin
  { Nothing to reconcile: the store is fixed at construction. }
end;

function TTaskTool.Specs: TToolSpecArray;
begin
  { Registered directly through Register, not contributed per request, so the
    provider seam carries only the tail queue. }
  Result := nil;
end;

function TTaskTool.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  ATool := Default(TRegisteredTool);
  Result := False;
end;

function TTaskTool.PromptFragment: string;
var
  Err: string;
begin
  Result := QueueLine(Err);
end;

{ --- task_list --------------------------------------------------------- }

function TTaskTool.ListCards(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  F: TTaskFilter;
  Rows: TTaskCardArray;
  I: Integer;
  StatusName, Text, Holder: string;
  Status: TTaskStatus;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    F := Default(TTaskFilter);
    StatusName := Trim(Root.Get('status', ''));
    if StatusName <> '' then
    begin
      if not TaskStatusFromName(StatusName, Status) then
      begin
        AError := 'unknown status "' + StatusName + '"; use one of: ' +
          TaskStatusList;
        Exit;
      end;
      F.Status := Status;
      F.StatusSet := True;
    end;
    F.Mine := Root.Get('mine', False);
    F.MineSession := FSessionId;
    F.Parent := Root.Get('parent', 0);
    F.Limit := Root.Get('limit', 0);
    if not FStore.List(FWorkspaceId, F, Rows, AError) then
      Exit;
    if Length(Rows) = 0 then
    begin
      AResult := '(no task cards)';
      Result := True;
      Exit;
    end;
    Text := '';
    for I := 0 to High(Rows) do
    begin
      if Text <> '' then
        Text := Text + LineEnding;
      Holder := '';
      if Rows[I].ClaimedBy <> '' then
        Holder := ' · held by ' + Rows[I].ClaimedBy
      else
      begin
        { An OPEN card's author. Without this an open card and an abandoned one
          are indistinguishable, and a card someone else created looks like
          yours. ClaimedBy is live ownership; FromSession is permanent
          authorship - different facts, both worth showing. }
        if Rows[I].FromLabel <> '' then
          Holder := ' · from ' + Rows[I].FromLabel
        else if Rows[I].FromSession <> '' then
          Holder := ' · from ' + Rows[I].FromSession;
      end;
      Text := Text + '#' + IntToStr(Rows[I].Id) + ' [' +
        TaskStatusToName(Rows[I].Status) + ']' + Holder +
        LineEnding + '  ' + OneLine(Rows[I].Title);
      if Rows[I].Status = tsBlocked then
        Text := Text + LineEnding + '  blocked on ' +
          BlockerKindToName(Rows[I].BlockedOnKind) + ' #' +
          IntToStr(Rows[I].BlockedOnId);
      if Rows[I].Body <> '' then
        Text := Text + LineEnding + '  ' + OneLine(Rows[I].Body);
      if Rows[I].DoneNote <> '' then
        Text := Text + LineEnding + '  note: ' + OneLine(Rows[I].DoneNote);
    end;
    AResult := Text;
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- task_add ---------------------------------------------------------- }

function TTaskTool.AddCard(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  E: TTaskCard;
  Id, ParentId: Integer;
  Title, Err: string;
  ParentCard: TTaskCard;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    E := Default(TTaskCard);
    E.WorkspaceId := FWorkspaceId;
    E.Title := Trim(Root.Get('title', ''));
    E.Body := Root.Get('body', '');
    E.FromSession := FSessionId;
    E.FromLabel := FLabel;
    { Epoch seconds. A zero here would make the card look infinitely old to the
      work queue and make retention prune it on sight. }
    E.CreatedAt := NowEpoch;
    ParentId := Root.Get('parent', 0);
    if E.Title = '' then
    begin
      AError := 'title is required (one line: what to do)';
      Exit;
    end;
    { One level of nesting: a card with a parent may not be a parent. Checked
      here so a forged parent is refused rather than creating a tree nothing
      renders. }
    if ParentId <> 0 then
    begin
      if not Load(ParentId, ParentCard, Err) then
      begin
        AError := 'parent: ' + Err;
        Exit;
      end;
      if ParentCard.Parent <> 0 then
      begin
        AError := 'parent: card ' + IntToStr(ParentId) +
          ' is itself a subtask; nesting is one level only';
        Exit;
      end;
      E.Parent := ParentId;
    end;
    if not FStore.Add(E, Id, Err) then
    begin
      AError := Err;
      Exit;
    end;
    AResult := 'added #' + IntToStr(Id) + ' ' + OneLine(E.Title);
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- task_claim -------------------------------------------------------- }

function TTaskTool.ClaimCard(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  Id: Integer;
  Prev: TTaskCard;
  Claimed, Found: Boolean;
  Err: string;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Id := TJSONObject(D).Get('id', 0);
    if Id <= 0 then
    begin
      AError := 'id is required';
      Exit;
    end;
    Prev := Default(TTaskCard);
    if not FStore.Claim(FWorkspaceId, Id, FSessionId, Prev, Claimed, Found,
      Err) then
    begin
      AError := Err;
      Exit;
    end;
    if not Found then
    begin
      AError := 'no task card ' + IntToStr(Id) + ' in this workspace';
      Exit;
    end;
    if Claimed then
    begin
      AResult := 'claimed #' + IntToStr(Id) + ' ' + OneLine(Prev.Title);
      Result := True;
      Exit;
    end;
    { THE refusal that makes the CAS useful: name the holder and how long they
      have had it, or name the status when nobody holds it. A generic "could not
      claim" would be the same failure with none of the information. }
    if Prev.Status = tsClaimed then
    begin
      if Prev.ClaimedBy = FSessionId then
        AError := 'you already hold #' + IntToStr(Id)
      else
        AError := '#' + IntToStr(Id) + ' is held by ' + Prev.ClaimedBy +
          ' since ' + AgeLabel(Prev.ClaimedAt, NowEpoch) + ' ago';
    end
    else if Prev.Status = tsOpen then
      AError := '#' + IntToStr(Id) + ' could not be claimed'
    else if Prev.ClaimedBy <> '' then
      AError := '#' + IntToStr(Id) + ' is ' + TaskStatusToName(Prev.Status) +
        ', held by ' + Prev.ClaimedBy + ' since ' +
        AgeLabel(Prev.ClaimedAt, NowEpoch) + ' ago'
    else
      AError := '#' + IntToStr(Id) + ' is ' + TaskStatusToName(Prev.Status) +
        '; only an open card can be claimed';
  finally
    D.Free;
  end;
end;

{ --- task_update ------------------------------------------------------- }

function TTaskTool.TransitionCard(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  Op, Err, BlockedOn, Note, What: string;
  Id, BlockId, QId, P: Integer;
  Card: TTaskCard;
  Kind: TBlockerKind;
  StatusFrom, StatusTo: TTaskStatus;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    Op := Trim(Root.Get('op', ''));
    Id := Root.Get('id', 0);
    Note := Root.Get('note', '');
    if Id <= 0 then
    begin
      AError := 'id is required';
      Exit;
    end;
    if not Load(Id, Card, Err) then
    begin
      AError := Err;
      Exit;
    end;
    StatusFrom := Card.Status;
    Kind := tbkNone;
    BlockId := 0;
    { An if-chain, not a case: FPC has no case on strings. }
    if Op = 'release' then
      StatusTo := tsOpen
    else if Op = 'done' then
      StatusTo := tsDone
    else if Op = 'drop' then
    begin
      StatusTo := tsDropped;
      if Trim(Note) = '' then
      begin
        AError := 'dropping a card needs a reason in `note`';
        Exit;
      end;
    end
    else if Op = 'block' then
    begin
      StatusTo := tsBlocked;
      BlockedOn := Trim(Root.Get('blocked_on', ''));
      if BlockedOn = '' then
      begin
        AError := 'blocked_on is required: a card id, or question:<id>';
        Exit;
      end;
      { The `question:` prefix is the discriminator. An id alone cannot say
        which table it names; guessing resolves to the wrong thing the first
        time the two disagree. }
      Kind := tbkCard;
      if Pos('question:', LowerCase(BlockedOn)) = 1 then
      begin
        Kind := tbkQuestion;
        BlockedOn := Trim(Copy(BlockedOn, Length('question:') + 1,
          Length(BlockedOn)));
      end;
      P := Pos(':', BlockedOn);
      if P > 0 then
      begin
        AError := 'blocked_on: use a card id, or question:<board id>';
        Exit;
      end;
      if not TryStrToInt(BlockedOn, QId) or (QId <= 0) then
      begin
        AError := 'blocked_on: "' + BlockedOn + '" is not an id';
        Exit;
      end;
      if not ResolveBlocker(QId, Kind, What, Err) then
      begin
        AError := Err;
        Exit;
      end;
      BlockId := QId;
    end
    else if Op = 'unblock' then
      StatusTo := tsClaimed
    else
    begin
      AError := 'unknown op "' + Op +
        '"; use one of: release, block, unblock, done, drop';
      Exit;
    end;
    if not FStore.Transition(FWorkspaceId, Id, StatusFrom, StatusTo, FSessionId, BlockId,
      Kind, Note, Err) then
    begin
      AError := Err;
      Exit;
    end;
    case StatusTo of
      tsOpen: AResult := 'released #' + IntToStr(Id);
      tsDone: AResult := 'completed #' + IntToStr(Id) + ' ' + OneLine(Card.Title);
      tsDropped: AResult := 'dropped #' + IntToStr(Id) + ': ' + OneLine(Note);
      tsBlocked: AResult := 'blocked #' + IntToStr(Id) + ' on ' + What;
      tsClaimed: AResult := 'unblocked #' + IntToStr(Id) + '; still yours';
    end;
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- task_edit --------------------------------------------------------- }

function TTaskTool.EditCard(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  Id: Integer;
  Title, Body, Err: string;
  Card: TTaskCard;
  HasTitle, HasBody: Boolean;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    Id := Root.Get('id', 0);
    if Id <= 0 then
    begin
      AError := 'id is required';
      Exit;
    end;
    { A status argument is refused rather than ignored: silently doing something
      other than what was asked is how a model learns the wrong contract. }
    if Root.Find('status') <> nil then
    begin
      AError := 'status is not editable; use task_update with a verb, so the ' +
        'change records who made it and why';
      Exit;
    end;
    if not Load(Id, Card, Err) then
    begin
      AError := Err;
      Exit;
    end;
    { Only what was supplied changes; an absent field keeps its current value. }
    HasTitle := Root.Find('title') <> nil;
    HasBody := Root.Find('body') <> nil;
    if HasTitle then
      Title := Trim(Root.Get('title', ''))
    else
      Title := Card.Title;
    if HasBody then
      Body := Root.Get('body', '')
    else
      Body := Card.Body;
    if Title = '' then
    begin
      AError := 'title may not be empty';
      Exit;
    end;
    if not FStore.Edit(FWorkspaceId, Id, Title, Body, Err) then
    begin
      AError := Err;
      Exit;
    end;
    AResult := 'edited #' + IntToStr(Id) + ' ' + OneLine(Title);
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- task_moderate ----------------------------------------------------- }

function TTaskTool.ModerateCard(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  Op, Reason, Target, Err: string;
  Id: Integer;
  Card: TTaskCard;
  Prev: TTaskCard;
  Claimed, Found: Boolean;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    Reason := Root.Get('reason', '');
    if Trim(Reason) = '' then
    begin
      AError := 'a non-empty reason is required';
      Exit;
    end;
    Op := Trim(Root.Get('op', ''));
    Id := Root.Get('id', 0);
    if Id <= 0 then
    begin
      AError := 'id is required';
      Exit;
    end;
    if (Op <> 'reassign') and (Op <> 'delete') then
    begin
      AError := 'unknown op "' + Op + '"; use one of: reassign, delete';
      Exit;
    end;
    { Read first, so the operator is asked about a card that exists and the ask
      can name it. Approval before the change, never after. }
    if not Load(Id, Card, Err) then
    begin
      AError := Err;
      Exit;
    end;
    if Op = 'reassign' then
    begin
      Target := Trim(Root.Get('session', ''));
      if Target = '' then
      begin
        AError := 'reassign needs a session to give the card to';
        Exit;
      end;
      if not Allow('reassign', Card.Title,
        'to ' + Target + ': ' + Reason, Err) then
      begin
        AError := Err;
        Exit;
      end;
      { Reassign is a claim hand-off: put the card back to open, then let the
        target claim it. Each step is a guarded transition, so nothing is forged;
        an operator action (empty ABy) is used because the card may be held by
        someone who is not here to release it. }
      if Card.Status in [tsDone, tsDropped] then
      begin
        AError := '#' + IntToStr(Id) + ' is ' + TaskStatusToName(Card.Status) +
          '; a finished card cannot be reassigned';
        Exit;
      end;
      if Card.Status = tsBlocked then
      begin
        { blocked -> open is not a legal transition; unblocking goes through the
          claim first. }
        if not FStore.Transition(FWorkspaceId, Id, tsBlocked, tsClaimed, '',
          0, tbkNone, '', Err) then
        begin
          AError := Err;
          Exit;
        end;
        Prev.Status := tsClaimed;
      end
      else
        Prev := Card;
      if Prev.Status <> tsOpen then
        if not FStore.Transition(FWorkspaceId, Id, Prev.Status, tsOpen, '',
          0, tbkNone, 'reassigned to ' + Target, Err) then
        begin
          AError := Err;
          Exit;
        end;
      if not FStore.Claim(FWorkspaceId, Id, Target, Prev, Claimed, Found,
        Err) then
      begin
        AError := Err;
        Exit;
      end;
      if not Claimed then
      begin
        AError := 'released #' + IntToStr(Id) + ' to open but ' + Target +
          ' could not claim it';
        Exit;
      end;
      AResult := 'reassigned #' + IntToStr(Id) + ' to ' + Target;
      Result := True;
      Exit;
    end;
    { delete }
    if not Allow('delete', Card.Title, Reason, Err) then
    begin
      AError := Err;
      Exit;
    end;
    if not FStore.Delete(FWorkspaceId, Id, Err) then
    begin
      AError := Err;
      Exit;
    end;
    AResult := 'deleted #' + IntToStr(Id) + ' ' + OneLine(Card.Title);
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- the tail work queue ----------------------------------------------- }

function TTaskTool.QueueLine(out AError: string): string;
var
  Mine, Open: TTaskCardArray;
  Err, MinePart, OpenPart, BlockedPart, Body: string;
  I, OpenTotal: Integer;
  Now2: Int64;
  First: Boolean;
  Blocks: TTaskCardArray;
  ShowBlock: Boolean;

  { Three parts, deliberately asymmetric: `mine` is the agent's own commitment
    and is always shown; `open` names at most three; `blocked` is shown only when
    it is this session's or has gone stale. }
  function Build(AWithOpen, AWithBlocked: Boolean): string;
  begin
    Result := '<tasks';
    if MinePart <> '' then
      Result := Result + ' mine="' + MinePart + '"';
    if OpenTotal > 0 then
      Result := Result + ' open="' + IntToStr(OpenTotal) + '"';
    if AWithBlocked and (BlockedPart <> '') then
      Result := Result + ' blocked="' + BlockedPart + '"';
    Result := Result + '>';
    if AWithOpen and (OpenPart <> '') then
      Result := Result + LineEnding + '  ' + OpenPart;
    Result := Result + LineEnding + '</tasks>';
  end;

begin
  Result := '';
  AError := '';
  if FStore = nil then
    Exit;
  Now2 := NowEpoch;
  MinePart := '';
  if not FStore.Mine(FWorkspaceId, FSessionId, Mine, Err) then
  begin
    { A tail that cannot be built must not fail a turn. }
    AError := Err;
    Exit;
  end;
  First := True;
  for I := 0 to High(Mine) do
  begin
    if not First then
      MinePart := MinePart + ' · ';
    First := False;
    MinePart := MinePart + '#' + IntToStr(Mine[I].Id) + ' ' +
      OneLine(Mine[I].Title) + ' (' +
      AgeLabel(Mine[I].ClaimedAt, Now2) + ')';
  end;
  { A block is worth surfacing when it is THIS session's, or has sat longer than
    the threshold. A block nobody owns - not yours, and not yet stale - is the
    orchestrator's problem, not every agent's. Both halves need real data: the
    first from Mine, the second from every blocked card in the workspace, which
    Mine can never show. }
  BlockedPart := '';
  if FStore.BlockedCards(FWorkspaceId, 3, Blocks, Err) then
  begin
    for I := 0 to High(Blocks) do
    begin
      ShowBlock := Blocks[I].ClaimedBy = FSessionId;
      { status_at, not claimed_at: how long it has been BLOCKED is the question. }
      if not ShowBlock then
        ShowBlock := (Now2 - Blocks[I].StatusAt) >= (StaleBlockMinutes * 60);
      if not ShowBlock then
        Continue;
      if BlockedPart <> '' then
        BlockedPart := BlockedPart + ' · ';
      BlockedPart := BlockedPart + '#' + IntToStr(Blocks[I].Id) + ' on ' +
        BlockerKindToName(Blocks[I].BlockedOnKind) + ' #' +
        IntToStr(Blocks[I].BlockedOnId);
    end;
  end;
  if FStore.OpenCards(FWorkspaceId, 3, Open, Err) then
  begin
    OpenPart := '';
    for I := 0 to High(Open) do
    begin
      if OpenPart <> '' then
        OpenPart := OpenPart + ' · ';
      OpenPart := OpenPart + '#' + IntToStr(Open[I].Id) + ' ' +
        OneLine(Open[I].Title);
    end;
    { The element reports how many open cards EXIST, not how many are named: a
      backlog of forty must not look like three. OpenCards is capped, so its
      length cannot say this. }
    if FStore.OpenCount(FWorkspaceId, OpenTotal, Err) then
    begin
      if OpenTotal > Length(Open) then
        OpenPart := OpenPart + ' · +' + IntToStr(OpenTotal - Length(Open)) +
          ' more';
    end
    else
      OpenTotal := Length(Open);
  end
  else
  begin
    Open := nil;
    OpenPart := '';
    OpenTotal := 0;
  end;
  { An empty board of work contributes nothing at all. }
  if (MinePart = '') and (Length(Open) = 0) and (BlockedPart = '') then
    Exit;
  { Drop whole parts in the stated order - the open list first, then blocked -
    and never `mine`. Cut mid-attribute is unreadable; a queue with no open list
    is still actionable. }
  Body := Build(True, True);
  if Length(Body) > MaxTaskQueueBytes then
    Body := Build(False, True);
  if Length(Body) > MaxTaskQueueBytes then
    Body := Build(False, False);
  if Length(Body) > MaxTaskQueueBytes then
  begin
    { Only `mine` is left and it alone is over budget: truncate the titles, not
      the fact. }
    MinePart := '#' + IntToStr(Mine[0].Id) + ' (' +
      AgeLabel(Mine[0].ClaimedAt, Now2) + ')';
    Body := Build(False, False);
  end;
  Result := Body;
end;

end.
