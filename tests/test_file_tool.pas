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
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
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
    procedure TestReadFileNumbered;
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
  end;

implementation

{ TFakeApproval }

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  Inc(Calls);
  AResult := Default(TApprovalBatchResult);
  if Length(AAsks) > 0 then
    LastRef := AAsks[0].Subject.Ref;
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'denied by test';
  end;
  Result := True;
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

procedure TFileToolTest.TestReadFileNumbered;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'alpha'#10'beta');
  AssertTrue('ok', FTool.ReadFile(Args(['path', 'a.txt', 'reason', 'r']), Res, Err));
  AssertTrue('line 1 numbered', Pos('1'#9'alpha', Res) > 0);
  AssertTrue('line 2 numbered', Pos('2'#9'beta', Res) > 0);
  AssertEquals('asked for read', 'file:read', FApproval.LastRef);
end;

procedure TFileToolTest.TestReadFileOffsetLimit;
var
  Res, Err: string;
begin
  WriteRaw(Full('a.txt'), 'l1'#10'l2'#10'l3'#10'l4'#10'l5');
  AssertTrue('ok', FTool.ReadFile(
    Args(['path', 'a.txt', 'reason', 'r']) + '', Res, Err));
  AssertTrue('ok', FTool.ReadFile(
    '{"path":"a.txt","reason":"r","offset":2,"limit":2}', Res, Err));
  AssertTrue('starts at 2', Pos('2'#9'l2', Res) > 0);
  AssertTrue('has 3', Pos('3'#9'l3', Res) > 0);
  AssertTrue('no 4', Pos('4'#9'l4', Res) = 0);
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
    AssertEquals('six tools', 6, Registry.Count);
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

initialization
  RegisterTest(TFileToolTest);
  Randomize;

end.
