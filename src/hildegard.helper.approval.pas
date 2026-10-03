unit hildegard.helper.approval;
{ Generic, durable approval whitelist for tool calls.

  A call is described by a ref (tool identity) and an ordered params token list.
  A rule matches when the ref is equal and the params are either exactly equal or
  a prefix (when AnyParams is set, a terminal wildcard). Rules carry an effect
  (allow/deny) and a scope (global/workspace/session). Any matching deny wins;
  otherwise a matching allow at session, workspace, or global scope allows the
  call; otherwise it is asked.

  Tools own their granularity: a tool reports the asks for a call (subject,
  summary, and the options it offers). The harness supplies the store and the
  prompt, and the service persists the chosen option. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TApprovalScope = (asGlobal, asWorkspace, asSession);
  TApprovalEffect = (aeAllow, aeDeny);
  TApprovalDecision = (adAllow, adAsk, adDeny);

  TApprovalParams = array of string;

  TApprovalRule = record
    Effect: TApprovalEffect;
    Scope: TApprovalScope;
    WorkspaceId: Integer;   // 0 for global
    SessionId: string;      // '' unless session scope
    Ref: string;            // 'run_command:cat', 'browser:navigate_to_url'
    Params: TApprovalParams;
    AnyParams: Boolean;
  end;

  TApprovalRuleArray = array of TApprovalRule;

  TApprovalSubject = record
    Ref: string;
    Params: TApprovalParams;
  end;

  TApprovalOption = record
    Key: string;            // 'once', 'exact', 'any', 'prefix'
    Caption: string;
    Persists: Boolean;
    Rule: TApprovalRule;
  end;

  TApprovalOptionArray = array of TApprovalOption;

  TApprovalAsk = record
    Summary: string;
    { The model's stated reason for the call, shown in the dialog. '' when the
      tool could not read one; the dialog then shows a placeholder. }
    Reason: string;
    Subject: TApprovalSubject;
    Options: TApprovalOptionArray;
  end;

  TApprovalAskArray = array of TApprovalAsk;

  { A tool participates by reporting the approval asks for one call. }
  IApprovableTool = interface
    function ApprovalAsks(const AArgumentsJson: string): TApprovalAskArray;
  end;

  TApprovalContext = record
    WorkspaceId: Integer;
    SessionId: string;
  end;

  IApprovalStore = interface
    function Load(const AContext: TApprovalContext;
      out ARules: TApprovalRuleArray; out AError: string): Boolean;
    function Save(const ARule: TApprovalRule; out AError: string): Boolean;
    function Remove(const ARule: TApprovalRule; out AError: string): Boolean;
  end;

  TApprovalChoice = record
    Allowed: Boolean;
    OptionKey: string;      // '' when denied
    Scope: TApprovalScope;
  end;

  TApprovalPrompt = function(const AAsk: TApprovalAsk): TApprovalChoice
    of object;

  TApprovalBatchResult = record
    Allowed: Boolean;
    Denied: Boolean;
    Reason: string;
  end;

  IApprovalService = interface
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

function ApprovalMatches(const ARule: TApprovalRule;
  const ASubject: TApprovalSubject): Boolean;
function Decide(const ARules: TApprovalRuleArray;
  const ASubject: TApprovalSubject): TApprovalDecision;
function DefaultApprovalRule(const AEffect: TApprovalEffect): TApprovalRule;
function FindOption(const AAsk: TApprovalAsk; const AKey: string;
  out AOption: TApprovalOption): Boolean;

type
  { In-memory store for tests and the no-database fallback. }
  TMemoryApprovalStore = class(TInterfacedObject, IApprovalStore)
  private
    FRules: TApprovalRuleArray;
  public
    function Load(const AContext: TApprovalContext;
      out ARules: TApprovalRuleArray; out AError: string): Boolean;
    function Save(const ARule: TApprovalRule; out AError: string): Boolean;
    function Remove(const ARule: TApprovalRule; out AError: string): Boolean;
  end;

  { Orchestrates matching, prompting, and persistence. }
  TApprovalService = class(TInterfacedObject, IApprovalService)
  private
    FStore: IApprovalStore;
    FPrompt: TApprovalPrompt;
    FContext: TApprovalContext;
    function ApplyChoice(const ARule: TApprovalRule;
      const AChoice: TApprovalChoice; out AApplied: TApprovalRule;
      out AError: string): Boolean;
  public
    constructor Create(AStore: IApprovalStore; APrompt: TApprovalPrompt;
      const AContext: TApprovalContext);
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

implementation

function ParamsEqual(const A, B: TApprovalParams): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to High(A) do
      if A[I] <> B[I] then
        Exit(False);
end;

function IsPrefix(const APrefix, AFull: TApprovalParams): Boolean;
var
  I: Integer;
begin
  if Length(APrefix) > Length(AFull) then
    Exit(False);
  for I := 0 to High(APrefix) do
    if APrefix[I] <> AFull[I] then
      Exit(False);
  Result := True;
end;

function ApprovalMatches(const ARule: TApprovalRule;
  const ASubject: TApprovalSubject): Boolean;
begin
  if (ARule.Ref = '') or (ARule.Ref <> ASubject.Ref) then
    Exit(False);
  if ARule.AnyParams then
    Result := IsPrefix(ARule.Params, ASubject.Params)
  else
    Result := ParamsEqual(ARule.Params, ASubject.Params);
end;

function Decide(const ARules: TApprovalRuleArray;
  const ASubject: TApprovalSubject): TApprovalDecision;
var
  I: Integer;
  Scope: TApprovalScope;

  function AllowInScope(AScope: TApprovalScope): Boolean;
  var
    J: Integer;
  begin
    for J := 0 to High(ARules) do
      if (ARules[J].Effect = aeAllow) and (ARules[J].Scope = AScope) and
        ApprovalMatches(ARules[J], ASubject) then
        Exit(True);
    Result := False;
  end;

begin
  { Any matching deny wins. }
  for I := 0 to High(ARules) do
    if (ARules[I].Effect = aeDeny) and ApprovalMatches(ARules[I], ASubject) then
      Exit(adDeny);

  { Allow, most specific scope first. }
  for Scope := asSession downto asGlobal do
    if AllowInScope(Scope) then
      Exit(adAllow);

  Result := adAsk;
end;

function DefaultApprovalRule(const AEffect: TApprovalEffect): TApprovalRule;
begin
  Result := Default(TApprovalRule);
  Result.Effect := AEffect;
  Result.Scope := asGlobal;
end;

function FindOption(const AAsk: TApprovalAsk; const AKey: string;
  out AOption: TApprovalOption): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AAsk.Options) do
    if AAsk.Options[I].Key = AKey then
    begin
      AOption := AAsk.Options[I];
      Exit(True);
    end;
  AOption := Default(TApprovalOption);
  Result := False;
