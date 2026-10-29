unit test_shell_isolation;
{ The isolation gate for the shell library: nothing in src/shell may name a
  hildi.* unit in a uses clause. (The `make shell-standalone` build
  is the stronger check; this catches a dependency added later.) }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TShellIsolationTest = class(TTestCase)
  published
    procedure TestLibraryHasUnits;
    procedure TestLibraryUsesNoHarnessUnit;
  end;

implementation

const
  ShellSourceDir = 'src/shell';

function UsesClauseNamesHarness(const APath: string): Boolean;
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
      begin
        S := Trim(Copy(S, 5, MaxInt));
        InUses := True;
      end;
      if InUses then
      begin
        if Pos('hildi.', LowerCase(S)) > 0 then
          Exit(True);
        if Pos(';', S) > 0 then
          InUses := False;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TShellIsolationTest.TestLibraryHasUnits;
var
  R: TSearchRec;
  Count: Integer;
begin
  Count := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ShellSourceDir) + '*.pas',
    faAnyFile, R) = 0 then
  try
    repeat
      if (R.Name <> '.') and (R.Name <> '..') then
        Inc(Count);
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
  AssertTrue('src/shell has units', Count >= 5);
end;

procedure TShellIsolationTest.TestLibraryUsesNoHarnessUnit;
var
  R: TSearchRec;
  Path: string;
begin
  AssertTrue('src/shell is readable from ' + GetCurrentDir,
    DirectoryExists(ShellSourceDir));
  if FindFirst(IncludeTrailingPathDelimiter(ShellSourceDir) + '*.pas',
    faAnyFile, R) = 0 then
  try
    repeat
      if (R.Name = '.') or (R.Name = '..') then
        Continue;
      Path := IncludeTrailingPathDelimiter(ShellSourceDir) + R.Name;
      AssertFalse('harness unit reachable from ' + R.Name,
        UsesClauseNamesHarness(Path));
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
end;

initialization
  RegisterTest(TShellIsolationTest);
end.
