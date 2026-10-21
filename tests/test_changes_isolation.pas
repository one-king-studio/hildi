unit test_changes_isolation;
{ The isolation gate for the changes library: nothing in src/changes may name a
  hildegard.helper.* unit in a uses clause. (The `make changes-standalone` build
  is the stronger check; this catches a dependency added later.) }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TChangesIsolationTest = class(TTestCase)
  published
    procedure TestLibraryHasUnits;
    procedure TestLibraryUsesNoHarnessUnit;
    procedure TestLibraryUsesNoSqlite;
  end;

implementation

const
  ChangesSourceDir = 'src/changes';

function UsesClauseNames(const APath, APrefix: string): Boolean;
var
  Lines: TStringList;
  I, P: Integer;
  S, Lower: string;
  InUses: Boolean;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    InUses := False;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      P := Pos('//', S);
      if P > 0 then
        S := Trim(Copy(S, 1, P - 1));
      Lower := LowerCase(S);
      if (not InUses) and (Pos('uses', Lower) = 1) then
        InUses := True;
      if InUses then
      begin
        if Pos(LowerCase(APrefix), Lower) > 0 then
          Exit(True);
        if Pos(';', S) > 0 then
          InUses := False;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function SourceFiles: TStringList;
var
  SR: TSearchRec;
begin
  Result := TStringList.Create;
  if FindFirst(ChangesSourceDir + PathDelim + '*.pas', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
          Result.Add(ChangesSourceDir + PathDelim + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TChangesIsolationTest.TestLibraryHasUnits;
var
  Files: TStringList;
begin
  Files := SourceFiles;
  try
    AssertTrue('the library has units', Files.Count >= 4);
  finally
    Files.Free;
  end;
end;

procedure TChangesIsolationTest.TestLibraryUsesNoHarnessUnit;
var
  Files: TStringList;
  I: Integer;
begin
  Files := SourceFiles;
  try
    for I := 0 to Files.Count - 1 do
      AssertFalse(Files[I] + ' must not use a harness unit',
        UsesClauseNames(Files[I], 'hildegard.helper'));
  finally
    Files.Free;
  end;
end;

procedure TChangesIsolationTest.TestLibraryUsesNoSqlite;
var
  Files: TStringList;
  I: Integer;
begin
  { Persistence is the consumer's, through IChangeStore. A library that opened a
    database itself could not be lifted or tested without one. }
  Files := SourceFiles;
  try
    for I := 0 to Files.Count - 1 do
    begin
      AssertFalse(Files[I] + ' must not use sqlite',
        UsesClauseNames(Files[I], 'sqlite'));
      AssertFalse(Files[I] + ' must not use the store',
        UsesClauseNames(Files[I], 'hildegard.helper.store'));
    end;
  finally
    Files.Free;
  end;
end;

initialization
  RegisterTest(TChangesIsolationTest);
end.
