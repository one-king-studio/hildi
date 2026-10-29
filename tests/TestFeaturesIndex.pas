unit TestFeaturesIndex;
{ Asserts that docs/features/FEATURES.md and the directory tree agree.

  Why a test and not a script: the audit that caught four real defects lived in
  gitignored build/ and did not survive a clone. An index that drifts is a slow,
  quiet failure - a feature is renamed, a directory is added, a status is typed
  by hand - and nothing notices until someone reads the wrong page.

  This walks the tree the way TestSplit walks `uses`: source-level, no build
  dependency, no network. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry;

type
  TFeaturesIndexTest = class(TTestCase)
  private
    FLines: TStringList;
    { The index row for a directory, or '' when there is none. }
    function RowFor(const ADir: string): string;
    { The directory a row's link points at. }
    function DirOfRow(const ARow: string): string;
    { The Status column of a row, trimmed, parenthetical removed. }
    function StatusOfRow(const ARow: string): string;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { The invariant a new feature breaks first: it is added and not listed. }
    procedure TestEveryFeatureDirectoryHasAnIndexRow;
    { The other direction: a row whose link points at nothing. }
    procedure TestEveryIndexLinkResolvesToAFile;
    { The Status Key defines six values; a typo or a seventh is drift. }
    procedure TestEveryStatusIsOneOfTheDefinedValues;
    { Two rows for one feature is how a stale row survives a rename. }
    procedure TestNoFeatureIsListedTwice;
    { A directory with no artifact at all is a placeholder, not a feature. }
    procedure TestEveryFeatureDirectoryHasAnArtifact;
    { A TODO left behind after its own DONE is stale scaffolding: the plan says
      finished in one file and underway in another. This is the drift I created
      and then cleaned up when closing the Task List. }
    procedure TestNoTodoSurvivesItsOwnDone;
  end;

implementation

const
  FeaturesDir = 'docs/features';
  IndexFile = FeaturesDir + '/FEATURES.md';
  { The Status Key's vocabulary. 'In Progress' has a space, so the prefix
    comparison is what the index actually supports. }
  LegalStatuses: array[0..5] of string = (
    'Proposed', 'Specified', 'In Progress', 'Implemented', 'Parked',
    'Superseded');

procedure TFeaturesIndexTest.SetUp;
begin
  FLines := TStringList.Create;
  AssertTrue('the index exists at ' + IndexFile, FileExists(IndexFile));
  FLines.LoadFromFile(IndexFile);
end;

procedure TFeaturesIndexTest.TearDown;
begin
  FLines.Free;
end;

function TFeaturesIndexTest.DirOfRow(const ARow: string): string;
var
  P, Q: Integer;
begin
  { The row's FIRST link is the feature's own directory: `| [Name](Dir/FILE.md)`. }
  Result := '';
  P := Pos('](', ARow);
  if P = 0 then
    Exit;
  Inc(P, 2);
  Q := Pos('/', ARow, P);
  if Q = 0 then
    Exit;
  Result := Copy(ARow, P, Q - P);
end;

function TFeaturesIndexTest.RowFor(const ADir: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FLines.Count - 1 do
    if Copy(FLines[I], 1, 3) = '| [' then
      if DirOfRow(FLines[I]) = ADir then
        Exit(FLines[I]);
end;

function TFeaturesIndexTest.StatusOfRow(const ARow: string): string;
var
  P, Q: Integer;
begin
  { Columns: | Feature | Status | Specs | Notes |. The Status is the text between
    the second and third pipe. A parenthetical is a qualifier, not the status:
    "Implemented (library)" is Implemented. }
  Result := '';
  P := Pos('|', ARow);
  if P = 0 then
    Exit;
  P := Pos('|', ARow, P + 1);
  if P = 0 then
    Exit;
  Q := Pos('|', ARow, P + 1);
  if Q = 0 then
    Exit;
  Result := Trim(Copy(ARow, P + 1, Q - P - 1));
  P := Pos('(', Result);
  if P > 0 then
    Result := Trim(Copy(Result, 1, P - 1));
end;

{ Every feature directory: a subdirectory of docs/features not starting with an
  underscore (those are working notes, not features). }
procedure CollectDirs(const AParent: string; ADirs: TStringList);
var
  SR: TSearchRec;
  Name: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(AParent) + '*', faDirectory, SR) <>
    0 then
    Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
        Continue;
      Name := SR.Name;
      if (Name = '.') or (Name = '..') then
        Continue;
      if Copy(Name, 1, 1) = '_' then
        Continue;
      ADirs.Add(Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure TFeaturesIndexTest.TestEveryFeatureDirectoryHasAnIndexRow;
var
  Dirs: TStringList;
  I: Integer;
begin
  AssertTrue('the features dir exists', DirectoryExists(FeaturesDir));
  Dirs := TStringList.Create;
  try
    CollectDirs(FeaturesDir, Dirs);
    { A walk that finds nothing would pass every assertion below. }
    AssertTrue('the walk found feature directories', Dirs.Count > 10);
    for I := 0 to Dirs.Count - 1 do
      AssertTrue(Dirs[I] + ' exists on disk but has no row in FEATURES.md',
        RowFor(Dirs[I]) <> '');
  finally
    Dirs.Free;
  end;
end;

procedure TFeaturesIndexTest.TestEveryIndexLinkResolvesToAFile;
var
  I, P, Q, Checked: Integer;
  Line, Target, Full: string;
begin
  Checked := 0;
  for I := 0 to FLines.Count - 1 do
  begin
    Line := FLines[I];
    P := 1;
    while True do
    begin
      P := PosEx('](', Line, P);
      if P = 0 then
        Break;
      Q := PosEx(')', Line, P);
      if Q = 0 then
        Break;
      Target := Copy(Line, P + 2, Q - P - 2);
      Inc(P, 2);
      { An absolute URL is not a file. }
      if (Pos('://', Target) > 0) or (Target = '') then
        Continue;
      Inc(Checked);
      Full := IncludeTrailingPathDelimiter(FeaturesDir) + Target;
      AssertTrue('FEATURES.md links to a file that is not there: ' + Target,
        FileExists(Full));
    end;
  end;
  AssertTrue('links were actually checked', Checked > 20);
end;

procedure TFeaturesIndexTest.TestEveryStatusIsOneOfTheDefinedValues;
var
  I, J, Rows: Integer;
  Status: string;
  Ok: Boolean;
begin
  Rows := 0;
  for I := 0 to FLines.Count - 1 do
  begin
    if Copy(FLines[I], 1, 3) <> '| [' then
      Continue;
    Status := StatusOfRow(FLines[I]);
    Inc(Rows);
    Ok := False;
    for J := Low(LegalStatuses) to High(LegalStatuses) do
      if Status = LegalStatuses[J] then
        Ok := True;
    AssertTrue('status "' + Status + '" is not in the Status Key for: ' +
      FLines[I], Ok);
  end;
  AssertTrue('rows were actually checked', Rows > 10);
end;

procedure TFeaturesIndexTest.TestNoFeatureIsListedTwice;
var
  I, J: Integer;
  Dir: string;
begin
  for I := 0 to FLines.Count - 1 do
  begin
    if Copy(FLines[I], 1, 3) <> '| [' then
      Continue;
    Dir := DirOfRow(FLines[I]);
    if Dir = '' then
      Continue;
    for J := I + 1 to FLines.Count - 1 do
    begin
      if Copy(FLines[J], 1, 3) <> '| [' then
        Continue;
      { Two rows for one directory: the earlier one is stale and nothing says so. }
      AssertFalse(Dir + ' is listed twice in FEATURES.md',
        DirOfRow(FLines[J]) = Dir);
    end;
  end;
end;

procedure TFeaturesIndexTest.TestEveryFeatureDirectoryHasAnArtifact;
var
  Dirs, Files: TStringList;
  I, Count: Integer;
  SR: TSearchRec;
  Full: string;
begin
  Dirs := TStringList.Create;
  Files := TStringList.Create;
  try
    CollectDirs(FeaturesDir, Dirs);
    for I := 0 to Dirs.Count - 1 do
    begin
      Full := IncludeTrailingPathDelimiter(FeaturesDir) +
        IncludeTrailingPathDelimiter(Dirs[I]);
      Count := 0;
      if FindFirst(Full + '*', faAnyFile, SR) = 0 then
      begin
        try
          repeat
            if (SR.Name <> '.') and (SR.Name <> '..') and
               ((SR.Attr and faDirectory) = 0) then
              Inc(Count);
          until FindNext(SR) <> 0;
        finally
          FindClose(SR);
        end;
      end;
      { An empty directory is a plan to have a plan. A feature needs at least
        one of FEATURE/SPEC/TODO/DONE. }
      AssertTrue(Dirs[I] + ' has no artifact at all', Count > 0);
    end;
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

function HasFile(const ADir, APattern: string): Boolean;
var
  SR: TSearchRec;
  Full: string;
begin
  Result := False;
  Full := IncludeTrailingPathDelimiter(FeaturesDir) +
    IncludeTrailingPathDelimiter(ADir) + APattern;
  if FindFirst(Full, faAnyFile, SR) = 0 then
  begin
    try
      Result := (SR.Name <> '.') and (SR.Name <> '..');
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TFeaturesIndexTest.TestNoTodoSurvivesItsOwnDone;
var
  Dirs: TStringList;
  I, J, Checked: Integer;
  SR: TSearchRec;
  Base, TodoPath, DirPath: string;
begin
  { A plan is *v1.TODO.md or *v1.DONE.md. When both exist for the same base, the
    plan was closed and the TODO is scaffolding nobody deleted. That is checkable
    and unambiguous; "a DONE.md exists so the whole feature is Implemented" is
    not - Agent_Loop has DONE.md files for v2 and sibling components while v1 is
    still genuinely in progress.}
  Dirs := TStringList.Create;
  try
    CollectDirs(FeaturesDir, Dirs);
    Checked := 0;
    for I := 0 to Dirs.Count - 1 do
    begin
      DirPath := IncludeTrailingPathDelimiter(FeaturesDir) +
        IncludeTrailingPathDelimiter(Dirs[I]);
      if FindFirst(DirPath + '*.DONE.md', faAnyFile, SR) <> 0 then
        Continue;
      try
        repeat
          if SR.Name = '.' then
            Continue;
          { `Foo_v1.DONE.md` -> base `Foo_v1`. }
          Base := Copy(SR.Name, 1, Length(SR.Name) - Length('.DONE.md'));
          TodoPath := DirPath + Base + '.TODO.md';
          Inc(Checked);
          AssertFalse(Dirs[I] + ' has both ' + Base + '.DONE.md and ' +
            Base + '.TODO.md - delete the TODO',
            FileExists(TodoPath));
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    AssertTrue('DONE.md files were actually found', Checked > 3);
  finally
    Dirs.Free;
  end;
end;

initialization
  RegisterTest(TFeaturesIndexTest);
end.
