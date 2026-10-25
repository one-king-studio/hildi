unit test_changes_revert;
{ fpcunit tests for the filesystem half of revert: reading the file, comparing
  against the record, applying the inverse, and writing atomically. Real files in
  a temp directory, because the point of this unit is precisely the I/O. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  changes.types, changes.text, changes.log,
  hildegard.helper.hash,
  hildegard.helper.changes.revert;

type
  TShaHasher = class
  public
    function OfText(const AText: string): string;
  end;

  TChangesRevertTest = class(TTestCase)
  private
    FDir: string;
    FHasher: TShaHasher;
    function WriteFile(const AName, AContent: string): string;
    function RecordFor(const APath, ABefore, AAfter: string): TChangeRecord;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRevertRestoresTheFileOnDisk;
    procedure TestRevertRefusesAFileThatMovedSince;
    procedure TestRevertSkipsARecordWithNoPatch;
    procedure TestRevertRefusesAPathOutsideTheWorkspace;
    procedure TestRevertRefusesAFileAboveTheReadLimit;
  end;

implementation

function TShaHasher.OfText(const AText: string): string;
begin
  Result := Sha256Hex(AText);
end;

procedure TChangesRevertTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-revert-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FHasher := TShaHasher.Create;
end;

procedure TChangesRevertTest.TearDown;
begin
  FHasher.Free;
  FHasher := nil;
  DeleteFile(IncludeTrailingPathDelimiter(FDir) + 'a.txt');
  RemoveDir(FDir);
end;

function TChangesRevertTest.WriteFile(const AName, AContent: string): string;
var
  Fs: TFileStream;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + AName;
  Fs := TFileStream.Create(Result, fmCreate);
  try
    if AContent <> '' then
      Fs.WriteBuffer(AContent[1], Length(AContent));
  finally
    Fs.Free;
  end;
end;

function TChangesRevertTest.RecordFor(const APath, ABefore, AAfter: string):
  TChangeRecord;
var
  Capped: Boolean;
begin
  Result := Default(TChangeRecord);
  Result.Path := APath;
  Result.Kind := ckModified;
  Result.BeforeHash := FHasher.OfText(ABefore);
  Result.AfterHash := FHasher.OfText(AAfter);
  Result.Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes, Capped);
  Result.PatchBytes := Length(Result.Patch);
  Result.Capped := Capped;
end;

procedure TChangesRevertTest.TestRevertRestoresTheFileOnDisk;
var
  Before, After: string;
  R: TChangeRecord;
  Res: TRevertResult;
  Fs: TFileStream;
  Got: string;
begin
  { The whole point: a file on disk, edited, then reverted back. }
  Before := 'one'#10'two'#10'three'#10;
  After := 'one'#10'TWO'#10'three'#10;
  WriteFile('a.txt', After);
  R := RecordFor('a.txt', Before, After);

  AssertTrue('revert ran', RevertRecord(FDir, R, FHasher.OfText, 0, Res));
  AssertEquals('outcome', Ord(rvReverted), Ord(Res.Outcome));
  AssertEquals('no detail on success', '', Res.Detail);

  Fs := TFileStream.Create(IncludeTrailingPathDelimiter(FDir) + 'a.txt',
    fmOpenRead);
  try
    SetLength(Got, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Got[1], Fs.Size);
  finally
    Fs.Free;
  end;
  AssertEquals('the file is back to the original', Before, Got);
end;

procedure TChangesRevertTest.TestRevertRefusesAFileThatMovedSince;
var
  Before, After: string;
  R: TChangeRecord;
  Res: TRevertResult;
  Fs: TFileStream;
  Got: string;
begin
  { Someone edited the file after the record was written. Reverting would
    silently discard that work, so it must refuse and touch nothing. }
  Before := 'one'#10;
  After := 'TWO'#10;
  WriteFile('a.txt', 'something else entirely'#10);
  R := RecordFor('a.txt', Before, After);

  AssertTrue('ran', RevertRecord(FDir, R, FHasher.OfText, 0, Res));
  AssertEquals('refused', Ord(rvMoved), Ord(Res.Outcome));
  AssertTrue('says why: ' + Res.Detail, Pos('changed', Res.Detail) > 0);

  Fs := TFileStream.Create(IncludeTrailingPathDelimiter(FDir) + 'a.txt',
    fmOpenRead);
  try
    SetLength(Got, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Got[1], Fs.Size);
  finally
    Fs.Free;
  end;
  AssertEquals('the file is untouched', 'something else entirely'#10, Got);
end;

procedure TChangesRevertTest.TestRevertSkipsARecordWithNoPatch;
var
  R: TChangeRecord;
  Res: TRevertResult;
begin
  { The process tier records sizes with no patch. That is not a failure - it is
    a record that cannot be reverted, and reporting it as a failure would bury
    the ones that can. }
  R := Default(TChangeRecord);
  R.Path := 'a.txt';
  R.Kind := ckModified;
  WriteFile('a.txt', 'whatever'#10);
  AssertTrue('ran', RevertRecord(FDir, R, FHasher.OfText, 0, Res));
  AssertEquals('skipped', Ord(rvSkipped), Ord(Res.Outcome));
  AssertTrue('and says why', Pos('no patch', Res.Detail) > 0);
end;

procedure TChangesRevertTest.TestRevertRefusesAPathOutsideTheWorkspace;
var
  Before, After: string;
  R: TChangeRecord;
  Res: TRevertResult;
begin
  { A record names a path; a corrupt or hand-edited row must not be able to
    write outside the root. Refused before anything is read. }
  Before := 'x'#10;
  After := 'y'#10;
  R := RecordFor('../escaped.txt', Before, After);
  AssertTrue('ran', RevertRecord(FDir, R, FHasher.OfText, 0, Res));
  AssertEquals('refused', Ord(rvUnsafe), Ord(Res.Outcome));
  AssertTrue('says why', Pos('outside', Res.Detail) > 0);
end;

procedure TChangesRevertTest.TestRevertRefusesAFileAboveTheReadLimit;
var
  Before, After: string;
  R: TChangeRecord;
  Res: TRevertResult;
begin
  { A partial read cannot be verified, so an oversized file is refused rather
    than reverted on incomplete evidence. }
  Before := 'one'#10;
  After := 'two'#10;
  WriteFile('a.txt', After);
  R := RecordFor('a.txt', Before, After);
  { The limit is BELOW the file size on purpose: 'two'#10 is 4 bytes, so a limit
    of 3 refuses. A limit equaled by the size is within the limit and reverts. }
  AssertTrue('ran', RevertRecord(FDir, R, FHasher.OfText, 3, Res));
  AssertEquals('refused', Ord(rvUnsafe), Ord(Res.Outcome));
  AssertTrue('says why: ' + Res.Detail, Pos('limit', Res.Detail) > 0);
end;

initialization
  RegisterTest(TChangesRevertTest);
end.
