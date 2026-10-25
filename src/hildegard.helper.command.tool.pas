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
  hildegard.helper.command.paths, hildegard.helper.shell.effects,
  hildegard.helper.process, hildegard.helper.workspace.changes,
  hildegard.helper.workspace.snapshot, hildegard.helper.command.pure,
  hildegard.helper.utf8;

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

{ Resolve a command argument to a workspace-RELATIVE path, or '' when it lands
  outside the root (those get their own outside-path ask).

  ComputeEffects returns paths as WRITTEN, so a relative operand has to be joined
  against the caller's cwd before it can be compared with the root. }
function ResolveCommandPath(const ACwd, ARoot, AArg: string): string;
var
  Full: string;
begin
  Result := '';
  if AArg = '' then
    Exit;
  if AArg[1] = '~' then
    Exit;                        // home is outside the workspace by definition
  if AArg[1] = '/' then
    Full := ExpandFileName(AArg)
  else if ACwd <> '' then
    Full := ExpandFileName(IncludeTrailingPathDelimiter(ACwd) + AArg)
  else if ARoot <> '' then
    { No cwd given: the tool's configured root IS the working directory. }
    Full := ExpandFileName(IncludeTrailingPathDelimiter(ARoot) + AArg)
  else
    Exit;
  Result := WorkspaceRelative(ARoot, Full);
end;

{ True when AToken appears in the effects ComputeEffects named. Used to tell a
  real operand from a token that merely CONTAINS a slash - an awk or sed program
  is not a path however many separators it has. }
function PathNamedByEffects(const AToken: string;
  const AReads, AWrites: TStringArray): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AReads) do
    if AReads[I] = AToken then
      Exit(True);
  for I := 0 to High(AWrites) do
    if AWrites[I] = AToken then
      Exit(True);
  Result := False;
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
  Bin, Ref, PathRef, Op, Rel, FileRef, CmdName: string;
  CmdArgs: TCommandArgArray;
  Access: TPathAccessArray;
  R2, W2: TStringArray;
  Known2: Boolean;
  { Grouping state: redirect effects collected by direction so one ask covers
    them all, and the segment that gets focus. }
  ReadPaths, WritePaths: TStringArray;
  FocusSeg: Integer;
  Wd: string;
  { File-scope state for the command ask, built from ComputeEffects rather than
    the path planner's heuristic - a regex containing '/' is not a directory. }
  ScopePaths: TStringArray;
  ScopeWrite, SameDir, SameExt: Boolean;
  FirstDir, FirstExt, Resolved: string;

  function OneParam(const AValue: string): TApprovalParams;
  begin
    Result := nil;
    SetLength(Result, 1);
    Result[0] := AValue;
  end;

  { A BUCKET option: a coarse grant that ignores Ref/Params and covers a whole
    effect class. Separate from AddOption because a bucket rule must leave Ref
    empty - setting it would make the rule narrow again. }
  procedure AddBucketOption(var AAsk: TApprovalAsk; const AKey, ACaption: string;
    ABucket: TApprovalBucket);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := True;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := '';
    Opt.Rule.Bucket := ABucket;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
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

  { The dialog shows the whole command and the span this ask is about. }
  procedure StampFocus(var AAsk: TApprovalAsk; ASegIndex: Integer);
  begin
    AAsk.Script := ACommand;
    if (ASegIndex >= 0) and (ASegIndex <= High(Plan.Segments)) then
    begin
      AAsk.FocusStart := Plan.Segments[ASegIndex].Start;
      AAsk.FocusLen := Plan.Segments[ASegIndex].Len;
    end;
  end;

  { Focus on the COMMAND only, excluding its redirect.

    In `echo "Test" > test.log` the read ask is about `echo "Test"`; the redirect
    belongs to the write ask. Highlighting the whole segment made the read ask
    swallow `> test.log`, so two asks described overlapping spans and neither read
    cleanly. }
  procedure StampCommandFocus(var AAsk: TApprovalAsk; ASegIndex: Integer);
  begin
    AAsk.Script := ACommand;
    if (ASegIndex >= 0) and (ASegIndex <= High(Plan.Segments)) then
    begin
      AAsk.FocusStart := Plan.Segments[ASegIndex].Start;
      AAsk.FocusLen := Plan.Segments[ASegIndex].CmdLen;
    end;
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

  { One file-effect ask covering a whole GROUP of paths, instead of one ask per
    path. The operator approving `grep a *.txt` should see ONE "read 3 files"
    dialog with scope options, not three dialogs that each resize the window.

    The options are the same vocabulary the per-path ask offered, so nothing is
    lost: exact file is meaningless for a group, so it is replaced by the scopes
    that actually generalise - same extension, same directory, both, or all. }
  procedure AppendGroupedFileAsk(const APaths: TStringArray; AWrite: Boolean);
  var
    LRef, Joined, Dirs, Exts, E: string;
    K: Integer;
    AP, FirstDir, FirstExt: string;
    SameDir, SameExt: Boolean;
  begin
    if Length(APaths) = 0 then
      Exit;
    LRef := 'file:write';
    if not AWrite then
      LRef := 'file:read';
    Ref := LRef;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Default(TApprovalAsk);
    Joined := '';
    for K := 0 to High(APaths) do
    begin
      if K > 0 then
        Joined := Joined + ', ';
      Joined := Joined + APaths[K];
    end;
    if AWrite then
      E := 'write '
    else
      E := 'read ';
    if Length(APaths) = 1 then
      Result[High(Result)].Summary := E + APaths[0]
    else
      Result[High(Result)].Summary := E + IntToStr(Length(APaths)) + ' files: ' +
        Joined;
    Result[High(Result)].Subject.Ref := LRef;
    Result[High(Result)].Subject.Path := APaths[0];
    SetLength(Result[High(Result)].Subject.Params, Length(APaths));
    for K := 0 to High(APaths) do
      Result[High(Result)].Subject.Params[K] := APaths[K];
    AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
    { The exact option names this precise set of paths - for a group it means
      "always this exact command's effects", which is what an operator grants
      after reviewing the list. }
    AddOption(Result[High(Result)], 'exact', 'always these exact files', True,
      Result[High(Result)].Subject.Params, False);
    { A group is often one directory or one extension, so offer those scopes only
      when they actually generalise - a scope option that covers nothing extra is
      just a way to grant more than asked. }
    FirstDir := DirOfRelative(APaths[0]);
    FirstExt := ExtOfRelative(APaths[0]);
    SameDir := True;
    SameExt := (FirstExt <> '');
    Dirs := '';
    Exts := '';
    for K := 0 to High(APaths) do
    begin
      AP := DirOfRelative(APaths[K]);
      if AP <> FirstDir then
        SameDir := False;
      if ExtOfRelative(APaths[K]) <> FirstExt then
        SameExt := False;
      if (AP <> '') and (Pos(#1 + AP + #1, Dirs) = 0) then
        Dirs := Dirs + #1 + AP + #1;
      if ExtOfRelative(APaths[K]) <> '' then
        Exts := Exts + #1 + ExtOfRelative(APaths[K]) + #1;
    end;
    if SameExt then
      AddFileScope(Result[High(Result)], 'ext',
        'always .' + FirstExt + ' files', '', FirstExt);
    if SameDir then
      if FirstDir = '' then
        AddFileScope(Result[High(Result)], 'dir', 'always in the workspace', '',
          '')
      else
        AddFileScope(Result[High(Result)], 'dir',
          'always in ' + FirstDir + '/', FirstDir, '');
    if SameDir and SameExt and (FirstExt <> '') then
      AddFileScope(Result[High(Result)], 'dir_ext',
        'always .' + FirstExt + ' files in ' + FirstDir + '/', FirstDir,
        FirstExt);
    { A bucket option, for the class this group belongs to. }
    if AWrite then
      Result[High(Result)].Subject.Bucket := abWrite
    else
      Result[High(Result)].Subject.Bucket := abRead;
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
  CmdName := '';
  CmdArgs := nil;
  Plan := ParseCommand(ACommand, ASyntax);
  if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
    Exit;
  for I := 0 to High(Plan.Segments) do
  begin
    Seg := Plan.Segments[I];
    if Seg.Executable = '' then
      Continue;
    { Structural words are not programs: `then cat a` is the command `cat a`,
      and a bare `fi`, `done`, `esac` or a for/case header is no command at
      all, so it must not ask. }
    if not SegmentCommand(Seg, CmdName, CmdArgs) then
      Continue;
    { A pure command needs no approval; its redirects are asked separately.
      BUT a pure command carrying a substitution is not pure in effect: its
      effects are the union of its inner commands. `echo $(cat secret.txt)` reads
      a file, so skipping it here would approve the read with no ask at all.
      This is the union rule: effect(compound) = inner U outer. }
    if IsPureCommand(ExtractFileName(CmdName)) and
       (Length(Seg.Substitutions) = 0) then
      Continue;
    Bin := ExtractFileName(CmdName);
    if Bin = '' then
      Bin := CmdName;
    Ref := 'run_command:' + Bin;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Default(TApprovalAsk);
    { The command text omits redirects; the operator needs to see them. }
    Result[High(Result)].Summary := CmdName;
    for J := 0 to High(CmdArgs) do
      Result[High(Result)].Summary := Result[High(Result)].Summary + ' ' +
        CmdArgs[J];
    { A substitution's inner command is what actually runs first, and we cannot
      execute it - but the operator must SEE it. Without this the dialog shows
      `echo ...` for `echo $(cat secret)` and the operator approves blind. }
    for J := 0 to High(Seg.Substitutions) do
      Result[High(Result)].Summary := Result[High(Result)].Summary +
        ' [runs first: ' + Seg.Substitutions[J] + ']';
    for J := 0 to High(Seg.Redirects) do
      Result[High(Result)].Summary := Result[High(Result)].Summary + ' ' +
        Seg.Redirects[J].Operator + ' ' + Seg.Redirects[J].Target;
    Result[High(Result)].Subject.Ref := Ref;
    { The bucket comes from the SAME effect classification the tier dispatches
      with, so a broad grant can never disagree with what the command actually
      does. AKnown False (tool/mcp/unknown) maps to abOpaque - deliberately not
      abNone, so an opaque command still shows up in a bucket ask rather than
      escaping one. }
    begin
      R2 := nil;
      W2 := nil;
      Known2 := False;
      ComputeEffects(Bin, CmdArgs, R2, W2, Known2);
      if not Known2 then
        Result[High(Result)].Subject.Bucket := abOpaque
      else if (Length(R2) > 0) and (Length(W2) > 0) then
        Result[High(Result)].Subject.Bucket := abReadWrite
      else if Length(W2) > 0 then
        Result[High(Result)].Subject.Bucket := abWrite
      else
        Result[High(Result)].Subject.Bucket := abRead;

      { File-scope options for the files this command NAMES.

        ComputeEffects is positional and authoritative: it knows grep's first
        operand is a pattern and awk's is a program, so a regex containing '/' is
        not mistaken for a directory. The path planner's IsPathLike heuristic is
        not used here for exactly that reason.

        Only paths INSIDE the workspace get file scopes; an outside path has its
        own ask with its own directory rule. }
      if ARoot <> '' then
      begin
        SetLength(ScopePaths, 0);
        ScopeWrite := False;
        for J := 0 to High(R2) do
        begin
          Resolved := ResolveCommandPath(ACwd, ARoot, R2[J]);
          if Resolved <> '' then
          begin
            SetLength(ScopePaths, Length(ScopePaths) + 1);
            ScopePaths[High(ScopePaths)] := Resolved;
          end;
        end;
        { A command that both reads and writes gets the WRITE scopes: granting
          read on a file it also writes would be granting less than the ask. }
        if Length(W2) > 0 then
        begin
          ScopeWrite := True;
          SetLength(ScopePaths, 0);
          for J := 0 to High(W2) do
          begin
            Resolved := ResolveCommandPath(ACwd, ARoot, W2[J]);
            if Resolved <> '' then
            begin
              SetLength(ScopePaths, Length(ScopePaths) + 1);
              ScopePaths[High(ScopePaths)] := Resolved;
            end;
          end;
        end;
        if Length(ScopePaths) > 0 then
        begin
          FirstDir := DirOfRelative(ScopePaths[0]);
          FirstExt := ExtOfRelative(ScopePaths[0]);
          SameDir := True;
          SameExt := (FirstExt <> '');
          for J := 1 to High(ScopePaths) do
          begin
            if DirOfRelative(ScopePaths[J]) <> FirstDir then
              SameDir := False;
            if ExtOfRelative(ScopePaths[J]) <> FirstExt then
              SameExt := False;
          end;
          { Only scopes that actually generalise: one covering nothing beyond the
            exact set is a way to grant more than was asked. }
          if SameExt then
            AddFileScope(Result[High(Result)], 'ext',
              'always .' + FirstExt + ' files', '', FirstExt);
          if SameDir then
            if FirstDir = '' then
              AddFileScope(Result[High(Result)], 'dir',
                'always in the workspace', '', '')
            else
              AddFileScope(Result[High(Result)], 'dir',
                'always in ' + FirstDir + '/', FirstDir, '');
          if SameDir and SameExt and (FirstExt <> '') then
            AddFileScope(Result[High(Result)], 'dir_ext',
              'always .' + FirstExt + ' files in ' + FirstDir + '/', FirstDir,
              FirstExt);
        end;
      end;
    end;
    Result[High(Result)].Subject.Params :=
      Copy(CmdArgs, 0, Length(CmdArgs));
    AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
    AddOption(Result[High(Result)], 'exact', 'always this exact command', True,
      Copy(CmdArgs, 0, Length(CmdArgs)), False);    AddOption(Result[High(Result)], 'any',
      'always ' + Bin + ' with any arguments', True, nil, True);
    if (Length(CmdArgs) > 0) and (CmdArgs[0] <> '') and
      (CmdArgs[0][1] <> '-') then
      AddOption(Result[High(Result)], 'prefix',
        'always ' + Bin + ' ' + CmdArgs[0] + ' ...', True,
        OneParam(CmdArgs[0]), True);
    { A coarse grant, offered only for the class THIS command belongs to. Showing
      both on every dialog would be clutter, and offering a bucket the command
      does not need invites granting more than asked. "Allow all reads" is what an
      operator wants on the fifth grep of a session; the granular options remain
      for when they do not. }
    case Result[High(Result)].Subject.Bucket of
      abRead:
        AddBucketOption(Result[High(Result)], 'bucket_read',
          'always allow READS (any command that only reads)', abRead);
      abWrite:
        AddBucketOption(Result[High(Result)], 'bucket_write',
          'always allow WRITES (any command that writes)', abWrite);
      abReadWrite:
        AddBucketOption(Result[High(Result)], 'bucket_rw',
          'always allow READS AND WRITES', abReadWrite);
      abOpaque, abNone, abAny:
        { No bucket: an opaque command has no known class, so a coarse grant
          would be a guess. }
        ;
    end;
    StampCommandFocus(Result[High(Result)], I);
  end;
  { A shell redirect is a file effect: here-docs and fd duplications are not
    files and are skipped; an outside target is not a file ask.

    GROUPED by direction, not one ask per path. `cmd a > x.txt b > y.txt` used to
    produce two dialogs that each resized the window; it now produces one "write
    2 files" ask with scopes that generalise. }
  if ARoot <> '' then
  begin
    Access := PathAccesses(Plan, ARoot, ACwd);
    SetLength(ReadPaths, 0);
    SetLength(WritePaths, 0);
    FocusSeg := -1;
    for J := 0 to High(Access) do
    begin
      if (not Access[J].IsRedirect) or (not Access[J].Inside) then
        Continue;
      Op := RedirectOpOf(Plan, Access[J].Segment, Access[J].Token);
      if not RedirectEffectsFile(Op) then
        Continue;
      Rel := WorkspaceRelative(ARoot, Access[J].Resolved);
      if Rel = '' then
        Continue;                     // outside the root: the path ask covers it
      if Op = '<' then
      begin
        SetLength(ReadPaths, Length(ReadPaths) + 1);
        ReadPaths[High(ReadPaths)] := Rel;
      end
      else
      begin
        SetLength(WritePaths, Length(WritePaths) + 1);
        WritePaths[High(WritePaths)] := Rel;
      end;
      if FocusSeg < 0 then
        FocusSeg := Access[J].Segment;
    end;
    if Length(ReadPaths) > 0 then
      AppendGroupedFileAsk(ReadPaths, False);
    if Length(WritePaths) > 0 then
      AppendGroupedFileAsk(WritePaths, True);
    if FocusSeg >= 0 then
      StampFocus(Result[High(Result)], FocusSeg);
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
      { A token is only a PATH if the command's own positional grammar says so.
        IsPathLike is a heuristic (any '/' in the arg), which turned an awk
        program into a directory. ComputeEffects knows where the operands are,
        so ask it instead.

        REDIRECT targets are exempt: `> /etc/passwd` names a file however it is
        spelled, and the redirect IS the evidence. The heuristic only misleads
        for plain operands. (No braces in this comment: a bare open-brace would
        close it early.) }
      if (not Access[J].IsRedirect) and
         (Access[J].Segment >= 0) and
         (Access[J].Segment <= High(Plan.Segments)) then
      begin
        R2 := nil;
        W2 := nil;
        Known2 := False;
        ComputeEffects(Plan.Segments[Access[J].Segment].Executable,
          Plan.Segments[Access[J].Segment].Arguments, R2, W2, Known2);
        if Known2 and (not PathNamedByEffects(Access[J].Token, R2, W2)) then
          Continue;
      end;
      PathRef := 'path:';
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Default(TApprovalAsk);
      Result[High(Result)].Summary := 'access outside the workspace: ' +
        Access[J].Resolved;
      Result[High(Result)].Subject.Ref := PathRef;
      Result[High(Result)].Subject.Path := Access[J].Resolved;
      StampFocus(Result[High(Result)], Access[J].Segment);
      { The path also rides Params, so an `exact` rule (ParamsEqual) can name
        this precise path. }
      SetLength(Result[High(Result)].Subject.Params, 1);
      Result[High(Result)].Subject.Params[0] := Access[J].Resolved;
      { Covers: the segment's command subject, so an exact grant suppresses. }
      { The cover is the segment's *command*, with any structural words
        stripped, so an exact grant for `cat a` also covers `then cat a`. }
      if (Access[J].Segment >= 0) and
        (Access[J].Segment <= High(Plan.Segments)) and
        SegmentCommand(Plan.Segments[Access[J].Segment], CmdName, CmdArgs) then
      begin
        Bin := ExtractFileName(CmdName);
        if Bin <> '' then
        begin
          Result[High(Result)].HasCovers := True;
          Result[High(Result)].Covers.Ref := 'run_command:' + Bin;
          Result[High(Result)].Covers.Params :=
            Copy(CmdArgs, 0, Length(CmdArgs));
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

  { Working directory: if the command changes it with cd/pushd, every ask says
    where the effects actually land. `cd /tmp && touch test.txt` writes somewhere
    the operator cannot infer from the text, and approving that blind is worse
    than not approving at all.

    Resolved against ACwd so a relative cd still shows an absolute destination.
    A cd whose target cannot be resolved is shown verbatim rather than dropped:
    the operator needs to know the directory CHANGED, even if we cannot say
    exactly where. }
  if Length(Result) > 0 then
  begin
    Wd := '';
    for J := 0 to High(Plan.Segments) do
    begin
      if not ((Plan.Segments[J].Executable = 'cd') or
              (Plan.Segments[J].Executable = 'pushd')) then
        Continue;
      if Length(Plan.Segments[J].Arguments) = 0 then
        Continue;
      if ACwd <> '' then
      begin
        { A relative cd resolves against the caller's cwd; an absolute one stands
          alone. Deliberately simple joining rather than a real resolver: the
          dialog only has to SHOW the operator where effects land. }
        if (Plan.Segments[J].Arguments[0] <> '') and
           (Plan.Segments[J].Arguments[0][1] = '/') then
          Wd := Plan.Segments[J].Arguments[0]
        else
          Wd := IncludeTrailingPathDelimiter(ACwd) +
            Plan.Segments[J].Arguments[0];
      end
      else
        Wd := Plan.Segments[J].Arguments[0];
    end;
    if Wd <> '' then
      for J := 0 to High(Result) do
        Result[J].WorkDir := Wd;
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
    { Bytes of an INCOMPLETE UTF-8 sequence at the end of the last chunk. The
      process reader hands us raw byte windows, so a multi-byte character can
      straddle two of them; forwarding the tail immediately renders it as a
      replacement character, which is what turned streamed box-drawing output
      into a row of question marks. Held here until the next chunk completes it. }
    FCarry: string;
    { True once the command finished, so a trailing carry that never completes is
      flushed rather than silently dropped. }
    FFinished: Boolean;
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
  FCarry := '';
  FFinished := False;
end;

destructor TOutputCollector.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TOutputCollector.OnOutput(const AId: string; AKind: TOutputKind;
  const AText: string; AExitCode: Integer);
var
  Send: string;
begin
  Send := '';
  FLock.Acquire;
  try
    case AKind of
      okStarted: ;
      okStdout, okStderr:
        begin
          { The split lives in hildegard.helper.utf8 where it can be tested
            directly: the process reader hands us raw byte windows, so a
            multi-byte character can straddle two chunks and forwarding the
            fragment renders it as U+FFFD. }
          Utf8SplitAtBoundary(FCarry + AText, Send, FCarry);
          FData := FData + Send;
        end;
      okFinished:
        begin
          { Flush a carry that never completed: those bytes were real, and
            dropping them would lose the tail of the output entirely. }
          if FCarry <> '' then
          begin
            Send := FCarry;
            FData := FData + Send;
            FCarry := '';
          end;
          FExit := AExitCode;
          FFinished := True;
        end;
    end;
  finally
    FLock.Release;
  end;
  { Forward outside the lock: the observer may reach a UI queue. }
  if (AKind in [okStdout, okStderr]) and (FObserver <> nil) and (Send <> '') then
    FObserver.Next(Send);
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
  { Cut on a UTF-8 boundary: a split sequence would render as a replacement
    character at the end of the live block. }
  Chunk := Utf8Prefix(AText, FRemaining);
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
  Before, After: TWorkspaceSnapshot;
  ExitCode: Integer;
  TimedOut: Boolean;
begin
  AExecution := Default(TCommandExecution);
  { A spawned command writes behind our back, so the only record is a
    before/after picture of the tree (ignore-aware). Only taken when somebody
    listens. }
  Before := nil;
  if (AChanges <> nil) and DirectoryExists(AWorkDir) then
    Before := TakeSnapshot(AWorkDir);
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
    if Before <> nil then
    begin
      try
        { Even a failed or timed-out run may have written; record what it
          managed. }
        After := TakeSnapshot(AWorkDir);
        try
          DiffSnapshots(Before, After, AChanges);
        finally
          After.Free;
        end;
      finally
        Before.Free;
      end;
    end;
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
  { SerialOnly is opt-in; a fresh spec starts false. }
  Spec := Default(TToolSpec);
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

  { A failure reads like the success shape, so the operator sees which command
    broke in the same place they see what it printed: `$ command`, a blank line,
    then the reason. Falls back to the raw arguments when the command never
    parsed out of them - "which command" is exactly the question then. }
  function InCommand(const AMsg: string): string;
  var
    Shown: string;
  begin
    if Command <> '' then
      Shown := Command
    else if AArgumentsJson <> '' then
      Shown := '(unparsed) ' + AArgumentsJson
    else
      Shown := '';
    if Shown = '' then
      Result := AMsg
    else
      Result := '$ ' + Shown + LineEnding + LineEnding + AMsg;
  end;

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
      { Show the command immediately - before any approval is asked - so the
        panel's block is never an empty box, whether the call is waiting for an
        answer, queued behind a sibling, or already running. Emitted to the
        observer directly so it is never dropped by the output cap. }
      if AObserver <> nil then
        AObserver.Next('$ ' + Command + LineEnding + LineEnding);
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
        AError := InCommand('could not parse command: ' + Plan.ParseError);
        AResult := AError;
        Exit(False);
      end;

      if FService = nil then
      begin
        AError := InCommand('no approval service configured');
        AResult := AError;
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
        AError := InCommand('the builtin shell cannot run this command: ' + Why);
        AResult := AError;
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
            AError := InCommand('approval error: ' + Batch.Reason);
        AResult := AError;
            Exit(False);
          end;
          if Batch.Denied then
          begin
            AError := InCommand(Batch.Reason);
        AResult := AError;
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
        { The set feeds the transcript note as well as OnChanges, so it is
          always collected; for the process tier that means one metadata-only
          walk of the tree before and after the call. }
        Changes := TFileChangeSet.Create;
        try
          if not FExecutor.Execute(FConfig.Shell, Command, EffectiveCwd,
            TimeoutMs, Stream, Reason, Mode, Changes, Execution) then
          begin
            AError := InCommand('failed to execute: ' + Execution.Error);
        AResult := AError;
            Exit(False);
          end;
          if (Changes <> nil) and (Changes.Count > 0) then
          begin
            { The set rides OnChanges only - the recorder stores it, and a diff
              view reads it from there. It is not rendered into AResult: what a
              call wrote is ambient context, not the command's output. }
            if Assigned(FConfig.OnChanges) then
              FConfig.OnChanges(Changes);
          end;
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
        AResult := AResult + Utf8Prefix(Execution.Output,
          FConfig.MaxOutputBytes)
      else
        AResult := AResult + Execution.Output;
      { Say so when there is nothing. A silent success (mkdir, mv, a sed -i that
        matched nothing) otherwise renders as a bare header followed by whatever
        rides the tail, and an agent cannot tell "ran, printed nothing" from
        "produced no result". }
      if Execution.Output = '' then
        AResult := AResult + '(no content)';
      if Truncated then
        AResult := AResult + LineEnding + '[output truncated at ' +
          IntToStr(FConfig.MaxOutputBytes) + ' bytes]';
      if Execution.ExitCode <> 0 then
        AResult := AResult + LineEnding + '[exit ' +
          IntToStr(Execution.ExitCode) + ']';
      { The change note is deliberately NOT part of AResult. What a call wrote is
        ambient context, not output: the operator reads a tool block to see what
        the command printed, and a `[changed: ...]` line is bookkeeping that
        belongs to the change log. The set is still delivered - OnChanges carries
        it to the recorder, which is what a diff view will read. }
      Result := True;
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      AResult := '';
      AError := InCommand('run_command error: ' + E.Message);
        AResult := AError;
      Result := False;
    end;
  end;
end;

end.
