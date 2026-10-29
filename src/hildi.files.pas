unit hildi.files;
{ Approval-gated file tools for the agent: file_read, file_write, file_edit,
  file_list, file_glob, and file_grep. Mirrors TCommandTool: parse the JSON
  arguments,
  resolve approval, act, and report text (or False + error). Every path is
  resolved against the workspace root; escapes are refused.

  Containment is a guardrail, not a sandbox - the same stance as the command
  policy. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, regexpr,
  hildi.llm, hildi.agent, hildi.approval,
  hildi.workspace, hildi.workspace.changes,
  hildi.yaml, hildi.patch;

type
  { Reports what a file tool wrote, so the change log can record it.

    The file tools had NO capture path at all: TFileToolConfig carried only Root
    and two size caps, and every write went through WriteAtomic with nothing
    telling the recorder. So file_write and file_edit - the commonest way an
    agent edits - were invisible to undo, the turn summary, the diff viewer and
    revert. run_command was captured (its executor wraps the shell's FS seam in
    TChangeCollector); the file tools were not.

    Same signature as TCommandChangesEvent so the session wires one handler to
    both. }
  TFileChangesEvent = procedure(const AChanges: TFileChangeSet;
    const AToolCallId: string) of object;

  TFileToolConfig = record
    Root: string;             // workspace root; '' => process cwd
    MaxReadBytes: Integer;    // 0 => DefaultMaxReadBytes
    MaxOutputBytes: Integer;  // 0 => DefaultMaxOutputBytes (list/glob/grep)
    { nil => nobody tracks writes, which is the honest default for a caller that
      has no change log. }
    OnChanges: TFileChangesEvent;
  end;

  TFileTool = class(TInterfacedObject)
  private
    FConfig: TFileToolConfig;
    FService: IApprovalService;
    FWorkspace: TWorkspace;
    function RelOf(const AAbs: string): string;
    { Report one write to the change log, if a handler is configured. }
    procedure ReportWrite(const ARel, ABefore, AAfter: string;
      AKind: TFileChangeKind; const AToolCallId: string);
    function ResolveChecked(const ARel: string; out AAbs, AErr: string): Boolean;
    function Approve(const ARef, ASummary, AReason, APath: string;
      const AParams: TApprovalParams; out AError: string): Boolean;
    function ParseArgs(const AJson: string; out AData: TJSONData;
      out ARoot: TJSONObject; out AError: string): Boolean;
    function CapText(const AText: string; ALimit: Integer): string;
    function MaxRead: Integer;
    function MaxOutput: Integer;
  public
    constructor Create(const AConfig: TFileToolConfig;
      AService: IApprovalService);
    destructor Destroy; override;

    { Registers all six tools. }
    procedure Register(ATools: TToolRegistry);

    { Handlers (public for direct testing). Each resolves approval first. }
    function ReadFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function WriteFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function EditFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ListDir(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function Glob(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function Grep(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { File Tools v2: the first-class edit tools. }
    function AppendFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function DeleteFileOp(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function MoveFileOp(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function CopyFileOp(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function MakeDir(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function StatFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { Resolve a workspace directory to its absolute path, so the model can pass
      it to run_command's `cwd` instead of shelling `cd`. Read-only. }
    function Cwd(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ReplaceRegex(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function SearchReplace(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function JsonRead(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function JsonEdit(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function YamlRead(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function YamlEdit(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function PatchApply(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { The unified-diff applier's I/O: resolve a diff path against the workspace
      and read/write it (confined). }
    function ReadPatchFile(const APath: string; out AText: string;
      out AError: string): Boolean;
    function WritePatchFile(const APath: string; const AText: string;
      out AError: string): Boolean;
  end;

const
  DefaultMaxReadBytes = 262144;    // 256 KiB
  DefaultMaxOutputBytes = 65536;   // 64 KiB
  DefaultGrepMaxResults = 200;
  DefaultCollectLimit = 20000;

{ Glob matcher: '*' within a segment, '?' one character, '**' across segments. }
function GlobMatch(const APattern, APath: string): Boolean;

implementation

{ --- helpers ------------------------------------------------------------ }

function JsonString(ARoot: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  V: TJSONData;
begin
  AValue := '';
  V := ARoot.Find(AName);
  Result := (V <> nil) and (V.JSONType = jtString);
  if Result then
    AValue := V.AsString;
end;

function JsonBool(ARoot: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  V: TJSONData;
begin
  Result := ADefault;
  V := ARoot.Find(AName);
  if (V <> nil) and (V.JSONType = jtBoolean) then
    Result := V.AsBoolean;
end;

function JsonInt(ARoot: TJSONObject; const AName: string;
  ADefault: Integer): Integer;
var
  V: TJSONData;
begin
  Result := ADefault;
  V := ARoot.Find(AName);
  if (V <> nil) and (V.JSONType = jtNumber) then
    Result := V.AsInteger;
end;

function SplitLines(const AText: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Text := AText;
end;

function FileBytes(const APath: string): Int64;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := FS.Size;
  finally
    FS.Free;
  end;
end;

{ Reads up to AMaxBytes of a text file. ABinary is set when a NUL appears. }
function ReadTextFile(const APath: string; AMaxBytes: Integer;
  out AText: string; out ATruncated, ABinary: Boolean;
  out AError: string): Boolean;
var
  FS: TFileStream;
  Size, N: Integer;
  Buf: RawByteString;
begin
  AText := '';
  ATruncated := False;
  ABinary := False;
  AError := '';
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      AError := 'could not read ' + APath + ': ' + E.Message;
      Exit(False);
    end;
  end;
  try
    Size := FS.Size;
    N := Size;
    if N > AMaxBytes then
      N := AMaxBytes;
    SetLength(Buf, N);
    if N > 0 then
      FS.ReadBuffer(Buf[1], N);
    ATruncated := Size > AMaxBytes;
    ABinary := Pos(#0, Buf) > 0;
    AText := string(Buf);
    Result := True;
  finally
    FS.Free;
  end;
end;

{ Writes via a temporary sibling then renames, so a failure does not truncate
  an existing file. }
function WriteAtomic(const APath, AContent: string; out AError: string): Boolean;
var
  Tmp: string;
  FS: TFileStream;
begin
  AError := '';
  Tmp := APath + '.hh-tmp';
  try
    FS := TFileStream.Create(Tmp, fmCreate);
    try
      if AContent <> '' then
        FS.WriteBuffer(AContent[1], Length(AContent));
    finally
      FS.Free;
    end;
    if not RenameFile(Tmp, APath) then
    begin
      DeleteFile(Tmp);
      AError := 'could not write: ' + APath;
      Exit(False);
    end;
  except
    on E: Exception do
    begin
      DeleteFile(Tmp);
      AError := E.Message;
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure CollectInto(AList: TStringList; const ADir: string;
  ARecursive, AIncludeDirs: Boolean; ALimit: Integer);
var
  SR: TSearchRec;
  Full: string;
begin
  if AList.Count >= ALimit then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      Full := IncludeTrailingPathDelimiter(ADir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if AIncludeDirs then
          AList.Add(Full + PathDelim);
        if ARecursive then
          CollectInto(AList, Full, ARecursive, AIncludeDirs, ALimit);
      end
      else
        AList.Add(Full);
      if AList.Count >= ALimit then
        Break;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ --- glob matcher ------------------------------------------------------- }

function MatchFrom(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean; forward;

function MatchStar(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean;
var
  K: Integer;
begin
  { '**' (optionally followed by '/') crosses segments; '*' does not. }
  if (PI < Length(P)) and (P[PI + 1] = '*') then
  begin
    Inc(PI, 2);
    if (PI <= Length(P)) and (P[PI] = '/') then
      Inc(PI);
    for K := TI to Length(T) + 1 do
      if MatchFrom(P, PI, T, K) then
        Exit(True);
    Exit(False);
  end;
  for K := TI to Length(T) do
  begin
    if (K > TI) and (T[K] = '/') then
      Break;
    if MatchFrom(P, PI + 1, T, K) then
      Exit(True);
  end;
  Result := False;
end;

function MatchFrom(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean;
begin
  while PI <= Length(P) do
  begin
    if P[PI] = '*' then
      Exit(MatchStar(P, PI, T, TI));
    if TI > Length(T) then
      Exit(False);
    if (P[PI] = '?') or (P[PI] = T[TI]) then
    begin
      Inc(PI);
      Inc(TI);
    end
    else
      Exit(False);
  end;
  Result := TI > Length(T);
end;

function GlobMatch(const APattern, APath: string): Boolean;
begin
  Result := MatchFrom(APattern, 1, APath, 1);
end;

{ --- TFileTool ---------------------------------------------------------- }

constructor TFileTool.Create(const AConfig: TFileToolConfig;
  AService: IApprovalService);
var
  Err: string;
begin
  inherited Create;
  FConfig := AConfig;
  FService := AService;
  FWorkspace := TWorkspace.Open(AConfig.Root, Err);
end;

destructor TFileTool.Destroy;
begin
  FWorkspace.Free;
  inherited Destroy;
end;

function TFileTool.MaxRead: Integer;
begin
  if FConfig.MaxReadBytes > 0 then
    Result := FConfig.MaxReadBytes
  else
    Result := DefaultMaxReadBytes;
end;

function TFileTool.MaxOutput: Integer;
begin
  if FConfig.MaxOutputBytes > 0 then
    Result := FConfig.MaxOutputBytes
  else
    Result := DefaultMaxOutputBytes;
end;

function TFileTool.RelOf(const AAbs: string): string;
begin
  if FWorkspace = nil then
    Exit(AAbs);
  if AAbs = FWorkspace.Root then
    Exit('.');
  Result := Copy(AAbs, Length(FWorkspace.Root) + 2, MaxInt);
end;

procedure TFileTool.ReportWrite(const ARel, ABefore, AAfter: string;
  AKind: TFileChangeKind; const AToolCallId: string);
var
  Set_: TFileChangeSet;
  C: TFileChange;
begin
  { A file write must reach the change log, or undo, the turn summary, the diff
    viewer and revert all silently ignore it. This unit had NO reporting path
    before: only run_command was captured, via its executor's collector.

    The two texts are in hand at every caller, which is exactly what the patch
    needs - a hash alone could not produce a diff. Captured is true only when the
    after-side is readable text; BeforeCaptured only when the before-side is, and
    they are independent because a creation has no before and a deletion no
    after. }
  if not Assigned(FConfig.OnChanges) then
    Exit;
  Set_ := TFileChangeSet.Create;
  try
    C := Default(TFileChange);
    C.Path := ARel;
    C.Kind := AKind;
    C.IsDir := False;
    C.Before := ABefore;
    C.After := AAfter;
    C.BeforeSize := Length(ABefore);
    C.AfterSize := Length(AAfter);
    { A side is 'captured' when the caller passed real text for it. An empty
      string is ambiguous for a creation vs a truncated read, so the caller's
      KIND decides: a creation has no before by definition, a deletion no after. }
    C.BeforeCaptured := AKind <> fcCreated;
    C.Captured := AKind <> fcDeleted;
    Set_.Add(C);
    FConfig.OnChanges(Set_, AToolCallId);
  finally
    Set_.Free;
  end;
end;

function TFileTool.ResolveChecked(const ARel: string;
  out AAbs, AErr: string): Boolean;
var
  P: string;
begin
  AAbs := '';
  AErr := '';
  P := Trim(ARel);
  if P = '' then
  begin
    AErr := 'missing required "path"';
    Exit(False);
  end;
  if FWorkspace = nil then
  begin
    AErr := 'workspace is not available';
    Exit(False);
  end;
  if not FWorkspace.Contains(P) then
  begin
    AErr := 'path escapes the workspace: ' + P;
    Exit(False);
  end;
  { The physical check: a symlink INSIDE the workspace that points OUT can pass
    the lexical check (the link path is under the root) but resolves outside.
    PhysicalContains requires both readings to be in-bounds, closing that hole. }
  if not PhysicalContains(FWorkspace.Root, P) then
  begin
    AErr := 'path escapes the workspace (physical): ' + P;
    Exit(False);
  end;
  AAbs := FWorkspace.Resolve(P);
  Result := True;
end;

function TFileTool.ParseArgs(const AJson: string; out AData: TJSONData;
  out ARoot: TJSONObject; out AError: string): Boolean;
begin
  AData := nil;
  ARoot := nil;
  AError := '';
  try
    AData := GetJSON(AJson);
  except
    on E: Exception do
    begin
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
  end;
  if not (AData is TJSONObject) then
  begin
    FreeAndNil(AData);
    AError := 'arguments must be a JSON object';
    Exit(False);
  end;
  ARoot := TJSONObject(AData);
  Result := True;
end;

{ The model's stated reason for the call, read from its arguments. '' when the
  tool cannot read one; the dialog then shows a placeholder. }
function ToolReasonOf(const AJson: string): string;
var
  Err: string;
begin
  Result := '';
  ExtractToolReason(AJson, Result, Err);
end;

function TFileTool.Approve(const ARef, ASummary, AReason, APath: string;
  const AParams: TApprovalParams; out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;

  function DirOfPath(const P: string): string;
  var
    Slash: Integer;
  begin
    Slash := LastDelimiter('/', P);
    if Slash <= 0 then
      Result := ''
    else
      Result := Copy(P, 1, Slash - 1);
  end;

  function ExtOfPath(const P: string): string;
  var
    Slash, Dot: Integer;
  begin
    Slash := LastDelimiter('/', P);
    Dot := LastDelimiter('.', P);
    if (Dot > Slash) and (Dot > 0) and (Dot < Length(P)) then
      Result := LowerCase(Copy(P, Dot + 1, MaxInt))
    else
      Result := '';
  end;

  { A path grant: empty params with AnyParams, plus the directory/extension. }
  procedure AddPathOption(const AKey, ACaption: string; const ADir,
    AExt: string);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := True;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := ARef;
    Opt.Rule.AnyParams := True;
    Opt.Rule.Directory := ADir;
    Opt.Rule.Extension := AExt;
    SetLength(Ask.Options, Length(Ask.Options) + 1);
    Ask.Options[High(Ask.Options)] := Opt;
  end;

  procedure AddOption(const AKey, ACaption: string; APersists: Boolean;
    const AOptionParams: TApprovalParams; AAny: Boolean);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := APersists;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := ARef;
    Opt.Rule.Params := AOptionParams;
    Opt.Rule.AnyParams := AAny;
    SetLength(Ask.Options, Length(Ask.Options) + 1);
    Ask.Options[High(Ask.Options)] := Opt;
  end;

var
  Dir, Ext: string;
  WriteShaped: Boolean;
begin
  AError := '';
  if FService = nil then
  begin
    AError := 'no approval service configured';
    Exit(False);
  end;
  Ask := Default(TApprovalAsk);
  Ask.Summary := ASummary;
  Ask.Reason := AReason;
  Ask.Subject.Ref := ARef;
  Ask.Subject.Params := AParams;
  Ask.Subject.Path := APath;
  Dir := DirOfPath(APath);
  Ext := ExtOfPath(APath);
  { Extension scoping is offered for write-shaped effects only (asking "allow
    editing all .md anywhere" is meaningful; "reading all .md" is not). }
  WriteShaped := (ARef = 'file:write') or (ARef = 'file:edit');
  AddOption('once', 'allow once', False, nil, False);
  AddOption('exact', 'always this exact operation', True, AParams, False);
  if Dir = '' then
    AddPathOption('dir', 'always in the workspace', '', '')
  else
    AddPathOption('dir', 'always in ' + Dir + '/', Dir, '');
  if WriteShaped then
  begin
    AddPathOption('ext', 'always .' + Ext + ' files', '', Ext);
    AddPathOption('dir_ext', 'always .' + Ext + ' files in ' + Dir + '/',
      Dir, Ext);
  end;
  AddOption('any', 'always ' + ARef, True, nil, True);
  SetLength(Asks, 1);
  Asks[0] := Ask;
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
  Result := True;
end;

function TFileTool.CapText(const AText: string; ALimit: Integer): string;
begin
  if (ALimit > 0) and (Length(AText) > ALimit) then
    Result := Copy(AText, 1, ALimit) + LineEnding + '[truncated]'
  else
    Result := AText;
end;

{ The ':start-end' suffix for a ranged read, or '' for the whole file. }
function ReadRangeLabel(AOffset, ALimit: Integer): string;
begin
  if (AOffset <= 1) and (ALimit <= 0) then
    Result := ''
  else if ALimit > 0 then
    Result := ':' + IntToStr(AOffset) + '-' + IntToStr(AOffset + ALimit - 1)
  else
    Result := ':' + IntToStr(AOffset) + '-';
end;

{ --- file_read ---------------------------------------------------------- }

function TFileTool.ReadFile(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Text: string;
  Offset, Limit: Integer;
  Truncated, Binary: Boolean;
  Lines, OutLines: TStringList;
  I: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Lines := nil;
  OutLines := nil;
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    Offset := JsonInt(Root, 'offset', 1);
    if Offset < 1 then
      Offset := 1;
    Limit := JsonInt(Root, 'limit', 0);
    { The tool defines how its ask reads, so a ranged read says so. }
    if not Approve('file:read', 'read ' + Rel + ReadRangeLabel(Offset, Limit),
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if DirectoryExists(Abs) then
    begin
      AError := 'not a file: ' + Rel;
      Exit(False);
    end;
    if not FileExists(Abs) then
    begin
      AError := 'no such file: ' + Rel;
      Exit(False);
    end;
    if not ReadTextFile(Abs, MaxRead, Text, Truncated, Binary, AError) then
      Exit(False);
    if Binary then
    begin
      AResult := 'read ' + Rel + LineEnding + LineEnding +
        '[binary file: ' + IntToStr(FileBytes(Abs)) + ' bytes]';
      Exit(True);
    end;
    Lines := SplitLines(Text);
    OutLines := TStringList.Create;
    for I := Offset - 1 to Lines.Count - 1 do
    begin
      if (Limit > 0) and (OutLines.Count >= Limit) then
        Break;
      OutLines.Add(Lines[I]);
    end;
    { A header naming the file and its size, then the content, so the panel
      reads without the tool needing a separate call-details line. }
    AResult := 'read ' + Rel + ' (' + IntToStr(FileBytes(Abs)) + ' bytes)' +
      LineEnding + LineEnding + CapText(OutLines.Text, MaxOutput);
    if Truncated then
      AResult := AResult + LineEnding + '[truncated: file larger than ' +
        IntToStr(MaxRead) + ' bytes]';
    Result := True;
  finally
    OutLines.Free;
    Lines.Free;
    Data.Free;
  end;
end;

{ --- file_write --------------------------------------------------------- }

function TFileTool.WriteFile(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Content, Before, ReadErr: string;
  BeforeKind: TFileChangeKind;
  BeforeOk, Truncated, Binary: Boolean;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'content', Content) then
    begin
      AError := 'missing required "content"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:write', 'write ' + Rel, ToolReasonOf(AArgumentsJson),
      Rel, [Rel], AError) then
      Exit(False);
    ForceDirectories(ExtractFileDir(Abs));
    { The prior text is read BEFORE writing, so the record can carry a real diff:
      a hash alone cannot produce one, and afterwards the old bytes are gone. A
      missing file is a creation, not a failed read. }
    BeforeKind := fcCreated;
    Before := '';
    BeforeOk := False;
    if FileExists(Abs) then
    begin
      BeforeKind := fcModified;
      if ReadTextFile(Abs, MaxRead, Before, Truncated, Binary, ReadErr) then
        BeforeOk := not Binary
      else
        Before := '';
    end;
    if not WriteAtomic(Abs, Content, AError) then
      Exit(False);
    { A file that was not there is a creation; one that was is a modification. }
    if BeforeOk or FileExists(Abs) then
    begin
      if AObserver <> nil then
        ReportWrite(Rel, Before, Content, BeforeKind, AObserver.ToolCallId)
      else
        ReportWrite(Rel, Before, Content, BeforeKind, '');
    end;
    AResult := 'wrote ' + IntToStr(Length(Content)) + ' bytes to ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- file_edit ---------------------------------------------------------- }

function TFileTool.EditFile(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, OldS, NewS, Text, Updated: string;
  ReplaceAll: Boolean;
  Truncated, Binary: Boolean;
  Count, P: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'old_string', OldS) or (OldS = '') then
    begin
      AError := 'missing required "old_string"';
      Exit(False);
    end;
    if not JsonString(Root, 'new_string', NewS) then
    begin
      AError := 'missing required "new_string"';
      Exit(False);
    end;
    ReplaceAll := JsonBool(Root, 'replace_all', False);
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:edit', 'edit ' + Rel, ToolReasonOf(AArgumentsJson),
      Rel, [Rel], AError) then
      Exit(False);
    if not FileExists(Abs) then
    begin
      AError := 'no such file: ' + Rel;
      Exit(False);
    end;
    if not ReadTextFile(Abs, MaxRead, Text, Truncated, Binary, AError) then
      Exit(False);
    if Binary then
    begin
      AError := 'not a text file: ' + Rel;
      Exit(False);
    end;
    if Truncated then
    begin
      AError := 'file too large to edit: ' + Rel;
      Exit(False);
    end;

    Count := 0;
    P := 1;
    while True do
    begin
      P := Pos(OldS, Text, P);
      if P = 0 then
        Break;
      Inc(Count);
      Inc(P, Length(OldS));
    end;
    if Count = 0 then
    begin
      AError := 'old_string not found in ' + Rel;
      Exit(False);
    end;
    if (Count > 1) and not ReplaceAll then
    begin
      AError := 'old_string is not unique in ' + Rel + '; use replace_all';
      Exit(False);
    end;
    if ReplaceAll then
      Updated := StringReplace(Text, OldS, NewS, [rfReplaceAll])
    else
    begin
      P := Pos(OldS, Text);
      Updated := Copy(Text, 1, P - 1) + NewS +
        Copy(Text, P + Length(OldS), MaxInt);
    end;
    if not WriteAtomic(Abs, Updated, AError) then
      Exit(False);
    { Both texts are already in hand here - the whole point of an edit is that it
      read the old text to replace in. No re-read needed. }
    if AObserver <> nil then
      ReportWrite(Rel, Text, Updated, fcModified, AObserver.ToolCallId)
    else
      ReportWrite(Rel, Text, Updated, fcModified, '');
    AResult := 'replaced ' + IntToStr(Count) + ' occurrence(s) in ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- file_list ----------------------------------------------------------- }

function TFileTool.ListDir(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg: string;
  Recursive: Boolean;
  Entries: TStringList;
  I: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Entries := nil;
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    Recursive := JsonBool(Root, 'recursive', False);
    if not Approve('file:list', 'list ' + Rel, ToolReasonOf(AArgumentsJson),
      Rel, [Rel], AError) then
      Exit(False);
    if not DirectoryExists(Abs) then
    begin
      AError := 'not a directory: ' + Rel;
      Exit(False);
    end;
    Entries := TStringList.Create;
    CollectInto(Entries, Abs, Recursive, True, DefaultCollectLimit);
    for I := 0 to Entries.Count - 1 do
      Entries[I] := RelOf(Entries[I]);
    Entries.Sort;
    AResult := CapText(Entries.Text, MaxOutput);
    Result := True;
  finally
    Entries.Free;
    Data.Free;
  end;
end;

{ --- glob --------------------------------------------------------------- }

function TFileTool.Glob(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, Pattern, PathArg: string;
  Files, Hits: TStringList;
  I: Integer;
  Sub: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Files := nil;
  Hits := nil;
  try
    if not JsonString(Root, 'pattern', Pattern) or (Trim(Pattern) = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:glob', 'glob ' + Pattern + ' in ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Pattern, Rel], AError) then
      Exit(False);
    if not DirectoryExists(Abs) then
    begin
      AError := 'not a directory: ' + Rel;
      Exit(False);
    end;
    Files := TStringList.Create;
    Hits := TStringList.Create;
    CollectInto(Files, Abs, True, False, DefaultCollectLimit);
    for I := 0 to Files.Count - 1 do
    begin
      Sub := Copy(Files[I], Length(Abs) + 2, MaxInt);
      if GlobMatch(Pattern, Sub) then
        Hits.Add(RelOf(Files[I]));
    end;
    Hits.Sort;
    AResult := CapText(Hits.Text, MaxOutput);
    Result := True;
  finally
    Hits.Free;
    Files.Free;
    Data.Free;
  end;
end;

{ --- grep --------------------------------------------------------------- }

function TFileTool.Grep(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, Pattern, PathArg, Text, Needle, Line: string;
  IgnoreCase: Boolean;
  MaxResults, I, J, Found: Integer;
  Files, Hits, Lines: TStringList;
  Truncated, Binary: Boolean;
  SearchIn: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Files := nil;
  Hits := nil;
  try
    if not JsonString(Root, 'pattern', Pattern) or (Trim(Pattern) = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    IgnoreCase := JsonBool(Root, 'ignore_case', False);
    MaxResults := JsonInt(Root, 'max_results', 0);
    if MaxResults <= 0 then
      MaxResults := DefaultGrepMaxResults;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:grep', 'grep ' + Pattern + ' in ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Pattern, Rel], AError) then
      Exit(False);

    Files := TStringList.Create;
    Hits := TStringList.Create;
    if DirectoryExists(Abs) then
      CollectInto(Files, Abs, True, False, DefaultCollectLimit)
    else if FileExists(Abs) then
      Files.Add(Abs)
    else
    begin
      AError := 'no such file or directory: ' + Rel;
      Exit(False);
    end;

    Needle := Pattern;
    if IgnoreCase then
      Needle := UpperCase(Needle);
    Found := 0;
    for I := 0 to Files.Count - 1 do
    begin
      if Found >= MaxResults then
        Break;
      if not ReadTextFile(Files[I], MaxRead, Text, Truncated, Binary, AError)
      then
      begin
        AError := '';
        Continue;
      end;
      if Binary then
        Continue;
      Lines := SplitLines(Text);
      try
        for J := 0 to Lines.Count - 1 do
        begin
          Line := Lines[J];
          SearchIn := Line;
          if IgnoreCase then
            SearchIn := UpperCase(SearchIn);
          if Pos(Needle, SearchIn) > 0 then
          begin
            Hits.Add(RelOf(Files[I]) + ':' + IntToStr(J + 1) + ': ' + Line);
            Inc(Found);
            if Found >= MaxResults then
              Break;
          end;
        end;
      finally
        Lines.Free;
      end;
    end;
    AResult := CapText(Hits.Text, MaxOutput);
    if Found >= MaxResults then
      AResult := AResult + LineEnding + '[truncated: ' + IntToStr(MaxResults) +
        ' results]';
    Result := True;
  finally
    Hits.Free;
    Files.Free;
    Data.Free;
  end;
end;

{ --- File Tools v2: the first-class edit tools ------------------------- }

function TFileTool.AppendFile(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Content, Before, ReadErr: string;
  FS: TFileStream;
  BeforeKind: TFileChangeKind;
  BeforeOk, Truncated, Binary: Boolean;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'content', Content) then
    begin
      AError := 'missing required "content"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:write', 'append ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    ForceDirectories(ExtractFileDir(Abs));
    { The prior text, read before the append: an append's "before" is the whole
      file, so without it the record could only carry a size and the diff would
      show the entire file as added. }
    BeforeKind := fcCreated;
    Before := '';
    BeforeOk := False;
    if FileExists(Abs) then
    begin
      BeforeKind := fcModified;
      if ReadTextFile(Abs, MaxRead, Before, Truncated, Binary, ReadErr) then
        BeforeOk := not Binary;
    end;
    try
      if FileExists(Abs) then
        FS := TFileStream.Create(Abs, fmOpenReadWrite or fmShareDenyNone)
      else
        FS := TFileStream.Create(Abs, fmCreate);
      try
        FS.Seek(0, soEnd);
        if Content <> '' then
          FS.WriteBuffer(Content[1], Length(Content));
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        AError := 'could not append: ' + E.Message;
        Exit(False);
      end;
    end;
    { The change log sees an append as a modification of the whole file, which is
      what it actually is - the after-text is the old text plus the appended
      bytes, and that is what the diff must compare against. }
    if AObserver <> nil then
      ReportWrite(Rel, Before, Before + Content, BeforeKind,
        AObserver.ToolCallId)
    else
      ReportWrite(Rel, Before, Before + Content, BeforeKind, '');
    AResult := 'appended ' + IntToStr(Length(Content)) + ' bytes to ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.DeleteFileOp(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:delete', 'delete ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if DirectoryExists(Abs) then
    begin
      if not RemoveDir(Abs) then
      begin
        AError := 'could not delete directory (not empty?): ' + Rel;
        Exit(False);
      end;
    end
    else if FileExists(Abs) then
    begin
      if not DeleteFile(Abs) then
      begin
        AError := 'could not delete: ' + Rel;
        Exit(False);
      end;
    end
    else
    begin
      AError := 'no such file: ' + Rel;
      Exit(False);
    end;
    AResult := 'deleted ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.MoveFileOp(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  SrcRel, DstRel, SrcAbs, DstAbs, SrcArg, DstArg: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'from', SrcArg) or (Trim(SrcArg) = '') then
    begin
      AError := 'missing required "from"';
      Exit(False);
    end;
    if not JsonString(Root, 'to', DstArg) or (Trim(DstArg) = '') then
    begin
      AError := 'missing required "to"';
      Exit(False);
    end;
    if not ResolveChecked(SrcArg, SrcAbs, AError) then
      Exit(False);
    if not ResolveChecked(DstArg, DstAbs, AError) then
      Exit(False);
    SrcRel := RelOf(SrcAbs);
    DstRel := RelOf(DstAbs);
    if not Approve('file:move', 'move ' + SrcRel + ' to ' + DstRel,
      ToolReasonOf(AArgumentsJson), SrcRel, [SrcRel], AError) then
      Exit(False);
    ForceDirectories(ExtractFileDir(DstAbs));
    if not RenameFile(SrcAbs, DstAbs) then
    begin
      AError := 'could not move: ' + SrcRel;
      Exit(False);
    end;
    AResult := 'moved ' + SrcRel + ' to ' + DstRel;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.CopyFileOp(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  SrcRel, DstRel, SrcAbs, DstAbs, SrcArg, DstArg: string;
  Src, Dst: TFileStream;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'from', SrcArg) or (Trim(SrcArg) = '') then
    begin
      AError := 'missing required "from"';
      Exit(False);
    end;
    if not JsonString(Root, 'to', DstArg) or (Trim(DstArg) = '') then
    begin
      AError := 'missing required "to"';
      Exit(False);
    end;
    if not ResolveChecked(SrcArg, SrcAbs, AError) then
      Exit(False);
    if not ResolveChecked(DstArg, DstAbs, AError) then
      Exit(False);
    SrcRel := RelOf(SrcAbs);
    DstRel := RelOf(DstAbs);
    if not Approve('file:copy', 'copy ' + SrcRel + ' to ' + DstRel,
      ToolReasonOf(AArgumentsJson), DstRel, [DstRel], AError) then
      Exit(False);
    if not FileExists(SrcAbs) then
    begin
      AError := 'no such file: ' + SrcRel;
      Exit(False);
    end;
    ForceDirectories(ExtractFileDir(DstAbs));
    try
      Src := TFileStream.Create(SrcAbs, fmOpenRead or fmShareDenyNone);
      try
        Dst := TFileStream.Create(DstAbs, fmCreate);
        try
          Dst.CopyFrom(Src, 0);
        finally
          Dst.Free;
        end;
      finally
        Src.Free;
      end;
    except
      on E: Exception do
      begin
        AError := 'could not copy: ' + E.Message;
        Exit(False);
      end;
    end;
    AResult := 'copied ' + SrcRel + ' to ' + DstRel;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.MakeDir(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:mkdir', 'mkdir ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if not ForceDirectories(Abs) then
    begin
      AError := 'could not create directory: ' + Rel;
      Exit(False);
    end;
    AResult := 'created ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.Cwd(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:list', 'resolve dir ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if not DirectoryExists(Abs) then
    begin
      AError := 'not a directory: ' + Rel;
      Exit(False);
    end;
    { The absolute path, so the model passes it to run_command's cwd instead of
      shelling `cd`. }
    AResult := Abs;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.StatFile(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Kind: string;
  Size: Int64;
  Sr: TSearchRec;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:stat', 'stat ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if DirectoryExists(Abs) then
    begin
      Kind := 'dir';
      Size := 0;
    end
    else if FindFirst(Abs, faAnyFile, Sr) = 0 then
    begin
      Size := Sr.Size;
      if (Sr.Attr and faDirectory) <> 0 then
        Kind := 'dir'
      else
        Kind := 'file';
      FindClose(Sr);
    end
    else
    begin
      AError := 'no such path: ' + Rel;
      Exit(False);
    end;
    AResult := '{"path":"' + Rel + '","type":"' + Kind + '","size":' +
      IntToStr(Size) + '}';
    Result := True;
  finally
    Data.Free;
  end;
end;

{ Apply a regex to AText: returns the new text and the number of matches. A
  non-compiling pattern yields AError. AAll replaces every match; otherwise only
  the first (TRegExpr.Replace replaces all, so count first for the one-only
  case). }
function RegexReplace(const AText, APattern, ARepl: string; AAll, AIgnoreCase:
  Boolean; out AOut: string; out ACount: Integer; out AError: string): Boolean;
var
  RE: TRegExpr;
begin
  AOut := AText;
  ACount := 0;
  AError := '';
  RE := TRegExpr.Create;
  try
    RE.Expression := APattern;
    RE.ModifierI := AIgnoreCase;
    try
      if not RE.Exec(AText) then
        Exit(True);   { no match: unchanged, count 0 }
    except
      on E: Exception do
      begin
        AError := 'invalid regex: ' + E.Message;
        Exit(False);
      end;
    end;
    if AAll then
    begin
      ACount := 0;
      repeat
        Inc(ACount);
      until not RE.ExecNext;
      AOut := RE.Replace(AText, ARepl, True);
    end
    else
    begin
      ACount := 1;
      AOut := RE.Replace(AText, ARepl, True);
    end;
    Result := True;
  finally
    RE.Free;
  end;
end;

{ A JSON string field, or ADefault when absent. }
function JsonStringDef(ARoot: TJSONObject; const AName,
  ADefault: string): string;
begin
  if not JsonString(ARoot, AName, Result) then
    Result := ADefault;
end;

function BoolToJson(AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

{ A JSON Pointer (RFC 6901): '/' then reference tokens, each optionally
  '~1'-escaped for '/' and '~0' for '~'. '' (or '/') is the whole document.
  Returns nil when the pointer does not resolve. }
function JsonPointerFind(ARoot: TJSONData; const APointer: string): TJSONData;
var
  I, Start: Integer;
  Tok, Raw: string;
  Cur: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  Idx: Integer;
begin
  Result := ARoot;
  Cur := ARoot;
  if (APointer = '') or (APointer = '/') then
    Exit;
  I := 1;
  while I <= Length(APointer) do
  begin
    if APointer[I] = '/' then
      Inc(I);
    Start := I;
    while (I <= Length(APointer)) and (APointer[I] <> '/') do
      Inc(I);
    Raw := Copy(APointer, Start, I - Start);
    { Unescape ~1 then ~0 (order matters). }
    Tok := StringReplace(Raw, '~1', '/', [rfReplaceAll]);
    Tok := StringReplace(Tok, '~0', '~', [rfReplaceAll]);
    if Cur is TJSONObject then
    begin
      Obj := TJSONObject(Cur);
      Cur := Obj.Find(Tok);
    end
    else if Cur is TJSONArray then
    begin
      Arr := TJSONArray(Cur);
      Idx := StrToIntDef(Tok, -1);
      if (Idx >= 0) and (Idx < Arr.Count) then
        Cur := Arr.Items[Idx]
      else
        Cur := nil;
    end
    else
      Cur := nil;
    if Cur = nil then
      Exit(nil);
  end;
  Result := Cur;
end;

{ Set the value at a JSON Pointer (RFC 6901), creating no intermediate objects:
  the pointer's parent must exist and be an object. A top-level pointer ('/key')
  sets a key on the document root. Returns False with AMissing set when the
  parent does not resolve, so the caller can name the pointer rather than
  silently creating a junk key. }
function JsonPointerSet(ARoot: TJSONData; const APointer: string;
  const AValue: TJSONData; out AMissing: Boolean): Boolean;
var
  I, LastSlash, Start, Idx: Integer;
  Tok, Raw, ParentPtr: string;
  Cur: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
begin
  AMissing := False;
  Result := False;
  if not (ARoot is TJSONObject) then
    Exit;
  { Split the pointer into its parent path and final token. }
  LastSlash := 0;
  for I := 1 to Length(APointer) do
    if APointer[I] = '/' then
      LastSlash := I;
  if LastSlash < 1 then
    Exit;                       { a pointer must start with '/' }
  ParentPtr := Copy(APointer, 1, LastSlash - 1);
  Raw := Copy(APointer, LastSlash + 1, MaxInt);
  Tok := StringReplace(Raw, '~1', '/', [rfReplaceAll]);
  Tok := StringReplace(Tok, '~0', '~', [rfReplaceAll]);

  if ParentPtr = '' then
    Cur := ARoot
  else
  begin
    Cur := JsonPointerFind(ARoot, ParentPtr);
    if Cur = nil then
    begin
      AMissing := True;
      Exit;
    end;
  end;

  if Cur is TJSONObject then
  begin
    Obj := TJSONObject(Cur);
    Obj.Elements[Tok] := AValue.Clone;
    Exit(True);
  end;
  { An array index is not settable in place with the FCL's API (no Elements
    setter); treat it as a missing parent so the caller names the pointer
    rather than silently doing nothing. }
  AMissing := True;
end;

{ The directory a glob searches: everything up to the first wildcard, else '.'. }
function GlobSearchDir(const AGlob: string): string;
var
  I, LastSlash: Integer;
begin
  LastSlash := 0;
  for I := 1 to Length(AGlob) do
  begin
    if (AGlob[I] = '*') or (AGlob[I] = '?') then
      Break;
    if AGlob[I] = '/' then
      LastSlash := I;
  end;
  if LastSlash = 0 then
    Result := '.'
  else
    Result := Copy(AGlob, 1, LastSlash - 1);
  if Result = '' then
    Result := '.';
end;

{ The whole file's text, or '' if it cannot be read. }
function ReadRawFile(const APath: string): string;
var
  FS: TFileStream;
begin
  Result := '';
  if not FileExists(APath) then
    Exit;
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

function TFileTool.ReplaceRegex(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Pattern, Repl, Text, NewText, IgnoreCase: string;
  All, AllFlag: Boolean;
  Count: Integer;
  Lines: TStringList;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'pattern', Pattern) or (Pattern = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'replacement', Repl) then
    begin
      AError := 'missing required "replacement"';
      Exit(False);
    end;
    AllFlag := JsonBool(Root, 'all', True);
    IgnoreCase := LowerCase(JsonStringDef(Root, 'flags', ''));
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    if not FileExists(Abs) then
    begin
      AError := 'no such file: ' + RelOf(Abs);
      Exit(False);
    end;
    Rel := RelOf(Abs);
    if not Approve('file:edit', 'regex-replace ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Text := ReadRawFile(Abs);
    if not RegexReplace(Text, Pattern, Repl, AllFlag,
      Pos('i', IgnoreCase) > 0, NewText, Count, AError) then
      Exit(False);
    if Count > 0 then
    begin
      if not WriteAtomic(Abs, NewText, AError) then
        Exit(False);
      { Both texts are in hand: ReadRawFile gave the before, RegexReplace the
        after. Reporting here is what keeps a regex-replace visible to undo. }
      if AObserver <> nil then
        ReportWrite(Rel, Text, NewText, fcModified, AObserver.ToolCallId)
      else
        ReportWrite(Rel, Text, NewText, fcModified, '');
    end;
    AResult := '{"replaced":' + IntToStr(Count) + ',"path":"' + Rel + '"}';
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.SearchReplace(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, DirArg, Pattern, Repl, IgnoreCase: string;
  AllFlag, DryRun: Boolean;
  Files: TStringList;
  I, Total, Count: Integer;
  Text, NewText: string;
  Paths: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Files := nil;
  try
    if not JsonString(Root, 'pattern', Pattern) or (Pattern = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'replacement', Repl) then
    begin
      AError := 'missing required "replacement"';
      Exit(False);
    end;
    AllFlag := JsonBool(Root, 'all', True);
    DryRun := JsonBool(Root, 'dryRun', False);
    IgnoreCase := LowerCase(JsonStringDef(Root, 'flags', ''));
    { The glob selects files; the directory scopes the ask. A pattern with a '/'
      is resolved as a path under the workspace. }
    if not JsonString(Root, 'glob', DirArg) or (Trim(DirArg) = '') then
      DirArg := '.';
    { The directory to search is the glob's leading directory (up to the first
      wildcard), else '.'; the ask scopes on it. }
    Rel := GlobSearchDir(DirArg);
    if not ResolveChecked(Rel, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:edit', 'search-replace in ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Files := TStringList.Create;
    { Collect from the workspace root so the glob (workspace-relative) matches
      the whole path, not just the searched subdirectory. }
    CollectInto(Files, FWorkspace.Root, True, False, DefaultCollectLimit);
    Total := 0;
    Paths := '';
    for I := 0 to Files.Count - 1 do
    begin
      if not GlobMatch(DirArg, RelOf(Files[I])) then
        Continue;
      Text := ReadRawFile(Files[I]);
      if not RegexReplace(Text, Pattern, Repl, AllFlag,
        Pos('i', IgnoreCase) > 0, NewText, Count, AError) then
        Exit(False);
      if Count = 0 then
        Continue;
      Inc(Total, Count);
      if Paths <> '' then
        Paths := Paths + ',';
      Paths := Paths + '"' + RelOf(Files[I]) + '"';
      if not DryRun then
      begin
        if not WriteAtomic(Files[I], NewText, AError) then
          Exit(False);
        { A dry run writes nothing, so it reports nothing - which is why this
          sits inside the guard. }
        if AObserver <> nil then
          ReportWrite(RelOf(Files[I]), Text, NewText, fcModified,
            AObserver.ToolCallId)
        else
          ReportWrite(RelOf(Files[I]), Text, NewText, fcModified, '');
      end;
    end;
    AResult := '{"files":[' + Paths + '],"replacements":' + IntToStr(Total) +
      ',"dryRun":' + BoolToJson(DryRun) + '}';
    Result := True;
  finally
    Files.Free;
    Data.Free;
  end;
end;

function TFileTool.JsonRead(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Pointer, Text: string;
  Doc, Found: TJSONData;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:read', 'read json ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Text := ReadRawFile(Abs);
    if Text = '' then
    begin
      AError := 'could not read (or empty): ' + Rel;
      Exit(False);
    end;
    Doc := nil;
    try
      try
        Doc := GetJSON(Text);
      except
        on E: Exception do
        begin
          AError := 'invalid JSON: ' + E.Message;
          Exit(False);
        end;
      end;
      if JsonString(Root, 'pointer', Pointer) and (Pointer <> '') then
      begin
        Found := JsonPointerFind(Doc, Pointer);
        if Found = nil then
        begin
          AError := 'pointer not found: ' + Pointer;
          Exit(False);
        end;
        AResult := Found.AsJSON;
      end
      else
        AResult := Doc.AsJSON;
      Result := True;
    finally
      Doc.Free;
    end;
  finally
    Data.Free;
  end;
end;

function TFileTool.JsonEdit(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Pointer, Text: string;
  Doc, Value: TJSONData;
  Existing: TJSONData;
  Missing: Boolean;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'pointer', Pointer) or (Pointer = '') then
    begin
      AError := 'missing required "pointer"';
      Exit(False);
    end;
    { Both json_read and json_edit take an RFC 6901 pointer, so the same
      '/a/b' form means the same thing. A bare key is rejected rather than
      treated as a top-level name — that silent reading is what made the two
      tools diverge. }
    if Pointer[1] <> '/' then
    begin
      AError := 'pointer must be a JSON pointer starting with "/" ' +
        '(e.g. /service/port), got: ' + Pointer;
      Exit(False);
    end;
    Value := Root.Find('value');
    if Value = nil then
    begin
      AError := 'missing required "value"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:write', 'edit json ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Text := ReadRawFile(Abs);
    Doc := nil;
    try
      try
        Doc := GetJSON(Text);
      except
        on E: Exception do
        begin
          { A parse failure never writes. }
          AError := 'invalid JSON (not written): ' + E.Message;
          Exit(False);
        end;
      end;
      { Set the value at the pointer. The parent must already exist, so a typo
        is an error rather than a silently-created junk key; and because both
        json_read and json_edit take the same '/a/b' form, the pointer means one
        thing across the pair. }
      if not JsonPointerSet(Doc, Pointer, Value, Missing) then
      begin
        if Missing then
        begin
          AError := 'pointer not found: ' + Pointer;
          Exit(False);
        end;
        AError := 'could not set the pointer: ' + Pointer;
        Exit(False);
      end;
      if not WriteAtomic(Abs, TJSONObject(Doc).FormatJSON + #10, AError) then
        Exit(False);
      AResult := '{"written":true,"path":"' + Rel + '"}';
      Result := True;
    finally
      Doc.Free;
    end;
  finally
    Data.Free;
  end;
end;

function TFileTool.YamlRead(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Text: string;
  Doc, Found: TJSONData;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:read', 'read yaml ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Text := ReadRawFile(Abs);
    Doc := ParseYaml(Text, AError);
    if Doc = nil then
    begin
      AError := 'invalid YAML: ' + AError;
      Exit(False);
    end;
    try
      AResult := Doc.AsJSON;
      Result := True;
    finally
      Doc.Free;
    end;
  finally
    Data.Free;
  end;
end;

function TFileTool.YamlEdit(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, YamlPath, Text, NewText: string;
  Value: TJSONData;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'key', YamlPath) or (YamlPath = '') then
    begin
      AError := 'missing required "key" (a dotted path)';
      Exit(False);
    end;
    Value := Root.Find('value');
    if Value = nil then
    begin
      AError := 'missing required "value"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:write', 'edit yaml ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    Text := ReadRawFile(Abs);
    NewText := SetYamlPath(Text, YamlPath, Value, AError);
    if NewText = '' then
    begin
      AError := 'invalid YAML (not written): ' + AError;
      Exit(False);
    end;
    if not WriteAtomic(Abs, NewText, AError) then
      Exit(False);
    AResult := '{"written":true,"path":"' + Rel + '"}';
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.PatchApply(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Patch, Rel, Abs, PathArg: string;
  DryRun: Boolean;
  Strip: Integer;
  Pr: TPatchResult;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'patch', Patch) or (Patch = '') then
    begin
      AError := 'missing required "patch"';
      Exit(False);
    end;
    DryRun := JsonBool(Root, 'dryRun', False);
    Strip := JsonInt(Root, 'strip', 1);
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:edit', 'apply patch in ' + Rel,
      ToolReasonOf(AArgumentsJson), Rel, [Rel], AError) then
      Exit(False);
    if not ApplyUnifiedPatch(Patch, Strip, DryRun, ReadPatchFile,
      WritePatchFile, Pr, AError) then
      Exit(False);
    AResult := '{"applied":' + IntToStr(Pr.Applied) + ',"rejected":' +
      IntToStr(Pr.Rejected) + ',"dryRun":' + BoolToJson(DryRun) + '}';
    Result := True;
  finally
    Data.Free;
  end;
end;

function TFileTool.ReadPatchFile(const APath: string; out AText: string;
  out AError: string): Boolean;
var
  Abs: string;
begin
  AText := '';
  AError := '';
  if not ResolveChecked(APath, Abs, AError) then
    Exit(False);
  if not FileExists(Abs) then
  begin
    AError := 'no such file: ' + APath;
    Exit(False);
  end;
  AText := ReadRawFile(Abs);
  Result := True;
end;

function TFileTool.WritePatchFile(const APath: string; const AText: string;
  out AError: string): Boolean;
var
  Abs: string;
begin
  AError := '';
  if not ResolveChecked(APath, Abs, AError) then
    Exit(False);
  ForceDirectories(ExtractFileDir(Abs));
  Result := WriteAtomic(Abs, AText, AError);
end;

procedure TFileTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  { SerialOnly is opt-in: start from a fresh spec so a tool that does not set
    it (the read-only ones below) is parallel-safe instead of inheriting stack
    garbage - a file read marked serial would hold up a whole batch. }
  Spec := Default(TToolSpec);
  Spec.Name := 'file_read';
  Spec.Description := 'Read a text file inside the workspace (with an optional line range). ' +
    'Prefer this over the shell: cat, head, tail, sed -n. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"offset":{"type":"integer","description":"First line to return (1-based)."},' +
    '"limit":{"type":"integer","description":"Maximum lines to return (0 = all)."},' +
    '"reason":{"type":"string","description":"Short reason this read is needed."}' +
    '},"required":["path","reason"]}';
  ATools.Add(Spec, ReadFile);

  Spec.Name := 'file_write';
  Spec.Description := 'Create or overwrite a file inside the workspace. ' +
    'Prefer this over the shell: cat > f, printf > f, tee. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"content":{"type":"string","description":"Full file content to write."},' +
    '"reason":{"type":"string","description":"Short reason this write is needed."}' +
    '},"required":["path","content","reason"]}';
  ATools.Add(Spec, WriteFile);

  Spec.Name := 'file_edit';
  Spec.Description := 'Replace an exact string in a file inside the workspace. ' +
    'Fails if the string is absent or ambiguous (unless replace_all). ' +
    'Prefer this over the shell: ed, ex, a small sed. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"old_string":{"type":"string","description":"Exact text to replace."},' +
    '"new_string":{"type":"string","description":"Replacement text."},' +
    '"replace_all":{"type":"boolean","description":"Replace every occurrence."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["path","old_string","new_string","reason"]}';
  ATools.Add(Spec, EditFile);

  Spec.Name := 'file_list';
  Spec.Description := 'List directory entries inside the workspace. ' +
    'Prefer this over the shell: ls, find. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Directory relative to the workspace."},' +
    '"recursive":{"type":"boolean","description":"Descend into subdirectories."},' +
    '"reason":{"type":"string","description":"Short reason this listing is needed."}' +
    '},"required":["reason"]}';
  ATools.Add(Spec, ListDir);

  Spec.Name := 'file_glob';
  Spec.Description := 'Find files by path pattern (*, ?, **) inside the ' +
    'workspace. Prefer this over the shell: find -name, shell globs. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"pattern":{"type":"string","description":"Glob pattern, e.g. src/**/*.pas."},' +
    '"path":{"type":"string","description":"Directory to search (default .)."},' +
    '"reason":{"type":"string","description":"Short reason this search is needed."}' +
    '},"required":["pattern","reason"]}';
  ATools.Add(Spec, Glob);

  Spec.Name := 'file_grep';
  Spec.Description := 'Search file contents for a substring inside the ' +
    'workspace. Prefer this over the shell: grep, rg. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"pattern":{"type":"string","description":"Substring to find."},' +
    '"path":{"type":"string","description":"File or directory (default .)."},' +
    '"ignore_case":{"type":"boolean","description":"Case-insensitive match."},' +
    '"max_results":{"type":"integer","description":"Maximum matches (default 200)."},' +
    '"reason":{"type":"string","description":"Short reason this search is needed."}' +
    '},"required":["pattern","reason"]}';
  ATools.Add(Spec, Grep);

  { --- File Tools v2 --- }
  Spec := MakeToolSpec('file_append',
    'Append text to a file inside the workspace, creating it if absent. ' +
    'Prefer this over the shell: >>, tee -a. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"content":{"type":"string","description":"Text to append."},' +
    '"reason":{"type":"string","description":"Short reason this append is needed."}' +
    '},"required":["path","content","reason"]}');
  Spec.SerialOnly := True;   { mutates the tree; keep it ordered }
  ATools.Add(Spec, AppendFile);

  Spec := MakeToolSpec('file_delete',
    'Delete a file (or an empty directory) inside the workspace. ' +
    'Prefer this over the shell: rm. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Path relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this delete is needed."}' +
    '},"required":["path","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, DeleteFileOp);

  Spec := MakeToolSpec('file_move',
    'Move or rename a file inside the workspace. ' +
    'Prefer this over the shell: mv. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"from":{"type":"string","description":"Source path relative to the workspace."},' +
    '"to":{"type":"string","description":"Destination path relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this move is needed."}' +
    '},"required":["from","to","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, MoveFileOp);

  Spec := MakeToolSpec('file_copy',
    'Copy a file inside the workspace. ' +
    'Prefer this over the shell: cp. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"from":{"type":"string","description":"Source path relative to the workspace."},' +
    '"to":{"type":"string","description":"Destination path relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this copy is needed."}' +
    '},"required":["from","to","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, CopyFileOp);

  Spec := MakeToolSpec('file_mkdir',
    'Create a directory (and its parents) inside the workspace. ' +
    'Prefer this over the shell: mkdir -p. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Directory relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this directory is needed."}' +
    '},"required":["path","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, MakeDir);

  Spec := MakeToolSpec('file_stat',
    'Report a path''s type and size inside the workspace. ' +
    'Prefer this over the shell: stat, ls -l. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Path relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this stat is needed."}' +
    '},"required":["path","reason"]}');
  ATools.Add(Spec, StatFile);

  Spec := MakeToolSpec('file_cwd',
    'Resolve a directory inside the workspace to its absolute path, for use as ' +
    'a run_command cwd. Prefer this over the shell: cd. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Directory relative to the workspace (default .)."},' +
    '"reason":{"type":"string","description":"Short reason this is needed."}' +
    '},"required":["reason"]}');
  Spec.SerialOnly := False;   { read-only }
  ATools.Add(Spec, Cwd);

  Spec := MakeToolSpec('file_replace_regex',
    'Replace a regular expression within one file. ' +
    'Prefer this over the shell: sed -i, perl -pi -e. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"pattern":{"type":"string","description":"Regular expression to match."},' +
    '"replacement":{"type":"string","description":"Replacement ($1 etc. for groups)."},' +
    '"all":{"type":"boolean","description":"Replace every match (default true)."},' +
    '"flags":{"type":"string","description":"Regex flags, e.g. i for case-insensitive."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["path","pattern","replacement","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, ReplaceRegex);

  Spec := MakeToolSpec('file_search_replace',
    'Replace a regular expression across every file matching a glob. ' +
    'dryRun counts without writing. Prefer this over the shell: ' +
    'grep -rl X | xargs sed -i, find -exec sed. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"glob":{"type":"string","description":"Glob selecting files, e.g. src/**/*.pas."},' +
    '"pattern":{"type":"string","description":"Regular expression to match."},' +
    '"replacement":{"type":"string","description":"Replacement ($1 etc. for groups)."},' +
    '"all":{"type":"boolean","description":"Replace every match (default true)."},' +
    '"dryRun":{"type":"boolean","description":"Count and list without writing."},' +
    '"flags":{"type":"string","description":"Regex flags, e.g. i for case-insensitive."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["glob","pattern","replacement","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, SearchReplace);

  Spec := MakeToolSpec('json_read',
    'Read and parse a JSON file (optionally at a JSON pointer). ' +
    'Prefer this over the shell: jq. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"pointer":{"type":"string","description":"A JSON pointer, e.g. /a/b/0 (optional)."},' +
    '"reason":{"type":"string","description":"Short reason this read is needed."}' +
    '},"required":["path","reason"]}');
  ATools.Add(Spec, JsonRead);

  Spec := MakeToolSpec('json_edit',
    'Set the value at a JSON pointer in a JSON file and write it back, ' +
    'validated. The pointer''s parent must already exist (so a typo is an ' +
    'error, not a new key). A parse failure never writes. ' +
    'Prefer this over the shell: jq. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"pointer":{"type":"string","description":"A JSON pointer to set, e.g. /service/port (the parent must exist)."},' +
    '"value":{"description":"The JSON value to set."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["path","pointer","value","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, JsonEdit);

  Spec := MakeToolSpec('yaml_read',
    'Read and parse a YAML file into JSON. Prefer this over the shell: yq. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"reason":{"type":"string","description":"Short reason this read is needed."}' +
    '},"required":["path","reason"]}');
  ATools.Add(Spec, YamlRead);

  Spec := MakeToolSpec('yaml_edit',
    'Set a dotted key path in a YAML file and write it back, validated. ' +
    'A parse failure never writes. Prefer this over the shell: yq -i. ' +
    'Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"key":{"type":"string","description":"A dotted key path, e.g. server.port."},' +
    '"value":{"description":"The value to set."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["path","key","value","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, YamlEdit);

  Spec := MakeToolSpec('patch_apply',
    'Apply a unified diff to files in the workspace. ' +
    'dryRun counts without writing. Prefer this over the shell: patch -p1, ' +
    'git apply. Requires a short reason. Gated by approval.',
    '{"type":"object","properties":{' +
    '"patch":{"type":"string","description":"A unified diff."},' +
    '"path":{"type":"string","description":"Base directory (default .)."},' +
    '"strip":{"type":"integer","description":"Path components to strip (default 1)."},' +
    '"dryRun":{"type":"boolean","description":"Count without writing."},' +
    '"reason":{"type":"string","description":"Short reason this patch is needed."}' +
    '},"required":["patch","reason"]}');
  Spec.SerialOnly := True;
  ATools.Add(Spec, PatchApply);
end;

end.