end;

{ --- TMemoryApprovalStore ----------------------------------------------- }

function RuleKey(const ARule: TApprovalRule): string;
var
  I: Integer;
begin
  Result := IntToStr(Ord(ARule.Effect)) + '|' + IntToStr(Ord(ARule.Scope)) +
    '|' + IntToStr(ARule.WorkspaceId) + '|' + ARule.SessionId + '|' +
    ARule.Ref + '|' + BoolToStr(ARule.AnyParams, True);
  for I := 0 to High(ARule.Params) do
    Result := Result + '|' + ARule.Params[I];
end;

function TMemoryApprovalStore.Load(const AContext: TApprovalContext;
  out ARules: TApprovalRuleArray; out AError: string): Boolean;
var
  I, N: Integer;
begin
  ARules := nil;
  AError := '';
  N := 0;
  SetLength(ARules, Length(FRules));
  for I := 0 to High(FRules) do
  begin
    if (FRules[I].Scope = asGlobal) or
      ((FRules[I].Scope = asWorkspace) and
        (FRules[I].WorkspaceId = AContext.WorkspaceId)) or
      ((FRules[I].Scope = asSession) and
        (FRules[I].SessionId = AContext.SessionId) and
        (AContext.SessionId <> '')) then
    begin
      ARules[N] := FRules[I];
      Inc(N);
    end;
  end;
  SetLength(ARules, N);
  Result := True;
end;

