unit test_workspace_snapshot;
{ fpcunit tests for hildegard.helper.workspace.snapshot: the ignore-aware
  before/after tree diff that gives the process tier the file changes the
  builtin tier records directly. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.gitignore, hildegard.helper.workspace.changes,
  hildegard.helper.workspace.snapshot;

type
  TWorkspaceSnapshotTest = class(TTestCase)
  private
    FRoot: string;
    function Full(const ARel: string): string;
    procedure WriteText(const ARel, AText: string);
    procedure WriteBlob(const ARel: string; ASize: Integer);
    function Diff: TFileChangeSet;
    function Find(const ASet: TFileChangeSet; const ARel: string): TFileChange;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestUnchangedTreeReportsNothing;
    procedure TestCreatedModifiedDeleted;
    procedure TestDeletedFileKeepsItsSizeOnly;
    procedure TestLargeFileIsSizeOnly;
    procedure TestIgnoredPathsAreNotReported;
    procedure TestNestedGitignoreAppliesToItsDirectory;
    procedure TestGitDirectoryIsSkipped;
    procedure TestDirectoryCreation;
  end;

implementation

procedure RemoveTree(const APath: string);
var
  SR: TSearchRec;
  Full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        Full := IncludeTrailingPathDelimiter(APath) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          RemoveTree(Full)
        else
          DeleteFile(Full);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(APath);
end;

procedure TWorkspaceSnapshotTest.SetUp;
begin
  FRoot := IncludeTrailingPathDelimiter(GetTempDir) + 'hhsnap_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  ForceDirectories(FRoot);
end;

procedure TWorkspaceSnapshotTest.TearDown;
begin
  RemoveTree(FRoot);
end;

function TWorkspaceSnapshotTest.Full(const ARel: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + ARel;
end;

procedure TWorkspaceSnapshotTest.WriteText(const ARel, AText: string);
var
  Fs: TFileStream;
begin
  ForceDirectories(ExtractFileDir(Full(ARel)));
  Fs := TFileStream.Create(Full(ARel), fmCreate);
  try
    if AText <> '' then
      Fs.WriteBuffer(AText[1], Length(AText));
  finally
    Fs.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.WriteBlob(const ARel: string; ASize: Integer);
var
  Fs: TFileStream;
  Chunk: string;
begin
  ForceDirectories(ExtractFileDir(Full(ARel)));
  Chunk := StringOfChar('x', 4096);
  Fs := TFileStream.Create(Full(ARel), fmCreate);
  try
    while ASize > 0 do
    begin
      if ASize >= Length(Chunk) then
      begin
        Fs.WriteBuffer(Chunk[1], Length(Chunk));
        Dec(ASize, Length(Chunk));
      end
      else
      begin
        Fs.WriteBuffer(Chunk[1], ASize);
        ASize := 0;
      end;
    end;
  finally
    Fs.Free;
  end;
end;

{ A diff of a fresh snapshot against another, both taken now. }
function TWorkspaceSnapshotTest.Diff: TFileChangeSet;
var
  Before: TWorkspaceSnapshot;
begin
  Result := TFileChangeSet.Create;
  Before := TakeSnapshot(FRoot);
  try
    DiffSnapshots(Before, TakeSnapshot(FRoot), Result);
  finally
    Before.Free;
  end;
end;

function TWorkspaceSnapshotTest.Find(const ASet: TFileChangeSet;
  const ARel: string): TFileChange;
var
  I: Integer;
begin
  Result := Default(TFileChange);
  Result.Path := '';
  for I := 0 to ASet.Count - 1 do
    if ASet[I].Path = ARel then
      Exit(ASet[I]);
end;

procedure TWorkspaceSnapshotTest.TestUnchangedTreeReportsNothing;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
begin
  WriteText('a.txt', 'one' + #10);
  WriteText('src/b.pas', 'program b;' + #10);
  Before := TakeSnapshot(FRoot);
  try
    { Directories are entries too (so a created or deleted one is reported). }
    AssertEquals('the dir and two files', 3, Before.Count);
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('no changes', 0, Changes.Count);
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestCreatedModifiedDeleted;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
  C: TFileChange;
begin
  WriteText('keep.txt', 'keep' + #10);
  WriteText('edit.txt', 'old' + #10);
  WriteText('gone.txt', 'bye' + #10);
  Before := TakeSnapshot(FRoot);
  try
    WriteText('edit.txt', 'new and longer' + #10);
    WriteText('fresh.txt', 'hello' + #10);
    DeleteFile(Full('gone.txt'));
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('three changes', 3, Changes.Count);
        AssertEquals('created', Ord(fcCreated), Ord(Find(Changes, 'fresh.txt').Kind));
        AssertEquals('created content', 'hello' + #10,
          Find(Changes, 'fresh.txt').After);
        AssertTrue('created captured', Find(Changes, 'fresh.txt').Captured);
        AssertEquals('modified', Ord(fcModified), Ord(Find(Changes, 'edit.txt').Kind));
        AssertEquals('modified after', 'new and longer' + #10,
          Find(Changes, 'edit.txt').After);
        AssertEquals('modified after size', 15,
          Find(Changes, 'edit.txt').AfterSize);
        C := Find(Changes, 'gone.txt');
        AssertEquals('deleted', Ord(fcDeleted), Ord(C.Kind));
        AssertEquals('deleted size', 4, C.BeforeSize);
        AssertTrue('keep is untouched', Find(Changes, 'keep.txt').Path = '');
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestDeletedFileKeepsItsSizeOnly;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
  C: TFileChange;
begin
  WriteText('a.txt', 'abcdef' + #10);
  Before := TakeSnapshot(FRoot);
  try
    DeleteFile(Full('a.txt'));
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        C := Find(Changes, 'a.txt');
        AssertEquals('deleted', Ord(fcDeleted), Ord(C.Kind));
        AssertEquals('size kept', 7, C.BeforeSize);
        AssertFalse('content is gone', C.Captured);
        AssertEquals('no content', '', C.Before);
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestLargeFileIsSizeOnly;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
  C: TFileChange;
begin
  WriteText('small.txt', 'x' + #10);
  Before := TakeSnapshot(FRoot);
  try
    WriteBlob('big.bin', MaxCapturedChangeBytes + 10);
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        C := Find(Changes, 'big.bin');
        AssertEquals('created', Ord(fcCreated), Ord(C.Kind));
        AssertFalse('too big to capture', C.Captured);
        AssertEquals('size recorded', MaxCapturedChangeBytes + 10, C.AfterSize);
        AssertEquals('no content', '', C.After);
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestIgnoredPathsAreNotReported;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
begin
  WriteText('.gitignore', 'build/' + #10 + '*.log' + #10);
  WriteText('build/out.txt', 'one' + #10);
  WriteText('run.log', 'one' + #10);
  Before := TakeSnapshot(FRoot);
  try
    AssertEquals('only .gitignore is tracked', 1, Before.Count);
    WriteText('build/out.txt', 'two, longer' + #10);
    WriteText('build/new.txt', 'new' + #10);
    WriteText('run.log', 'two, longer' + #10);
    WriteText('trace.log', 'new' + #10);
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('ignored edits are not changes', 0, Changes.Count);
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestNestedGitignoreAppliesToItsDirectory;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
begin
  WriteText('src/.gitignore', '*.tmp' + #10);
  WriteText('src/a.tmp', 'one' + #10);
  WriteText('src/a.pas', 'one' + #10);
  WriteText('b.tmp', 'one' + #10);
  Before := TakeSnapshot(FRoot);
  try
    { src/, src/.gitignore, src/a.pas and b.tmp; src/a.tmp is ignored. }
    AssertEquals('everything but the nested .tmp', 4, Before.Count);
    WriteText('src/a.tmp', 'two, longer' + #10);
    WriteText('src/a.pas', 'two, longer' + #10);
    WriteText('b.tmp', 'two, longer' + #10);
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('two changes', 2, Changes.Count);
        AssertTrue('the sibling .tmp is not covered by src/.gitignore',
          Find(Changes, 'b.tmp').Path <> '');
        AssertTrue('the source file is reported',
          Find(Changes, 'src/a.pas').Path <> '');
        AssertTrue('the ignored one is not',
          Find(Changes, 'src/a.tmp').Path = '');
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestGitDirectoryIsSkipped;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
begin
  WriteText('.git/config', 'one' + #10);
  WriteText('a.txt', 'one' + #10);
  Before := TakeSnapshot(FRoot);
  try
    AssertEquals('only the working file', 1, Before.Count);
    WriteText('.git/config', 'two, longer' + #10);
    WriteText('.git/HEAD', 'ref' + #10);
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('git churn is not a change', 0, Changes.Count);
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

procedure TWorkspaceSnapshotTest.TestDirectoryCreation;
var
  Before, After: TWorkspaceSnapshot;
  Changes: TFileChangeSet;
  C: TFileChange;
begin
  Before := TakeSnapshot(FRoot);
  try
    ForceDirectories(Full('new/sub'));
    After := TakeSnapshot(FRoot);
    try
      Changes := TFileChangeSet.Create;
      try
        DiffSnapshots(Before, After, Changes);
        AssertEquals('two directories', 2, Changes.Count);
        C := Find(Changes, 'new');
        AssertEquals('created', Ord(fcCreated), Ord(C.Kind));
        AssertTrue('a directory', C.IsDir);
        AssertTrue('captured (nothing to read)', C.Captured);
        AssertTrue('the nested one too', Find(Changes, 'new/sub').Path <> '');
      finally
        Changes.Free;
      end;
    finally
      After.Free;
    end;
  finally
    Before.Free;
  end;
end;

initialization
  RegisterTest(TWorkspaceSnapshotTest);
end.
