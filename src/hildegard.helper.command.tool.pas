unit hildegard.helper.command.tool;
{ The gated shell tool. `run_command` parses a command into simple-command
  segments, asks the approval service to resolve each segment through the
  generic tool-approval whitelist, executes synchronously through an injectable
  executor (a thin wrapper over TCommandRunner), and caps the output returned to
  the model.

  The tool owns its approval granularity: for each segment it offers "once",
  "this exact command", "any arguments", and (when a non-flag prefix exists) a
  prefix-subtree option. The harness supplies the store-backed approval service
  and the operator prompt. v1 is Unix-first: the shell is a value (POSIX bash by
  default). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.command.policy, hildegard.helper.approval,
  hildegard.helper.command.paths,
  hildegard.helper.process, hildegard.helper.workspace.changes,
  hildegard.helper.command.pure;

type
  TShellProfile = record
    Executable: string;   // '/bin/bash'
    Switch: string;       // '-c'
    Syntax: TShellSyntax; // ssPosix
  end;

  { The files a call changed, delivered once per successful run. }
  TCommandChangesEvent = procedure(const AChanges: TFileChangeSet) of object;

  TCommandToolConfig = record
    Shell: TShellProfile;
    DefaultCwd: string;        // '' => process cwd
    DefaultTimeoutMs: QWord;   // 0 => ProfileDefaultTimeoutMs
    MaxTimeoutMs: QWord;       // 0 => no cap; >0 caps the model's timeout_ms
    MaxOutputBytes: Integer;   // 0 => DefaultMaxOutputBytes
    OnChanges: TCommandChangesEvent;  // nil => nobody tracks writes
  end;

  TCommandExecution = record
    Output: string;
    ExitCode: Integer;
    TimedOut: Boolean;
    Cancelled: Boolean;
    Started: Boolean;
    Error: string;
  end;

  { Execution seam. The real implementation wraps TCommandRunner; tests use a
    fake. AObserver receives the command's output as it arrives (it may be nil).
    Returns False only on infrastructure failure. }
  { Which executor the model asked for. auto picks the builtin shell when the
    whole command is supported; builtin requires it (fails rather than falling
    back); bash forces the process shell. }
  TCommandMode = (cmAuto, cmBuiltin, cmBash);

  ICommandExecutor = interface
    { True when this executor handles the whole command and raises its own
      approval asks per command (the builtin tier). The tool then must not
      pre-resolve the splitter's asks, or one command would prompt twice. A
      process executor returns False: the tool's asks are the gate. AWhy says
      why a mode cannot handle the command. }
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    { AReason is the model's reason for the call; the builtin tier inherits it
      into every approval ask. A process executor may ignore it. AChanges
      (may be nil) collects every filesystem write the call makes. }
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

  { Runs one command through TCommandRunner, streaming its output to the
    observer and collecting it for the result. }
  TProcessCommandExecutor = class(TInterfacedObject, ICommandExecutor)
  public
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    { AChanges (may be nil) collects every filesystem write the call makes. }
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

  TCommandTool = class(TInterfacedObject, IApprovableTool)
  private
    FConfig: TCommandToolConfig;
    FService: IApprovalService;
    FExecutor: ICommandExecutor;
  public
    constructor Create(const AConfig: TCommandToolConfig;
      AService: IApprovalService; AExecutor: ICommandExecutor = nil);
    { Registers run_command with the registry. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; registered by Register. Public for direct testing. }
    function Run(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { One approval ask per parsed segment (IApprovableTool). }
    function ApprovalAsks(const AArgumentsJson: string): TApprovalAskArray;
  end;

function DefaultShellProfile: TShellProfile;

const
  CommandToolName = 'run_command';
  { The default command timeout when the model does not ask for one: 5 minutes,
    long enough for real builds and installs. The model may raise it via
    timeout_ms, up to the absolute ceiling. }
  ProfileDefaultTimeoutMs = 300000;
  { The absolute ceiling. A timeout_ms above it is clamped; the attempted bypass
    is a nudge for the loop (docs/features/Tool_Limits), never a failure. }
  AbsoluteTimeoutMs = 3600000;
  DefaultMaxOutputBytes = 32768;

implementation

uses
  fpjson, jsonparser, hildegard.helper.htmlentities;

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

function ReadOptionalUInt(ARoot: TJSONObject; const AName: string;
  ADefault: QWord): QWord;
var
  D: TJSONData;
begin
  Result := ADefault;
  D := ARoot.Find(AName);
  if (D <> nil) and (D.JSONType = jtNumber) and (D.AsInt64 > 0) then
    Result := D.AsInt64;
end;

function DefaultShellProfile: TShellProfile;
begin
  Result.Executable := '/bin/bash';
  Result.Switch := '-c';
  Result.Syntax := ssPosix;
end;

{ Builds the approval ask for each parsed segment. Pure; nil on parse error. }
{ The redirect operator that produced this access, matched by target text. }
function RedirectOpOf(const APlan: TCommandPlan; ASegment: Integer;
  const AToken: string): string;
var
  I: Integer;
begin
  Result := '';
  if (ASegment < 0) or (ASegment > High(APlan.Segments)) then
    Exit;
  for I := 0 to High(APlan.Segments[ASegment].Redirects) do
    if APlan.Segments[ASegment].Redirects[I].Target = AToken then
      Exit(APlan.Segments[ASegment].Redirects[I].Operator);
end;

{ True when the operator reads or writes a file. Here-docs and here-strings
  carry a delimiter, not a path; fd duplications (`2>&1`) name an fd. }
function RedirectEffectsFile(const AOp: string): Boolean;
begin
  Result := (AOp = '<') or (AOp = '>') or (AOp = '>>') or (AOp = '>|') or
    (AOp = '2>') or (AOp = '2>>') or (AOp = '1>') or (AOp = '1>>') or
    (AOp = '&>') or (AOp = '&>>');
end;

function WorkspaceRelative(const ARoot, AResolved: string): string;
begin
  if ARoot = '/' then
    Result := Copy(AResolved, 2, MaxInt)
  else if Copy(AResolved, 1, Length(ARoot) + 1) = ARoot + '/' then
    Result := Copy(AResolved, Length(ARoot) + 2, MaxInt)
  else
    Result := '';
end;

function DirOfRelative(const ARel: string): string;
var
  P: Integer;
begin
  P := Length(ARel);
  while (P >= 1) and (ARel[P] <> '/') do
    Dec(P);
  if P <= 1 then
    Result := ''
  else
    Result := Copy(ARel, 1, P - 1);
end;

function ExtOfRelative(const ARel: string): string;
var
  Slash, Dot: Integer;
begin
  Slash := LastDelimiter('/', ARel);
  Dot := LastDelimiter('.', ARel);
  if (Dot > Slash) and (Dot > 0) and (Dot < Length(ARel)) then
    Result := LowerCase(Copy(ARel, Dot + 1, MaxInt))
  else
    Result := '';
end;

function BuildAsks(const ACommand: string;
  ASyntax: TShellSyntax; const ARoot, ACwd: string): TApprovalAskArray;
var
  Plan: TCommandPlan;
  I, J: Integer;
  Seg: TCommandSegment;
  Bin, Ref, PathRef, Op, Rel, FileRef: string;
  Access: TPathAccessArray;

  function OneParam(const AValue: string): TApprovalParams;
  begin
    Result := nil;
    SetLength(Result, 1);
    Result[0] := AValue;
  end;

  procedure AddOption(var AAsk: TApprovalAsk; const AKey, ACaption: string;
    APersists: Boolean; const AParams: TApprovalParams; AAny: Boolean);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := APersists;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := Ref;
    Opt.Rule.Params := AParams;
    Opt.Rule.AnyParams := AAny;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
  end;

  { A file-scope option: a Directory and/or Extension rule, matching how the
    file tools grant "always in dir/" and "always .ext files". }
  procedure AddFileScope(var AAsk: TApprovalAsk; const AKey, ACaption,
    ADir, AExt: string);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := True;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := Ref;
    Opt.Rule.AnyParams := True;
    Opt.Rule.Directory := ADir;
    Opt.Rule.Extension := AExt;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
  end;

  { One file-effect ask, in the file tools' shape and option vocabulary. An
    effect outside the workspace is not a file ask (the path ask covers it). }
  procedure AppendFileAsk(const AResolved: string; AWrite: Boolean);
  var
    LRel, LRef: string;
  begin
    LRel := WorkspaceRelative(ARoot, AResolved);
    if LRel = '' then
      Exit;
    if AWrite then
      LRef := 'file:write'
    else
      LRef := 'file:read';
    Ref := LRef;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Default(TApprovalAsk);
    if AWrite then
      Result[High(Result)].Summary := 'write ' + LRel
    else
      Result[High(Result)].Summary := 'read ' + LRel;
    Result[High(Result)].Subject.Ref := LRef;
    Result[High(Result)].Subject.Path := LRel;
    SetLength(Result[High(Result)].Subject.Params, 1);
    Result[High(Result)].Subject.Params[0] := LRel;
    AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
    AddOption(Result[High(Result)], 'exact', 'always this exact operation',
      True, Result[High(Result)].Subject.Params, False);
    if DirOfRelative(LRel) = '' then
      AddFileScope(Result[High(Result)], 'dir', 'always in the workspace', '',
        '')
    else
      AddFileScope(Result[High(Result)], 'dir',
        'always in ' + DirOfRelative(LRel) + '/', DirOfRelative(LRel), '');
    if AWrite and (ExtOfRelative(LRel) <> '') then
    begin
      AddFileScope(Result[High(Result)], 'ext',
        'always .' + ExtOfRelative(LRel) + ' files', '', ExtOfRelative(LRel));
      AddFileScope(Result[High(Result)], 'dir_ext',
        'always .' + ExtOfRelative(LRel) + ' files in ' +
        DirOfRelative(LRel) + '/', DirOfRelative(LRel), ExtOfRelative(LRel));
    end;
    AddOption(Result[High(Result)], 'any', 'always ' + LRef, True, nil, True);
  end;

  { A path-grant option: a Directory rule (subtree-inclusive), empty params
    with AnyParams set, so the directory is what matches. }
  procedure AddDirOption(var AAsk: TApprovalAsk; const AKey, ACaption,
    ADirectory: string);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := True;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := Ref;
    Opt.Rule.AnyParams := True;
    Opt.Rule.Directory := ADirectory;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
  end;

begin
  Result := nil;
  Plan := ParseCommand(ACommand, ASyntax);
  if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
    Exit;
  for I := 0 to High(Plan.Segments) do
  begin
    Seg := Plan.Segments[I];
    if Seg.Executable = '' then
      Continue;
    { A pure command needs no approval; its redirects are asked separately. }
    if IsPureCommand(ExtractFileName(Seg.Executable)) then
      Continue;
    Bin := ExtractFileName(Seg.Executable);
    if Bin = '' then
      Bin := Seg.Executable;
    Ref := 'run_command:' + Bin;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Default(TApprovalAsk);
    { The segment text omits redirects; the operator needs to see them. }
    Result[High(Result)].Summary := Seg.Text;
    for J := 0 to High(Seg.Redirects) do
      Result[High(Result)].Summary := Result[High(Result)].Summary + ' ' +
        Seg.Redirects[J].Operator + ' ' + Seg.Redirects[J].Target;
    Result[High(Result)].Subject.Ref := Ref;
    Result[High(Result)].Subject.Params :=
      Copy(Seg.Arguments, 0, Length(Seg.Arguments));
    AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
    AddOption(Result[High(Result)], 'exact', 'always this exact command', True,
      Copy(Seg.Arguments, 0, Length(Seg.Arguments)), False);
    AddOption(Result[High(Result)], 'any',
      'always ' + Bin + ' with any arguments', True, nil, True);
    if (Length(Seg.Arguments) > 0) and (Seg.Arguments[0] <> '') and
      (Seg.Arguments[0][1] <> '-') then
      AddOption(Result[High(Result)], 'prefix',
        'always ' + Bin + ' ' + Seg.Arguments[0] + ' ...', True,
        OneParam(Seg.Arguments[0]), True);
  end;
  { A shell redirect is a file effect: here-docs and fd duplications are not
    files and are skipped; an outside target is not a file ask. }
  if ARoot <> '' then
  begin
    Access := PathAccesses(Plan, ARoot, ACwd);
    for J := 0 to High(Access) do
    begin
      if (not Access[J].IsRedirect) or (not Access[J].Inside) then
        Continue;
      Op := RedirectOpOf(Plan, Access[J].Segment, Access[J].Token);
      if not RedirectEffectsFile(Op) then
        Continue;
      AppendFileAsk(Access[J].Resolved, Op <> '<');
    end;
  end;
  { Path asks: for each access that leaves the workspace, one ask whose subject
    is the absolute path (a distinct coordinate space from a file tool's
    relative path, so the two never cross-match). It carries Covers = the
    segment's command subject, so an EXACT command grant suppresses it. }
  if ARoot <> '' then
  begin
    Access := OutsideAccesses(Plan, ARoot, ACwd);
    for J := 0 to High(Access) do
    begin
      PathRef := 'path:';
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Default(TApprovalAsk);
      Result[High(Result)].Summary := 'access outside the workspace: ' +
        Access[J].Resolved;
      Result[High(Result)].Subject.Ref := PathRef;
      Result[High(Result)].Subject.Path := Access[J].Resolved;
      { The path also rides Params, so an `exact` rule (ParamsEqual) can name
        this precise path. }
      SetLength(Result[High(Result)].Subject.Params, 1);
      Result[High(Result)].Subject.Params[0] := Access[J].Resolved;
      { Covers: the segment's command subject, so an exact grant suppresses. }
      if Access[J].Segment <= High(Plan.Segments) then
      begin
        Bin := ExtractFileName(Plan.Segments[Access[J].Segment].Executable);
        if Bin <> '' then
        begin
          Result[High(Result)].HasCovers := True;
          Result[High(Result)].Covers.Ref := 'run_command:' + Bin;
          Result[High(Result)].Covers.Params :=
            Copy(Plan.Segments[Access[J].Segment].Arguments, 0,
              Length(Plan.Segments[Access[J].Segment].Arguments));
        end;
      end;
      { The path ask's options: once / exact / dir / any. AddOption reads the
        outer Ref, so point it at the path ref first. `exact` names this path;
        `dir` is a Directory rule (subtree-inclusive); `any` allows every
        outside path. }
      Ref := PathRef;
      AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
      AddOption(Result[High(Result)], 'exact',
        'always allow ' + Access[J].Resolved, True,
        Result[High(Result)].Subject.Params, False);
      AddDirOption(Result[High(Result)], 'dir',
        'always allow paths under ' + ExtractFileDir(Access[J].Resolved),
        ExtractFileDir(Access[J].Resolved));
      AddOption(Result[High(Result)], 'any',
        'always allow any path outside the workspace', True, nil, True);
    end;
  end;
end;

{ --- TProcessCommandExecutor -------------------------------------------- }

type
  { Collects runner output under a lock and forwards it to the observer; the
    runner callback fires on its own thread. The executor joins the runner
    before reading. }
  TOutputCollector = class
  private
    FLock: TCriticalSection;
    FObserver: TToolObserver;
    FData: string;
    FExit: Integer;
    FTimedOut: Boolean;
  public
    constructor Create(AObserver: TToolObserver);
    destructor Destroy; override;
    procedure OnOutput(const AId: string; AKind: TOutputKind;
      const AText: string; AExitCode: Integer);
    function Take(out AExit: Integer; out ATimedOut: Boolean): string;
  end;

  { Forwards chunks to an inner observer until AMaxChars characters have passed,
    then drops later ones: the live body stays bounded by the result cap even
    when a command streams without end. }
  TCappedObserver = class(TToolObserver)
  private
    FInner: TToolObserver;
    FRemaining: Integer;
  public
    constructor Create(AInner: TToolObserver; AMaxChars: Integer);
    procedure Next(const AText: string); override;
    procedure Complete; override;
  end;

constructor TOutputCollector.Create(AObserver: TToolObserver);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObserver := AObserver;
end;

destructor TOutputCollector.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TOutputCollector.OnOutput(const AId: string; AKind: TOutputKind;
  const AText: string; AExitCode: Integer);
begin
  FLock.Acquire;
  try
    case AKind of
      okStarted: ;
      okStdout, okStderr: FData := FData + AText;
      okFinished: FExit := AExitCode;
    end;
  finally
    FLock.Release;
  end;
  { Forward outside the lock: the observer may reach a UI queue. }
  if (AKind in [okStdout, okStderr]) and (FObserver <> nil) then
    FObserver.Next(AText);
end;

function TOutputCollector.Take(out AExit: Integer;
  out ATimedOut: Boolean): string;
begin
  FLock.Acquire;
  try
    Result := FData;
    AExit := FExit;
    ATimedOut := FTimedOut;
  finally
    FLock.Release;
  end;
end;

{ --- TCappedObserver ---------------------------------------------------- }

constructor TCappedObserver.Create(AInner: TToolObserver; AMaxChars: Integer);
begin
  inherited Create;
  FInner := AInner;
  FRemaining := AMaxChars;
end;

procedure TCappedObserver.Next(const AText: string);
var
  Chunk: string;
begin
  if (FInner = nil) or (FRemaining <= 0) or (AText = '') then
    Exit;
  if Length(AText) <= FRemaining then
    Chunk := AText
  else
    Chunk := Copy(AText, 1, FRemaining);
  Dec(FRemaining, Length(Chunk));
  FInner.Next(Chunk);
end;

procedure TCappedObserver.Complete;
begin
  if FInner <> nil then
    FInner.Complete;
end;

function TProcessCommandExecutor.OwnsApproval(const ACommand: string;
  AMode: TCommandMode; out AWhy: string): Boolean;
begin
  AWhy := '';
  Result := False;
end;

function TProcessCommandExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
  const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
  out AExecution: TCommandExecution): Boolean;
var
  Collector: TOutputCollector;
  Runner: TCommandRunner;
  ExitCode: Integer;
  TimedOut: Boolean;
begin
  AExecution := Default(TCommandExecution);
  Collector := TOutputCollector.Create(AObserver);
  try
    Runner := TCommandRunner.Create('cmd', ACommand, ATimeoutMs, AWorkDir,
      Collector.OnOutput, AProfile.Executable, AProfile.Switch);
    try
      Runner.Start;
      Runner.WaitFor;
      AExecution.Output := Collector.Take(ExitCode, TimedOut);
      AExecution.ExitCode := ExitCode;
      AExecution.TimedOut := TimedOut;
      AExecution.Cancelled := False;
      AExecution.Started := True;
      AExecution.Error := '';
      Result := True;
    finally
      Runner.Free;
    end;
  finally
    Collector.Free;
  end;
end;

{ --- TCommandTool ------------------------------------------------------- }

constructor TCommandTool.Create(const AConfig: TCommandToolConfig;
  AService: IApprovalService; AExecutor: ICommandExecutor);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.Shell.Executable = '' then
    FConfig.Shell := DefaultShellProfile;
  if FConfig.DefaultTimeoutMs = 0 then
    FConfig.DefaultTimeoutMs := ProfileDefaultTimeoutMs;
  if FConfig.MaxOutputBytes <= 0 then
    FConfig.MaxOutputBytes := DefaultMaxOutputBytes;
  FService := AService;
  if AExecutor = nil then
    FExecutor := TProcessCommandExecutor.Create
  else
    FExecutor := AExecutor;
end;

procedure TCommandTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := CommandToolName;
  Spec.Description :=
    'Run a shell command on the host and return its output. Requires a short ' +
    'reason. Two executors: the builtin shell runs in-process over the ' +
    'workspace (echo, cat, head, tail, wc, grep, sed, awk, find, jq, cut, tr, tee, ' +
    'printf, rg, ls, mkdir, rm, mv, cp, touch, ' +
    'sort, uniq, basename, dirname, test, [, true, false, tool, mcp) and asks ' +
    'approval once per command; /bin/bash runs everything else. Prefer ' +
    'mode="builtin" for composed file work - loops, pipelines, redirects, ' +
    'tool composition - because it is gated per command and never spawns; it ' +
    'fails rather than falling back. Use mode="bash" for real programs: git, ' +
    'sed, make, curl, builds, package managers. mode="auto" (the default) ' +
    'picks the builtin shell when the whole command is supported. Prefer a ' +
    'dedicated tool when one fits (file_read/write/edit, file_glob, file_grep, ' +
    'file_search_replace, ...): they are gated, confined to the workspace, and ' +
    'diffable. Use the shell for what no tool covers. ';
  { State where the shell starts, so the model grounds relative paths instead of
    guessing a directory (it has guessed /workspace). }
  if FConfig.DefaultCwd <> '' then
    Spec.Description := Spec.Description +
      ' The shell starts in the workspace root (' + FConfig.DefaultCwd + ').';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"command":{"type":"string","description":"Shell command to run."},' +
    '"reason":{"type":"string","description":"Short reason this command is needed."},' +
    '"cwd":{"type":"string","description":"Working directory; defaults to the ' +
    'workspace root."},' +
    '"timeout_ms":{"type":"integer","description":"Timeout in ms; omit or 0 ' +
    'for the default. Set higher for slow commands."},' +
    '"mode":{"type":"string","enum":["auto","builtin","bash"],' +
    '"description":"auto (default): the builtin shell when the whole command ' +
    'is supported, else /bin/bash. builtin: require the builtin shell; fail ' +
    'if unsupported, no fallback. bash: force /bin/bash for real programs."}' +
    '},"required":["command","reason"]}';
  ATools.Add(Spec, Run);
end;

function TCommandTool.ApprovalAsks(
  const AArgumentsJson: string): TApprovalAskArray;
var
  Data: TJSONData;
  Root: TJSONObject;
  Command, Reason, ReasonError, Cwd: string;
  I: Integer;
begin
  Result := nil;
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Exit;
    end;
    try
      if not (Data is TJSONObject) then
        Exit;
      Root := TJSONObject(Data);
      if not ReadStringArg(Root, 'command', Command) or (Trim(Command) = '') then
        Exit;
      Command := DecodeHtmlEntities(Command);
      Cwd := '';
      ReadStringArg(Root, 'cwd', Cwd);
      Result := BuildAsks(Command, FConfig.Shell.Syntax, FConfig.DefaultCwd, Cwd);
      { The reason is already in the call's arguments; carry it so the dialog
        can show why the model wants to run this. }
      Reason := '';
      ExtractToolReason(AArgumentsJson, Reason, ReasonError);
      for I := 0 to High(Result) do
        Result[I].Reason := Reason;
    finally
      Data.Free;
    end;
  except
    Result := nil;
  end;
end;

function TCommandTool.Run(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Command, Reason, Cwd, EffectiveCwd, ModeText, Why: string;
  Mode: TCommandMode;
  TimeoutMs: QWord;
  Plan: TCommandPlan;
  Asks: TApprovalAskArray;
  I: Integer;
  Batch: TApprovalBatchResult;
  Execution: TCommandExecution;
  Truncated: Boolean;
  Stream: TCappedObserver;
  Changes: TFileChangeSet;
begin
  AResult := '';
  AError := '';
  Result := False;
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
    try
      if not (Data is TJSONObject) then
      begin
        AError := 'arguments must be a JSON object';
        Exit(False);
      end;
      Root := TJSONObject(Data);

      if not ReadStringArg(Root, 'command', Command) or (Trim(Command) = '') then
      begin
        AError := 'missing required "command"';
        Exit(False);
      end;
      { The model may have written markdown-escaped text (&lt;, &gt;, &amp;);
        the shell must see the characters. }
      Command := DecodeHtmlEntities(Command);
      if not ReadStringArg(Root, 'reason', Reason) or (Trim(Reason) = '') then
      begin
        AError := 'missing required "reason"';
        Exit(False);
      end;
      ReadStringArg(Root, 'cwd', Cwd);
      Mode := cmAuto;
      if ReadStringArg(Root, 'mode', ModeText) and (Trim(ModeText) <> '') then
      begin
        if ModeText = 'auto' then
          Mode := cmAuto
        else if ModeText = 'builtin' then
          Mode := cmBuiltin
        else if ModeText = 'bash' then
          Mode := cmBash
        else
        begin
          AError := 'invalid "mode": use "auto", "builtin" or "bash"';
          Exit(False);
        end;
      end;
      TimeoutMs := ReadOptionalUInt(Root, 'timeout_ms', FConfig.DefaultTimeoutMs);
      { The model defines its own timeout. An operator may still impose a cap via
        MaxTimeoutMs (0 = none). }
      if (FConfig.MaxTimeoutMs > 0) and (TimeoutMs > FConfig.MaxTimeoutMs) then
        TimeoutMs := FConfig.MaxTimeoutMs;
      { The absolute ceiling: clamp, never fail. The advisory for an attempted
        bypass belongs to the loop (docs/features/Tool_Limits) and is not
        persisted here. }
      if TimeoutMs > AbsoluteTimeoutMs then
        TimeoutMs := AbsoluteTimeoutMs;

      Plan := ParseCommand(Command, FConfig.Shell.Syntax);
      if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
      begin
        AError := 'could not parse command: ' + Plan.ParseError;
        Exit(False);
      end;

      if FService = nil then
      begin
        AError := 'no approval service configured';
        Exit(False);
      end;
      { The builtin tier understands the whole script and raises one ask per
        command itself; asking here as well would prompt twice for one command
        (and the second prompt would never be answered). Only the process path
        uses the splitter's asks.

        mode=builtin makes that a requirement: an unsupported command fails
        here, before any ask and before anything runs. }
      if (Mode = cmBuiltin) and
        (not FExecutor.OwnsApproval(Command, Mode, Why)) then
      begin
        AError := 'the builtin shell cannot run this command: ' + Why;
        Exit(False);
      end;
      if not FExecutor.OwnsApproval(Command, Mode, Why) then
      begin
        Asks := BuildAsks(Command, FConfig.Shell.Syntax, FConfig.DefaultCwd, Cwd);
        { Carry the model's reason into the ask so the dialog can show it. }
        for I := 0 to High(Asks) do
          Asks[I].Reason := Reason;
        if Length(Asks) > 0 then
        begin
          if not FService.Resolve(Asks, Batch) then
          begin
            AError := 'approval error: ' + Batch.Reason;
            Exit(False);
          end;
          if Batch.Denied then
          begin
            AError := Batch.Reason;
            Exit(False);
          end;
        end;
      end;

      EffectiveCwd := Cwd;
      if EffectiveCwd = '' then
        EffectiveCwd := FConfig.DefaultCwd;
      { Bound the live stream to the result cap so a chatty command cannot grow
        the live block without end. }
      Stream := TCappedObserver.Create(AObserver, FConfig.MaxOutputBytes);
      try
        { Print the command first, before its output, so the operator sees what
          is about to run - especially for a long-running command. Emitted to the
          observer directly so it is never dropped by the output cap. }
        if AObserver <> nil then
          AObserver.Next('$ ' + Command + LineEnding + LineEnding);
        Changes := TFileChangeSet.Create;
        try
          if not FExecutor.Execute(FConfig.Shell, Command, EffectiveCwd,
            TimeoutMs, Stream, Reason, Mode, Changes, Execution) then
          begin
            AError := 'failed to execute: ' + Execution.Error;
            Exit(False);
          end;
          if (Changes.Count > 0) and Assigned(FConfig.OnChanges) then
            FConfig.OnChanges(Changes);
        finally
          Changes.Free;
        end;
      finally
        Stream.Free;
      end;

      { The result reads like a shell transcript: the command, a blank line,
        then its output. A non-zero exit is noted so a failure is visible
        without the panel prefixing every result with [ok]/[failed]. }
      Truncated := Length(Execution.Output) > FConfig.MaxOutputBytes;
      AResult := '$ ' + Command + LineEnding + LineEnding;
      if Truncated then
        AResult := AResult + Copy(Execution.Output, 1, FConfig.MaxOutputBytes)
      else
        AResult := AResult + Execution.Output;
      if Truncated then
        AResult := AResult + LineEnding + '[output truncated at ' +
          IntToStr(FConfig.MaxOutputBytes) + ' bytes]';
      if Execution.ExitCode <> 0 then
        AResult := AResult + LineEnding + '[exit ' +
          IntToStr(Execution.ExitCode) + ']';
      Result := True;
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      AResult := '';
      AError := 'run_command error: ' + E.Message;
      Result := False;
    end;
  end;
end;

end.
