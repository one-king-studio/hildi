unit TestSkillsFiles;
{ fpcunit tests for HildiSkillsFiles: SKILL.md frontmatter parsing, the spec's
  naming and length rules, and bounded discovery. Pure - no registry, no store,
  no loop. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiSkills, HildiSkillsFiles;

type
  TSkillsFilesTest = class(TTestCase)
  private
    FDir: string;
    function WriteSkill(const ARelDir, AText: string): string;
    function Skill(const AName, ADesc: string): TSkillFile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { Phase 1: frontmatter parsing. }
    procedure TestSplitSeparatesFieldsAndBody;
    procedure TestSplitToleratesLeadingBlankLines;
    procedure TestSplitRejectsMissingFrontmatter;
    procedure TestSplitRejectsUnclosedFrontmatter;
    procedure TestSplitTrimsTheBody;
    procedure TestSplitHandlesEmptyBody;
    { Phase 2: name validation. }
    procedure TestNameRules;
    procedure TestDescriptionLength;
    { Phase 2 remainder: the name must match its directory. }
    procedure TestNameMustMatchItsDirectory;
    procedure TestCompatibilityLength;
    { Phase 3: discovery. }
    procedure TestScanFindsSkillDirectories;
    procedure TestScanIgnoresDirectoriesWithoutSkillMd;
    procedure TestScanSkipsGitAndNodeModules;
    procedure TestScanReportsAnInvalidSkillWithoutAborting;
    procedure TestScanListsResourcesButDoesNotReadThem;
    procedure TestScanRespectsTheDirectoryBound;
    procedure TestScanOfAMissingRootIsEmpty;
    { Phase 4: import. }
    procedure TestImportAddsAValidSkill;
    procedure TestImportSkipsAnInvalidSkill;
    procedure TestImportDerivesASnakeCaseKey;
    procedure TestProjectScopeShadowsUserScope;
    procedure TestImportCarriesLocationAndResources;
  end;

implementation

procedure TSkillsFilesTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-skills-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
end;

procedure TSkillsFilesTest.TearDown;
begin
  RemoveDir(FDir);
end;

function TSkillsFilesTest.WriteSkill(const ARelDir, AText: string): string;
var
  Dir, Path: string;
  Fs: TFileStream;
begin
  Dir := IncludeTrailingPathDelimiter(FDir) + ARelDir;
  ForceDirectories(Dir);
  Path := IncludeTrailingPathDelimiter(Dir) + 'SKILL.md';
  Fs := TFileStream.Create(Path, fmCreate);
  try
    if AText <> '' then
      Fs.WriteBuffer(AText[1], Length(AText));
  finally
    Fs.Free;
  end;
  Result := Path;
end;

function TSkillsFilesTest.Skill(const AName, ADesc: string): TSkillFile;
begin
  Result := Default(TSkillFile);
  Result.Name := AName;
  Result.Description := ADesc;
end;

procedure TSkillsFilesTest.TestSplitSeparatesFieldsAndBody;
var
  Front, Body, Err: string;
begin
  AssertTrue('split', SplitFrontmatter(
    '---'#10 + 'name: pdf-processing'#10 + 'description: Extract PDF text.'#10 +
    '---'#10 + '# PDF'#10 + 'Do the thing.'#10, Front, Body, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('name kept', Pos('name: pdf-processing', Front) > 0);
  AssertTrue('description kept', Pos('description: Extract PDF text.', Front) > 0);
  AssertTrue('body starts with the heading', Pos('# PDF', Body) = 1);
  AssertTrue('body carries the instruction', Pos('Do the thing.', Body) > 0);
  AssertTrue('body has no frontmatter', Pos('name:', Body) = 0);
end;

procedure TSkillsFilesTest.TestSplitToleratesLeadingBlankLines;
var
  Front, Body, Err: string;
begin
  { Hand-edited files accumulate blank lines above the fence. }
  AssertTrue('split', SplitFrontmatter(
    #10#10 + '---'#10 + 'name: a'#10 + '---'#10 + 'body'#10, Front, Body, Err));
  AssertEquals('no error', '', Err);
  AssertTrue('name kept', Pos('name: a', Front) > 0);
  AssertEquals('body', 'body', Body);
end;

procedure TSkillsFilesTest.TestSplitRejectsMissingFrontmatter;
var
  Front, Body, Err: string;
begin
  AssertFalse('no frontmatter', SplitFrontmatter('# Just markdown'#10,
    Front, Body, Err));
  AssertTrue('says why: ' + Err, Pos('---', Err) > 0);
end;

procedure TSkillsFilesTest.TestSplitRejectsUnclosedFrontmatter;
var
  Front, Body, Err: string;
begin
  { An unclosed block is an error, not a body: treating the rest of the file as
    a body would hide a truncated skill. }
  AssertFalse('unclosed', SplitFrontmatter(
    '---'#10 + 'name: a'#10 + 'description: b'#10, Front, Body, Err));
  AssertTrue('says why: ' + Err, Pos('not closed', Err) > 0);
end;

procedure TSkillsFilesTest.TestSplitTrimsTheBody;
var
  Front, Body, Err: string;
begin
  AssertTrue('split', SplitFrontmatter(
    '---'#10'name: a'#10'---'#10#10#10'  body  '#10#10, Front, Body, Err));
  AssertEquals('trimmed', 'body', Body);
end;

procedure TSkillsFilesTest.TestSplitHandlesEmptyBody;
var
  Front, Body, Err: string;
begin
  AssertTrue('split', SplitFrontmatter('---'#10'name: a'#10'---'#10,
    Front, Body, Err));
  AssertEquals('empty body is valid', '', Body);
end;

procedure TSkillsFilesTest.TestNameRules;
var
  Why: string;
  Long64: string;
begin
  AssertTrue('simple', IsValidSkillName('pdf', Why));
  AssertTrue('hyphenated', IsValidSkillName('pdf-processing', Why));
  AssertTrue('digits', IsValidSkillName('v2-extract', Why));

  Long64 := StringOfChar('a', 64);
  AssertTrue('exactly 64', IsValidSkillName(Long64, Why));

  AssertFalse('empty', IsValidSkillName('', Why));
  AssertTrue('empty says so', Pos('empty', Why) > 0);

  AssertFalse('uppercase', IsValidSkillName('PDF-Processing', Why));
  AssertTrue('uppercase says so', Pos('a-z', Why) > 0);

  AssertFalse('leading hyphen', IsValidSkillName('-pdf', Why));
  AssertTrue('leading says so', Pos('starts', Why) > 0);

  AssertFalse('trailing hyphen', IsValidSkillName('pdf-', Why));
  AssertTrue('trailing says so', Pos('ends', Why) > 0);

  AssertFalse('double hyphen', IsValidSkillName('pdf--processing', Why));
  AssertTrue('double says so', Pos('consecutive', Why) > 0);

  AssertFalse('underscore', IsValidSkillName('pdf_processing', Why));
  AssertFalse('too long', IsValidSkillName(StringOfChar('a', 65), Why));
  AssertTrue('too long says so', Pos('longer', Why) > 0);
end;

procedure TSkillsFilesTest.TestDescriptionLength;
var
  S: TSkillFile;
begin
  S := Skill('ok', 'a description');
  AssertEquals('valid', '', ValidateSkillFile(S));

  S := Skill('ok', '');
  AssertTrue('empty description rejected',
    Pos('description', ValidateSkillFile(S)) > 0);

  S := Skill('ok', StringOfChar('x', 1024));
  AssertEquals('exactly 1024 is fine', '', ValidateSkillFile(S));

  S := Skill('ok', StringOfChar('x', 1025));
  AssertTrue('over 1024 rejected',
    Pos('description', ValidateSkillFile(S)) > 0);
end;

procedure TSkillsFilesTest.TestNameMustMatchItsDirectory;
var
  S: TSkillFile;
begin
  { The spec requires it. A mismatch means a renamed folder or a copy-paste, and
    the result is a skill that answers to a name the operator will not find. }
  S := Skill('pdf-processing', 'does pdfs');
  S.Dir := IncludeTrailingPathDelimiter(FDir) + 'pdf-processing';
  AssertEquals('matches', '', ValidateSkillFile(S));

  S.Dir := IncludeTrailingPathDelimiter(FDir) + 'something-else';
  AssertTrue('mismatch is named',
    Pos('does not match its directory', ValidateSkillFile(S)) > 0);
end;

procedure TSkillsFilesTest.TestCompatibilityLength;
var
  S: TSkillFile;
begin
  S := Skill('ok', 'a description');
  S.Compatibility := StringOfChar('x', 500);
  AssertEquals('exactly 500 is fine', '', ValidateSkillFile(S));

  S.Compatibility := StringOfChar('x', 501);
  AssertTrue('over 500 rejected',
    Pos('compatibility', ValidateSkillFile(S)) > 0);
end;

{ --- Phase 3: discovery --- }

procedure TSkillsFilesTest.TestScanFindsSkillDirectories;
var
  Skills: TSkillFileArray;
begin
  WriteSkill('pdf-processing',
    '---'#10'name: pdf-processing'#10'description: Extract PDF text.'#10'---'#10'Body.');
  WriteSkill('data-analysis',
    '---'#10'name: data-analysis'#10'description: Charts.'#10'---'#10'Body.');
  Skills := ScanSkillsDir(FDir, skProject);
  AssertEquals('both found', 2, Length(Skills));
  AssertEquals('no problems', '', Skills[0].Problem + Skills[1].Problem);
end;

procedure TSkillsFilesTest.TestScanIgnoresDirectoriesWithoutSkillMd;
var
  Skills: TSkillFileArray;
begin
  { A loose README and a directory with no SKILL.md are normal, not errors. }
  WriteSkill('real',
    '---'#10'name: real'#10'description: A skill.'#10'---'#10'Body.');
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'not-a-skill');
  Skills := ScanSkillsDir(FDir, skProject);
  AssertEquals('only the real one', 1, Length(Skills));
  AssertEquals('and it is the right one', 'real', Skills[0].Name);
end;

procedure TSkillsFilesTest.TestScanSkipsGitAndNodeModules;
var
  Skills: TSkillFileArray;
begin
  WriteSkill('.git/hidden',
    '---'#10'name: hidden'#10'description: Should not appear.'#10'---'#10'x');
  WriteSkill('node_modules/pkg',
    '---'#10'name: pkg'#10'description: Should not appear.'#10'---'#10'x');
  WriteSkill('visible',
    '---'#10'name: visible'#10'description: Should appear.'#10'---'#10'x');
  Skills := ScanSkillsDir(FDir, skProject);
  AssertEquals('only the visible one', 1, Length(Skills));
  AssertEquals('and it is visible', 'visible', Skills[0].Name);
end;

procedure TSkillsFilesTest.TestScanReportsAnInvalidSkillWithoutAborting;
var
  Skills: TSkillFileArray;
begin
  { One bad skill in a cloned repo must not take out the rest. }
  WriteSkill('broken',
    '---'#10'name: BROKEN Name'#10'description: bad name'#10'---'#10'x');
  WriteSkill('good',
    '---'#10'name: good'#10'description: A fine skill.'#10'---'#10'x');
  Skills := ScanSkillsDir(FDir, skProject);
  AssertEquals('both listed', 2, Length(Skills));
  AssertTrue('one has a problem', (Skills[0].Problem <> '') or
    (Skills[1].Problem <> ''));
  AssertTrue('one is fine', (Skills[0].Problem = '') or
    (Skills[1].Problem = ''));
end;

procedure TSkillsFilesTest.TestScanListsResourcesButDoesNotReadThem;
var
  Skills: TSkillFileArray;
  I: Integer;
  SawScript, SawRef: Boolean;
begin
  WriteSkill('with-resources',
    '---'#10'name: with-resources'#10'description: Has files.'#10'---'#10'x');
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'with-resources/scripts');
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'with-resources/references');
  Skills := ScanSkillsDir(FDir, skProject);
  AssertEquals('one skill', 1, Length(Skills));
  SawScript := False;
  SawRef := False;
  for I := 0 to High(Skills[0].Resources) do
  begin
    if Skills[0].Resources[I] = 'scripts/' then
      SawScript := True;
    if Skills[0].Resources[I] = 'references/' then
      SawRef := True;
  end;
  AssertTrue('the scripts dir is listed', SawScript);
  AssertTrue('the references dir is listed', SawRef);
  AssertFalse('listing is not truncated', Skills[0].ResourcesTruncated);
end;

procedure TSkillsFilesTest.TestScanRespectsTheDirectoryBound;
var
  Skills: TSkillFileArray;
  I: Integer;
begin
  { A bound that truncates rather than hangs. Depth 1 here means only the root's
    immediate children are considered. }
  for I := 0 to 4 do
    WriteSkill('skill' + IntToStr(I),
      '---'#10'name: skill' + IntToStr(I) + #10'description: d'#10'---'#10'x');
  Skills := ScanSkillsDir(FDir, skProject, 1, 1);
  AssertTrue('the bound cut the scan short', Length(Skills) <= 1);
end;

procedure TSkillsFilesTest.TestScanOfAMissingRootIsEmpty;
var
  Skills: TSkillFileArray;
begin
  Skills := ScanSkillsDir(IncludeTrailingPathDelimiter(FDir) + 'nope', skProject);
  AssertEquals('nothing', 0, Length(Skills));
end;

procedure TSkillsFilesTest.TestImportAddsAValidSkill;
var
  Reg: TSkillRegistry;
  Skills: TSkillFileArray;
  Shadowed: TStringArray;
  N: Integer;
begin
  WriteSkill('pdf-processing',
    '---'#10'name: pdf-processing'#10'description: Extract PDF text.'#10'---'#10 +
    'Follow these steps.');
  Skills := ScanSkillsDir(FDir, skProject);
  Reg := TSkillRegistry.Create;
  try
    N := ImportSkills(Reg, Skills, Shadowed);
    AssertEquals('one imported', 1, N);
    AssertEquals('no shadowing', 0, Length(Shadowed));
    AssertEquals('unloaded', Ord(ssUnloaded),
      Ord(Reg.StateOf('pdf_processing')));
    AssertEquals('the body became the instructions', 'Follow these steps.',
      Reg.InstructionsOf('pdf_processing'));
  finally
    Reg.Free;
  end;
end;

procedure TSkillsFilesTest.TestImportSkipsAnInvalidSkill;
var
  Reg: TSkillRegistry;
  Skills: TSkillFileArray;
  Shadowed: TStringArray;
  N: Integer;
begin
  WriteSkill('bad-name',
    '---'#10'name: BAD'#10'description: bad'#10'---'#10'x');
  Skills := ScanSkillsDir(FDir, skProject);
  Reg := TSkillRegistry.Create;
  try
    N := ImportSkills(Reg, Skills, Shadowed);
    AssertEquals('nothing imported', 0, N);
  finally
    Reg.Free;
  end;
end;

procedure TSkillsFilesTest.TestImportDerivesASnakeCaseKey;
var
  Reg: TSkillRegistry;
  Skills: TSkillFileArray;
  Shadowed: TStringArray;
begin
  WriteSkill('pdf-processing',
    '---'#10'name: pdf-processing'#10'description: d'#10'---'#10'x');
  Skills := ScanSkillsDir(FDir, skProject);
  Reg := TSkillRegistry.Create;
  try
    ImportSkills(Reg, Skills, Shadowed);
    { The key is an approval-ref and tool-namespace token, so hyphens cannot
      survive. Deterministic, so a rescan keeps the same approval. }
    AssertEquals('snake case', 'pdf_processing', Reg.Keys[0]);
    AssertEquals('the spec name is preserved verbatim',
      'pdf-processing', Reg.NameOf('pdf_processing'));
  finally
    Reg.Free;
  end;
end;

procedure TSkillsFilesTest.TestProjectScopeShadowsUserScope;
var
  Reg: TSkillRegistry;
  Skills: TSkillFileArray;
  Shadowed: TStringArray;
  N: Integer;
begin
  { The spec's universal convention: project skills override user skills. The
    shadowed one is NAMED, because silent shadowing is how an operator loses an
    hour. }
  SetLength(Skills, 2);
  Skills[0] := Default(TSkillFile);
  Skills[0].Name := 'code-review';
  Skills[0].Description := 'project version';
  Skills[0].Scope := skProject;
  Skills[1] := Default(TSkillFile);
  Skills[1].Name := 'code-review';
  Skills[1].Description := 'user version';
  Skills[1].Scope := skUser;

  Reg := TSkillRegistry.Create;
  try
    N := ImportSkills(Reg, Skills, Shadowed);
    AssertEquals('one imported', 1, N);
    AssertEquals('the shadowed one is reported', 1, Length(Shadowed));
    AssertTrue('and named: ' + Shadowed[0], Pos('code-review', Shadowed[0]) > 0);
    AssertEquals('the project version won', 'project version',
      Reg.SkillOf('code_review').Description);
  finally
    Reg.Free;
  end;
end;

procedure TSkillsFilesTest.TestImportCarriesLocationAndResources;
var
  Reg: TSkillRegistry;
  Skills: TSkillFileArray;
  Shadowed: TStringArray;
  S: TSkill;
begin
  WriteSkill('with-files',
    '---'#10'name: with-files'#10'description: d'#10'---'#10'x');
  ForceDirectories(IncludeTrailingPathDelimiter(FDir) + 'with-files/scripts');
  Skills := ScanSkillsDir(FDir, skProject);
  Reg := TSkillRegistry.Create;
  try
    ImportSkills(Reg, Skills, Shadowed);
    S := Reg.SkillOf('with_files');
    AssertTrue('location is carried', S.Location <> '');
    AssertTrue('the location is the skill dir', Pos('with-files', S.Location) > 0);
    AssertTrue('resources are carried', Length(S.Resources) > 0);
  finally
    Reg.Free;
  end;
end;

initialization
  RegisterTest(TSkillsFilesTest);

end.