function TMemoryApprovalStore.Save(const ARule: TApprovalRule;
  out AError: string): Boolean;
var
  I: Integer;
  Key: string;
begin
  AError := '';
  Key := RuleKey(ARule);
  for I := 0 to High(FRules) do
    if RuleKey(FRules[I]) = Key then
      Exit(True);
  SetLength(FRules, Length(FRules) + 1);
  FRules[High(FRules)] := ARule;
  Result := True;
end;

function TMemoryApprovalStore.Remove(const ARule: TApprovalRule;
  out AError: string): Boolean;
var
  I, N: Integer;
  Key: string;
begin
  AError := '';
  Key := RuleKey(ARule);
  N := 0;
  for I := 0 to High(FRules) do
    if RuleKey(FRules[I]) <> Key then
    begin
      FRules[N] := FRules[I];
      Inc(N);
    end;
  SetLength(FRules, N);
  Result := True;
end;

{ --- TApprovalService ---------------------------------------------------- }

constructor TApprovalService.Create(AStore: IApprovalStore;
  APrompt: TApprovalPrompt; const AContext: TApprovalContext);
begin
  inherited Create;
  FStore := AStore;
  FPrompt := APrompt;
  FContext := AContext;
end;

function TApprovalService.ApplyChoice(const ARule: TApprovalRule;
  const AChoice: TApprovalChoice; out AApplied: TApprovalRule;
  out AError: string): Boolean;
begin
  AApplied := ARule;
  AApplied.Scope := AChoice.Scope;
  AApplied.WorkspaceId := FContext.WorkspaceId;
  AApplied.SessionId := '';
  if (AApplied.Scope = asSession) and (FContext.SessionId = '') then
    AApplied.Scope := asWorkspace;   // no session: fall back to the workspace
  if AApplied.Scope = asGlobal then
    AApplied.WorkspaceId := 0;
  if AApplied.Scope = asSession then
    AApplied.SessionId := FContext.SessionId;
  Result := FStore.Save(AApplied, AError);
end;

function TApprovalService.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
var
  Rules: TApprovalRuleArray;
  LoadErr, SaveErr: string;
  I: Integer;
  Decision: TApprovalDecision;
  Choice: TApprovalChoice;
  Option: TApprovalOption;
  Applied: TApprovalRule;
begin
  AResult := Default(TApprovalBatchResult);
  if FStore = nil then
  begin
    AResult.Denied := True;
    AResult.Reason := 'no approval store';
    Exit(False);
  end;
  if not FStore.Load(FContext, Rules, LoadErr) then
  begin
    AResult.Denied := True;
    AResult.Reason := 'approval store error: ' + LoadErr;
    Exit(False);
  end;

  { Deny-first pre-scan: never prompt when something is denied. }
  for I := 0 to High(AAsks) do
    if Decide(Rules, AAsks[I].Subject) = adDeny then
    begin
      AResult.Denied := True;
      AResult.Reason := 'denied by policy: ' + AAsks[I].Summary;
      Exit(True);
    end;

  for I := 0 to High(AAsks) do
  begin
    Decision := Decide(Rules, AAsks[I].Subject);
    if Decision = adAllow then
      Continue;

    Choice := Default(TApprovalChoice);
    if Assigned(FPrompt) then
      Choice := FPrompt(AAsks[I]);
    if not Choice.Allowed then
    begin
      AResult.Denied := True;
      AResult.Reason := 'denied by operator: ' + AAsks[I].Summary;
      Exit(True);
    end;

    if not FindOption(AAsks[I], Choice.OptionKey, Option) then
    begin
      AResult.Denied := True;
      AResult.Reason := 'invalid approval option: ' + Choice.OptionKey;
      Exit(False);
    end;
    if Option.Persists then
    begin
      if not ApplyChoice(Option.Rule, Choice, Applied, SaveErr) then
      begin
        AResult.Denied := True;
        AResult.Reason := 'could not persist approval: ' + SaveErr;
        Exit(False);
      end;
      { Make the new rule visible to later asks in this batch. }
      SetLength(Rules, Length(Rules) + 1);
      Rules[High(Rules)] := Applied;
    end;
  end;

  AResult.Allowed := True;
  Result := True;
end;

end.
