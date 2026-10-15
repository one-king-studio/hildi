unit test_file_tool;
{ fpcunit tests for hildegard.helper.files: the six gated file tools against
  a real temporary workspace, with a fake approval service (and one real
  TApprovalService to prove persistence). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.workspace, hildegard.helper.files;

type
  TFakeApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Calls: Integer;
    LastRef: string;
    LastSummary: string;
    LastPath: string;
    LastOptions: TApprovalOptionArray;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
    function HasOption(const AKey: string): Boolean;
  end;

  TChoiceRecorder = class
  public
    Calls: Integer;
    Choice: TApprovalChoice;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

  TFileToolTest = class(TTestCase)
  private
    FDir: string;
    FApproval: TFakeApproval;
    FTool: TFileTool;
    function Cfg: TFileToolConfig;
    function Str(const AKey, AValue: string): string;
    function Args(const APairs: array of string): string;
    procedure WriteRaw(const APath, AText: string);
    function ReadRaw(const APath: string): string;
    function Full(const ARel: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestReadFileContent;
    procedure TestReadFileOffsetLimit;
    procedure TestReadErrors;
    procedure TestWriteFileCreatesAndReports;
    procedure TestRefusedWriteLeavesNoFile;
    procedure TestEditFileSingleReplace;
    procedure TestEditFileAmbiguous;
    procedure TestEditFileReplaceAll;
    procedure TestEditFileNotFound;
    procedure TestListDir;
    procedure TestGlob;
    procedure TestGrep;
    procedure TestGrepIgnoreCaseAndCap;
    procedure TestPathEscapeRefused;
    procedure TestNoApprovalService;
    procedure TestRegisterAdvertisesSixGatedTools;
    procedure TestGlobMatchMatcher;
    procedure TestExactAllowPersists;
    procedure TestWriteAskOffersPathOptions;
    procedure TestReadAskOmitsExtensionScoping;
    procedure TestGlobAskScopesOnTheDirectoryNotThePattern;
    procedure TestAskCarriesTheSubjectPath;
    { File Tools v2, Phase 1. }
    procedure TestAppendCreatesThenAppends;
    procedure TestDeleteFileOp;
    procedure TestMoveFileOp;
    procedure TestCopyFileOp;
    procedure TestMakeDirCreatesParents;
    procedure TestStatReportsTypeAndSize;
    procedure TestV2ToolsAreRegistered;
    procedure TestReplaceRegexAll;
    procedure TestReplaceRegexBadPattern;
    procedure TestSearchReplaceAcrossGlob;
    procedure TestSearchReplaceDryRunWritesNothing;
    procedure TestSearchReplaceAskScopesOnTheGlobDirectory;
  end;

implementation

{ TFakeApproval }

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  Inc(Calls);
  AResult := Default(TApprovalBatchResult);
  if Length(AAsks) > 0 then
  begin
    LastRef := AAsks[0].Subject.Ref;
    LastSummary := AAsks[0].Summary;
    LastPath := AAsks[0].Subject.Path;
    LastOptions := AAsks[0].Options;
  end;
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'denied by test';
  end;
  Result := True;
end;

function TFakeApproval.HasOption(const AKey: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(LastOptions) do
    if LastOptions[I].Key = AKey then
      Exit(True);
  Result := False;
end;

{ TChoiceRecorder }

function TChoiceRecorder.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
begin
  Inc(Calls);
  Result := Choice;
end;

{ TFileToolTest }

procedure TFileToolTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-files-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FApproval := TFakeApproval.Create;
  FApproval.Allow := True;
  FTool := TFileTool.Create(Cfg, FApproval);
end;

procedure TFileToolTest.TearDown;
  procedure RemoveTree(const ADir: string);
  var
    S: TSearchRec;
    Full: string;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, S) = 0 then
    try
      repeat
        if (S.Name = '.') or (S.Name = '..') then
          Continue;
        Full := IncludeTrailingPathDelimiter(ADir) + S.Name;
        if (S.Attr and faDirectory) <> 0 then
          RemoveTree(Full)
        else
          DeleteFile(Full);
      until FindNext(S) <> 0;
    finally
      FindClose(S);
    end;
    RemoveDir(ADir);
  end;

begin
  FTool.Free;
  { FApproval is a TInterfacedObject held by the tool's IApprovalService; freeing
    the tool already released and destroyed it. }
  FApproval := nil;
  if DirectoryExists(FDir) then
    RemoveTree(FDir);
end;

function TFileToolTest.Cfg: TFileToolConfig;
begin
  Result := Default(TFileToolConfig);
  Result.Root := FDir;
end;

function TFileToolTest.Str(const AKey, AValue: string): string;
var
  V: string;
begin
  V := StringReplace(AValue, '\', '\\', [rfReplaceAll]);
  V := StringReplace(V, '"', '\"', [rfReplaceAll]);
  V := StringReplace(V, #10, '\n', [rfReplaceAll]);
  V := StringReplace(V, #13, '\r', [rfReplaceAll]);
  V := StringReplace(V, #9, '\t', [rfReplaceAll]);
  Result := '"' + AKey + '":"' + V + '"';
end;

function TFileToolTest.Args(const APairs: array of string): string;
var
  I: Integer;
begin
  Result := '{';
  I := 0;
  while I < Length(APairs) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + Str(APairs[I], APairs[I + 1]);
    Inc(I, 2);
  end;
  Result := Result + '}';
end;

function TFileToolTest.Full(const ARel: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + ARel;
end;

procedure TFileToolTest.WriteRaw(const APath, AText: string);
var
  SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AText;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

function TFileToolTest.ReadRaw(const APath: string): string;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

procedure TFileToolTest.TestReadFileContent;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'alpha'#10'beta');
  AssertTrue('ok', FTool.ReadFile(Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
  AssertTrue('names the file', Pos('read a.txt', Res) > 0);
  AssertTrue('first line', Pos('alpha', Res) > 0);
  AssertTrue('second line', Pos('beta', Res) > 0);
  AssertFalse('no line-number prefix', Pos(#9, Res) > 0);
  AssertEquals('asked for read', 'file:read', FApproval.LastRef);
end;

procedure TFileToolTest.TestReadFileOffsetLimit;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'l1'#10'l2'#10'l3'#10'l4'#10'l5');
  AssertTrue('ok', FTool.ReadFile(
    '{"path":"a.txt","reason":"r","offset":2,"limit":2}', Res, Err));
  AssertTrue('starts at l2', Pos('l2', Res) > 0);
  AssertTrue('has l3', Pos('l3', Res) > 0);
  AssertFalse('no l1', Pos('l1', Res) > 0);
  AssertFalse('no l4', Pos('l4', Res) > 0);
  { The tool defines how its ask reads: a ranged read names the range. }
  AssertEquals('summary names the range', 'read a.txt:2-3',
    FApproval.LastSummary);
end;

procedure TFileToolTest.TestReadErrors;
var
  Res, Err: string;
begin
  AssertFalse('missing', FTool.ReadFile(
    Args(['path', 'nope.txt', 'reason', 'r']), Res, Err));
  AssertTrue('missing error', Pos('no such file', Err) > 0);

  ForceDirectories(Full('adir'));
  AssertFalse('directory', FTool.ReadFile(
    Args(['path', 'adir', 'reason', 'r']), Res, Err));
  AssertTrue('not a file', Pos('not a file', Err) > 0);
end;

procedure TFileToolTest.TestWriteFileCreatesAndReports;
var
  Res, Err: string;
begin
  AssertTrue('ok', FTool.WriteFile(
    Args(['path', 'sub/a.txt', 'content', 'hello'#10'world', 'reason', 'r']),
    Res, Err));
  AssertTrue('file exists', FileExists(Full('sub/a.txt')));
  AssertEquals('content written', 'hello'#10'world', ReadRaw(Full('sub/a.txt')));
  AssertTrue('reports', Pos('wrote', Res) > 0);
  AssertEquals('asked for write', 'file:write', FApproval.LastRef);
end;

procedure TFileToolTest.TestRefusedWriteLeavesNoFile;
var
  Res, Err: string;
begin
  FApproval.Allow := False;
  AssertFalse('refused', FTool.WriteFile(
    Args(['path', 'a.txt', 'content', 'x', 'reason', 'r']), Res, Err));
  AssertFalse('no file', FileExists(Full('a.txt')));
  AssertTrue('reason', Pos('denied', Err) > 0);
end;

procedure TFileToolTest.TestEditFileSingleReplace;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'one two three');
  AssertTrue('ok', FTool.EditFile(Args(['path', 'a.txt', 'old_string', 'two',
    'new_string', 'TWO', 'reason', 'r']), Res, Err));
  AssertTrue('replaced', Pos('one TWO three', ReadRaw(Full('a.txt'))) > 0);
  AssertTrue('count', Pos('1 occurrence', Res) > 0);
end;

procedure TFileToolTest.TestEditFileAmbiguous;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'x x x');
  AssertFalse('ambiguous', FTool.EditFile(Args(['path', 'a.txt',
    'old_string', 'x', 'new_string', 'y', 'reason', 'r']), Res, Err));
  AssertTrue('message', Pos('not unique', Err) > 0);
  AssertEquals('unchanged', 'x x x'#10, ReadRaw(Full('a.txt')));
end;

procedure TFileToolTest.TestEditFileReplaceAll;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'x x x');
  AssertTrue('ok', FTool.EditFile(
    '{"path":"a.txt","old_string":"x","new_string":"y","replace_all":true,' +
    '"reason":"r"}', Res, Err));
  AssertEquals('all replaced', 'y y y'#10, ReadRaw(Full('a.txt')));
end;

procedure TFileToolTest.TestEditFileNotFound;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'abc');
  AssertFalse('not found', FTool.EditFile(Args(['path', 'a.txt',
    'old_string', 'zzz', 'new_string', 'y', 'reason', 'r']), Res, Err));
  AssertTrue('message', Pos('not found', Err) > 0);
end;

procedure TFileToolTest.TestListDir;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'a');
  WriteRaw(Full('b/c.txt'), 'c');
  AssertTrue('ok', FTool.ListDir(
    Args(['path', '.', 'reason', 'r']), Res, Err));
  AssertTrue('file listed', Pos('a.txt', Res) > 0);
  AssertTrue('dir listed with slash', Pos('b/', Res) > 0);
  AssertTrue('not recursive', Pos('c.txt', Res) = 0);

  AssertTrue('ok recursive', FTool.ListDir(
    '{"path":".","recursive":true,"reason":"r"}', Res, Err));
  AssertTrue('recursive lists file', Pos('b/c.txt', Res) > 0);
end;

procedure TFileToolTest.TestGlob;
var
  Res, Err: string;
begin
  WriteRaw(Full('src/a.pas'), 'a');
  WriteRaw(Full('src/sub/b.pas'), 'b');
  WriteRaw(Full('src/readme.md'), 'm');

  AssertTrue('ok', FTool.Glob(
    Args(['pattern', 'src/**/*.pas', 'reason', 'r']), Res, Err));
  AssertTrue('a.pas', Pos('src/a.pas', Res) > 0);
  AssertTrue('b.pas', Pos('src/sub/b.pas', Res) > 0);
  AssertTrue('no md', Pos('readme.md', Res) = 0);

  AssertTrue('ok', FTool.Glob(
    Args(['pattern', 'src/*.pas', 'reason', 'r']), Res, Err));
  AssertTrue('only top-level', Pos('src/a.pas', Res) > 0);
  AssertTrue('not nested', Pos('src/sub/b.pas', Res) = 0);
end;

procedure TFileToolTest.TestGrep;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'first'#10'needle here'#10'last');
  WriteRaw(Full('b.txt'), 'nothing');
  AssertTrue('ok', FTool.Grep(
    Args(['pattern', 'needle', 'path', '.', 'reason', 'r']), Res, Err));
  AssertTrue('hit with location', Pos('a.txt:2: needle here', Res) > 0);
  AssertTrue('no false hit', Pos('b.txt', Res) = 0);
end;

procedure TFileToolTest.TestGrepIgnoreCaseAndCap;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'Needle'#10'needle');
  AssertTrue('case-sensitive matches lowercase', FTool.Grep(
    Args(['pattern', 'needle', 'path', 'a.txt', 'reason', 'r']), Res, Err));
  AssertTrue('lowercase line', Pos('a.txt:2: needle', Res) > 0);
  AssertTrue('not the uppercase line', Pos('a.txt:1: Needle', Res) = 0);

  AssertTrue('ignore case', FTool.Grep(
    '{"pattern":"needle","path":"a.txt","ignore_case":true,"reason":"r"}',
    Res, Err));
  AssertTrue('match', Pos('a.txt:1: Needle', Res) > 0);

  AssertTrue('capped', FTool.Grep(
    '{"pattern":"needle","path":"a.txt","ignore_case":true,' +
    '"max_results":1,"reason":"r"}', Res, Err));
  AssertTrue('truncated marker', Pos('[truncated', Res) > 0);
end;

procedure TFileToolTest.TestPathEscapeRefused;
var
  Res, Err: string;
begin
  AssertFalse('dotdot', FTool.ReadFile(
    Args(['path', '../secret', 'reason', 'r']), Res, Err));
  AssertTrue('escape error', Pos('escapes the workspace', Err) > 0);

  AssertFalse('absolute', FTool.ReadFile(
    Args(['path', '/etc/hosts', 'reason', 'r']), Res, Err));
  AssertTrue('escape error', Pos('escapes the workspace', Err) > 0);
end;

procedure TFileToolTest.TestNoApprovalService;
var
  Tool: TFileTool;
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'a');
  Tool := TFileTool.Create(Cfg, nil);
  try
    AssertFalse('no service', Tool.ReadFile(
      Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
    AssertTrue('message', Pos('no approval service', Err) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TFileToolTest.TestRegisterAdvertisesSixGatedTools;
var
  Registry: TToolRegistry;
  Specs: TToolSpecArray;
  I: Integer;
begin
  Registry := TToolRegistry.Create;
  try
    FTool.Register(Registry);
    AssertEquals('v1 six + v2 eight tools', 14, Registry.Count);
    Specs := Registry.Specs;
    for I := 0 to High(Specs) do
      AssertTrue(Specs[I].Name + ' requires reason',
        Pos('"reason"', Specs[I].ParametersJson) > 0);
  finally
    Registry.Free;
  end;
end;

procedure TFileToolTest.TestGlobMatchMatcher;
begin
  AssertTrue('star segment', GlobMatch('*.pas', 'a.pas'));
  AssertFalse('star no slash', GlobMatch('*.pas', 'sub/a.pas'));
  AssertTrue('question', GlobMatch('a?c.pas', 'abc.pas'));
  AssertTrue('double star', GlobMatch('**/*.pas', 'a/b/c.pas'));
  AssertTrue('double star root', GlobMatch('**/*.pas', 'c.pas'));
  AssertTrue('prefix dir', GlobMatch('src/**', 'src/a/b.txt'));
  AssertFalse('literal mismatch', GlobMatch('a.pas', 'b.pas'));
end;

procedure TFileToolTest.TestExactAllowPersists;
var
  Store: IApprovalStore;
  Rec: TChoiceRecorder;
  Svc: IApprovalService;
  Ctx: TApprovalContext;
  Tool: TFileTool;
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'a');
  Store := TMemoryApprovalStore.Create;
  Rec := TChoiceRecorder.Create;
  try
    Rec.Choice := Default(TApprovalChoice);
    Rec.Choice.Allowed := True;
    Rec.Choice.OptionKey := 'exact';
    Rec.Choice.Scope := asWorkspace;
    Ctx := Default(TApprovalContext);
    Ctx.WorkspaceId := 1;
    Svc := TApprovalService.Create(Store, Rec.Prompt, Ctx);
    Tool := TFileTool.Create(Cfg, Svc);
    try
      AssertTrue('first', Tool.ReadFile(
        Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
      AssertTrue('second', Tool.ReadFile(
        Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
      AssertEquals('prompted once', 1, Rec.Calls);
    finally
      Tool.Free;
    end;
  finally
    Rec.Free;
  end;
end;

procedure TFileToolTest.TestWriteAskOffersPathOptions;
var
  Res, Err: string;
begin
  { A write-shaped ask offers once/exact/dir/ext/dir_ext/any/never. }
  AssertTrue('write', FTool.WriteFile(
    Args(['path', 'docs/a.md', 'content', 'x', 'reason', 'r']), Res, Err));
  AssertTrue('once', FApproval.HasOption('once'));
  AssertTrue('exact', FApproval.HasOption('exact'));
  AssertTrue('dir', FApproval.HasOption('dir'));
  AssertTrue('ext', FApproval.HasOption('ext'));
  AssertTrue('dir_ext', FApproval.HasOption('dir_ext'));
  AssertTrue('any', FApproval.HasOption('any'));
  AssertTrue('never', FApproval.HasOption('never'));
end;

procedure TFileToolTest.TestReadAskOmitsExtensionScoping;
var
  Res, Err: string;
begin
  { A read-shaped ask offers no extension scoping. }
  WriteRaw(Full('a.md'), 'hi');
  AssertTrue('read', FTool.ReadFile(
    Args(['path', 'a.md', 'reason', 'r']), Res, Err));
  AssertTrue('dir', FApproval.HasOption('dir'));
  AssertFalse('no ext', FApproval.HasOption('ext'));
  AssertFalse('no dir_ext', FApproval.HasOption('dir_ext'));
  AssertTrue('never', FApproval.HasOption('never'));
end;

procedure TFileToolTest.TestGlobAskScopesOnTheDirectoryNotThePattern;
var
  Res, Err: string;
begin
  { file_glob's subject path is the searched directory, not the pattern. }
  ForceDirectories(Full('src'));
  AssertTrue('glob', FTool.Glob(
    Args(['pattern', '**/*.pas', 'path', 'src', 'reason', 'r']), Res, Err));
  AssertEquals('scopes on the directory', 'src', FApproval.LastPath);
end;

procedure TFileToolTest.TestAskCarriesTheSubjectPath;
var
  Res, Err: string;
begin
  WriteRaw(Full('docs/x/a.md'), 'hi');
  AssertTrue('write', FTool.WriteFile(
    Args(['path', 'docs/x/a.md', 'content', 'y', 'reason', 'r']), Res, Err));
  AssertEquals('the operation path', 'docs/x/a.md', FApproval.LastPath);
end;

procedure TFileToolTest.TestAppendCreatesThenAppends;
var
  Res, Err: string;
begin
  AssertTrue('append creates', FTool.AppendFile(
    Args(['path', 'log.txt', 'content', 'a', 'reason', 'r']), Res, Err));
  AssertEquals('created with a', 'a', ReadRaw(Full('log.txt')));
  AssertTrue('append again', FTool.AppendFile(
    Args(['path', 'log.txt', 'content', 'b', 'reason', 'r']), Res, Err));
  AssertEquals('appended b', 'ab', ReadRaw(Full('log.txt')));
end;

procedure TFileToolTest.TestDeleteFileOp;
var
  Res, Err: string;
begin
  WriteRaw(Full('gone.txt'), 'x');
  AssertTrue('delete', FTool.DeleteFileOp(
    Args(['path', 'gone.txt', 'reason', 'r']), Res, Err));
  AssertFalse('file is gone', FileExists(Full('gone.txt')));
end;

procedure TFileToolTest.TestMoveFileOp;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'hi');
  AssertTrue('move', FTool.MoveFileOp(
    Args(['from', 'a.txt', 'to', 'sub/b.txt', 'reason', 'r']), Res, Err));
  AssertFalse('source gone', FileExists(Full('a.txt')));
  AssertEquals('destination has the content', 'hi' + LineEnding,
    ReadRaw(Full('sub/b.txt')));
end;

procedure TFileToolTest.TestCopyFileOp;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'hi');
  AssertTrue('copy', FTool.CopyFileOp(
    Args(['from', 'a.txt', 'to', 'b.txt', 'reason', 'r']), Res, Err));
  AssertEquals('source stays', 'hi' + LineEnding, ReadRaw(Full('a.txt')));
  AssertEquals('copy made', 'hi' + LineEnding, ReadRaw(Full('b.txt')));
end;

procedure TFileToolTest.TestMakeDirCreatesParents;
var
  Res, Err: string;
begin
  AssertTrue('mkdir', FTool.MakeDir(
    Args(['path', 'x/y/z', 'reason', 'r']), Res, Err));
  AssertTrue('deep dir exists', DirectoryExists(Full('x/y/z')));
end;

procedure TFileToolTest.TestStatReportsTypeAndSize;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'hello');
  AssertTrue('stat file', FTool.StatFile(
    Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
  AssertTrue('type file', Pos('"type":"file"', Res) > 0);
  { WriteRaw adds a trailing newline, so 6 bytes. }
  AssertTrue('size 6', Pos('"size":6', Res) > 0);
  AssertTrue('stat dir', FTool.StatFile(
    Args(['path', '.', 'reason', 'r']), Res, Err));
  AssertTrue('type dir', Pos('"type":"dir"', Res) > 0);
end;

procedure TFileToolTest.TestV2ToolsAreRegistered;
var
  Registry: TToolRegistry;
  Specs: TToolSpecArray;
  I, J: Integer;
  Saw: Boolean;
  Names: array[0..5] of string;
begin
  Names[0] := 'file_append';
  Names[1] := 'file_delete';
  Names[2] := 'file_move';
  Names[3] := 'file_copy';
  Names[4] := 'file_mkdir';
  Names[5] := 'file_stat';
  Registry := TToolRegistry.Create;
  try
    FTool.Register(Registry);
    Specs := Registry.Specs;
    for I := Low(Names) to High(Names) do
    begin
      Saw := False;
      for J := 0 to High(Specs) do
        if Specs[J].Name = Names[I] then
          Saw := True;
      AssertTrue(Names[I] + ' registered', Saw);
    end;
  finally
    Registry.Free;
  end;
end;

procedure TFileToolTest.TestReplaceRegexAll;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'cat bat cat');
  AssertTrue('replace', FTool.ReplaceRegex(
    Args(['path', 'a.txt', 'pattern', 'cat', 'replacement', 'dog',
      'reason', 'r']), Res, Err));
  AssertTrue('two replaced', Pos('"replaced":2', Res) > 0);
  AssertEquals('all replaced', 'dog bat dog' + LineEnding,
    ReadRaw(Full('a.txt')));
end;

procedure TFileToolTest.TestReplaceRegexBadPattern;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'x');
  AssertFalse('bad pattern', FTool.ReplaceRegex(
    Args(['path', 'a.txt', 'pattern', '([', 'replacement', 'y',
      'reason', 'r']), Res, Err));
  AssertTrue('error mentions regex', Pos('regex', Err) > 0);
end;

procedure TFileToolTest.TestSearchReplaceAcrossGlob;
var
  Res, Err: string;
begin
  WriteRaw(Full('src/a.pas'), 'OldName here');
  WriteRaw(Full('src/b.pas'), 'OldName there');
  WriteRaw(Full('src/c.txt'), 'OldName ignored');
  AssertTrue('search-replace', FTool.SearchReplace(
    Args(['glob', 'src/*.pas', 'pattern', 'OldName', 'replacement', 'NewName',
      'reason', 'r']), Res, Err));
  AssertTrue('two replacements', Pos('"replacements":2', Res) > 0);
  AssertEquals('a changed', 'NewName here' + LineEnding,
    ReadRaw(Full('src/a.pas')));
  AssertEquals('txt untouched', 'OldName ignored' + LineEnding,
    ReadRaw(Full('src/c.txt')));
end;

procedure TFileToolTest.TestSearchReplaceDryRunWritesNothing;
var
  Res, Err: string;
begin
  WriteRaw(Full('src/a.pas'), 'OldName');
  { dryRun must be a JSON boolean, not a string (the Args helper quotes). }
  AssertTrue('dry run', FTool.SearchReplace(
    '{"glob":"src/*.pas","pattern":"OldName","replacement":"NewName",' +
    '"dryRun":true,"reason":"r"}', Res, Err));
  AssertTrue('counted', Pos('"replacements":1', Res) > 0);
  AssertEquals('file unchanged', 'OldName' + LineEnding,
    ReadRaw(Full('src/a.pas')));
end;

procedure TFileToolTest.TestSearchReplaceAskScopesOnTheGlobDirectory;
var
  Res, Err: string;
begin
  { A multi-file replace is a write-shaped ask scoped on the glob's leading
    directory, so one dir/dir_ext grant covers the whole batch. }
  WriteRaw(Full('src/a.pas'), 'x');
  AssertTrue('search-replace', FTool.SearchReplace(
    Args(['glob', 'src/*.pas', 'pattern', 'x', 'replacement', 'y',
      'reason', 'r']), Res, Err));
  AssertEquals('scopes on the directory', 'src', FApproval.LastPath);
  AssertTrue('offers dir', FApproval.HasOption('dir'));
  AssertTrue('offers ext', FApproval.HasOption('ext'));
  AssertTrue('offers dir_ext', FApproval.HasOption('dir_ext'));
end;

initialization
  RegisterTest(TFileToolTest);
  Randomize;

end.
