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
  SysUtils, SyncObjs;

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
    { Path-shaped scoping (Approval Path Scoping v1). A rule with either set is a
      path grant: its params are empty with AnyParams set, and it matches only a
      subject that carries a Path. Directory is workspace-relative,
      subtree-inclusive; Extension is normalised (no leading dot, lower-case).
      '' = any. }
    Directory: string;
    Extension: string;
  end;

  TApprovalRuleArray = array of TApprovalRule;

  TApprovalSubject = record
    Ref: string;
    Params: TApprovalParams;
    { The operation's path, in the coordinate space the declaring tool owns: a
      workspace-relative path for the file tools, an absolute path (outside the
      root) for the command tool. '' = none (never matches a path rule). }
    Path: string;
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
    { True when the choice is a timeout, not an operator decision, so the
      denial can be reported as a timeout rather than a denial. }
    TimedOut: Boolean;
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
{ Normalise a directory (strip a trailing '/', a leading './'; '.' → ''). }
function NormalizeDirectory(const ADirectory: string): string;
{ Normalise an extension (strip a leading '.'; lower-case). }
function NormalizeExtension(const AExtension: string): string;
{ True when APath is ADirectory or below it, component-wise. '' dir = any. }
function PathInDirectory(const APath, ADirectory: string): Boolean;
{ True when APath's final component ends in '.' + AExtension. '' ext = any. }
function PathHasExtension(const APath, AExtension: string): Boolean;
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

  { Orchestrates matching, prompting, and persistence.

    Safe for concurrent calls (a parallel tool batch). The rule set is a shared
    snapshot guarded briefly by FDecisionLock; a caller whose subject is already
    allowed reads the snapshot and returns without ever touching FPromptLock, so
    it is not blocked by a sibling that is prompting. Prompts are serialized by
    FPromptLock (one dialog at a time), and each prompter re-checks the snapshot
    first, so a rule granted by one call is seen by the next and the operator is
    not asked twice for it. }
  TApprovalService = class(TInterfacedObject, IApprovalService)
  private
    FStore: IApprovalStore;
    FPrompt: TApprovalPrompt;
    FContext: TApprovalContext;
    FDecisionLock: TCriticalSection;
    FPromptLock: TCriticalSection;
    { The rule snapshot. Guarded by FDecisionLock for every read and write; a
      prompter never holds FDecisionLock while the prompt is up. }
    FRules: TApprovalRuleArray;
    function ApplyChoice(const ARule: TApprovalRule;
      const AChoice: TApprovalChoice; out AApplied: TApprovalRule;
      out AError: string): Boolean;
    { Decide ASubject against the current snapshot. FDecisionLock must be held. }
    function DecideLocked(const ASubject: TApprovalSubject): TApprovalDecision;
  public
    constructor Create(AStore: IApprovalStore; APrompt: TApprovalPrompt;
      const AContext: TApprovalContext);
    destructor Destroy; override;
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
  if not Result then
    Exit;
  { Path-shaped scoping: when the rule carries a directory/extension, the
    subject must carry a path that satisfies them. A rule with neither behaves
    exactly as v1. A pathless subject never matches a path rule. }
  if (ARule.Directory <> '') or (ARule.Extension <> '') then
  begin
    if ASubject.Path = '' then
      Exit(False);
    if (ARule.Directory <> '') and
      (not PathInDirectory(ASubject.Path, ARule.Directory)) then
      Exit(False);
    if (ARule.Extension <> '') and
      (not PathHasExtension(ASubject.Path, ARule.Extension)) then
      Exit(False);
  end;
end;

function NormalizeDirectory(const ADirectory: string): string;
begin
  Result := Trim(ADirectory);
  { Strip a leading './' (repeatedly) and a trailing '/'. '.' alone is the root,
    i.e. the empty directory. Backslashes are not a path separator here. }
  while (Length(Result) >= 2) and (Result[1] = '.') and (Result[2] = '/') do
    Result := Copy(Result, 3, MaxInt);
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  if Result = '.' then
    Result := '';
end;

function NormalizeExtension(const AExtension: string): string;
begin
  Result := Trim(AExtension);
  while (Length(Result) >= 1) and (Result[1] = '.') do
    Result := Copy(Result, 2, MaxInt);
  Result := LowerCase(Result);
end;

function PathInDirectory(const APath, ADirectory: string): Boolean;
var
  Dir, P: string;
begin
  if ADirectory = '' then
    Exit(True);
  Dir := NormalizeDirectory(ADirectory);
  if Dir = '' then
    Exit(True);
  P := Trim(APath);
  while (Length(P) >= 2) and (P[1] = '.') and (P[2] = '/') do
    P := Copy(P, 3, MaxInt);
  { Component-wise: the path equals the directory or continues with '/'. }
  Result := (P = Dir) or
    ((Length(P) > Length(Dir)) and (Copy(P, 1, Length(Dir)) = Dir) and
     (P[Length(Dir) + 1] = '/'));
end;

function PathHasExtension(const APath, AExtension: string): Boolean;
var
  P, Ext: string;
  Slash, Dot: Integer;
begin
  if AExtension = '' then
    Exit(True);
  Ext := NormalizeExtension(AExtension);
  P := Trim(APath);
  Slash := LastDelimiter('/', P);
  Dot := LastDelimiter('.', P);
  { The dot must be in the final component (after the last '/'), and the suffix
    must equal the extension, case-insensitively. }
  Result := (Dot > Slash) and (Dot > 0) and
    (LowerCase(Copy(P, Dot + 1, MaxInt)) = Ext);
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
  FDecisionLock := TCriticalSection.Create;
  FPromptLock := TCriticalSection.Create;
  FRules := nil;
end;

destructor TApprovalService.Destroy;
begin
  FPromptLock.Free;
  FDecisionLock.Free;
  inherited Destroy;
end;

function TApprovalService.DecideLocked(
  const ASubject: TApprovalSubject): TApprovalDecision;
begin
  Result := Decide(FRules, ASubject);
end;

function TApprovalService.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
var
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

  { Load the rule set (the store is the source of truth) and deny-first scan it.
    The lock is held only for the load + scan, never across a prompt. }
  FDecisionLock.Acquire;
  try
    if not FStore.Load(FContext, FRules, LoadErr) then
    begin
      AResult.Denied := True;
      AResult.Reason := 'approval store error: ' + LoadErr;
      Exit(False);
    end;
    for I := 0 to High(AAsks) do
      if DecideLocked(AAsks[I].Subject) = adDeny then
      begin
        AResult.Denied := True;
        AResult.Reason := 'denied by policy: ' + AAsks[I].Summary;
        Exit(True);
      end;
  finally
    FDecisionLock.Release;
  end;

  for I := 0 to High(AAsks) do
  begin
    { A fast path: an already-allowed subject returns without touching
      FPromptLock, so it is not blocked behind a sibling that is prompting. }
    FDecisionLock.Acquire;
    try
      Decision := DecideLocked(AAsks[I].Subject);
    finally
      FDecisionLock.Release;
    end;

    if Decision = adAllow then
      Continue;

    { This call must prompt. Serialize prompts so one dialog is up at a time. }
    FPromptLock.Acquire;
    try
      { Re-check against a fresh load: a sibling may have just granted a rule
        covering this subject, in which case the operator is not asked again. }
      FDecisionLock.Acquire;
      try
        FStore.Load(FContext, FRules, LoadErr);
        Decision := DecideLocked(AAsks[I].Subject);
      finally
        FDecisionLock.Release;
      end;

      if Decision = adAllow then
        Continue;

      Choice := Default(TApprovalChoice);
      if not Assigned(FPrompt) then
      begin
        AResult.Denied := True;
        AResult.Reason := 'denied: no approver available for ' +
          AAsks[I].Summary;
        Exit(True);
      end;
      Choice := FPrompt(AAsks[I]);
      if not Choice.Allowed then
      begin
        AResult.Denied := True;
        { A timeout is not an operator decision: say so, so the operator is not
          blamed for a call no one answered. }
        if Choice.TimedOut then
          AResult.Reason := 'approval timed out (no operator response): ' +
            AAsks[I].Summary
        else
          AResult.Reason := 'denied by operator: ' + AAsks[I].Summary;
        Exit(True);
      end;

      if not FindOption(AAsks[I], Choice.OptionKey, Option) then
      begin
        AResult.Denied := True;
        AResult.Reason := 'invalid approval option: ' + Choice.OptionKey;
        Exit(False);
      end;
      { Persist and publish the grant atomically under the decision lock, so a
        concurrent sibling's Load/Decide cannot race the store write. The lock
        is NOT held during the prompt above, so a no-prompt sibling still runs
        freely; only this brief section is serialized. }
      if Option.Persists then
      begin
        FDecisionLock.Acquire;
        try
          if not ApplyChoice(Option.Rule, Choice, Applied, SaveErr) then
          begin
            AResult.Denied := True;
            AResult.Reason := 'could not persist approval: ' + SaveErr;
            Exit(False);
          end;
          SetLength(FRules, Length(FRules) + 1);
          FRules[High(FRules)] := Applied;
        finally
          FDecisionLock.Release;
        end;
      end;
    finally
      FPromptLock.Release;
    end;
  end;

  AResult.Allowed := True;
  Result := True;
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

end.
