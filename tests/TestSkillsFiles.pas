unit TestSkillsFiles;
{ fpcunit tests for HildiSkillsFiles: SKILL.md frontmatter parsing, the spec's
  naming and length rules, and bounded discovery. Pure - no registry, no store,
  no loop. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiSkillsFiles;

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

initialization
  RegisterTest(TSkillsFilesTest);

end.
