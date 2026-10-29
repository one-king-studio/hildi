unit TestEnv;
{ fpcunit tests for HildiEnv. Parsing is tested purely; apply/load
  tests use a uniquely named variable cleared first. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ctypes, fpcunit, testregistry, HildiEnv;

type
  TEnvTest = class(TTestCase)
  published
    procedure TestParsesSimplePairs;
    procedure TestIgnoresCommentsAndBlankLines;
    procedure TestStripsExportPrefix;
    procedure TestTrimsWhitespaceAndQuotes;
    procedure TestKeepsEqualsInValue;
    procedure TestSkipsMalformedLines;
    procedure TestApplySkipsExistingEnvironment;
    procedure TestLoadMissingFileIsNoOp;
    procedure TestLoadAppliesNewVariable;

    { The rename moves the default store; without a fallback every existing
      session looks lost. These pin the decision, not the filesystem. }
    procedure TestStorePathPrefersEnvOverride;
    procedure TestStorePathPrefersNewWhenPresent;
    procedure TestStorePathFallsBackToLegacyWhenNewIsAbsent;
    procedure TestStorePathUsesNewWhenNeitherExists;
  end;

implementation

{$ifdef unix}
function c_setenv(Name, Value: PAnsiChar; Overwrite: cint): cint; cdecl;
  external 'c' name 'setenv';
function c_unsetenv(Name: PAnsiChar): cint; cdecl; external 'c' name 'unsetenv';
{$endif}

const
  TestVar = 'HILDI_TEST_ENV_A1B2';

procedure ClearTestVar;
begin
  {$ifdef unix}
  c_unsetenv(PAnsiChar(AnsiString(TestVar)));
  {$endif}
end;

procedure TEnvTest.TestParsesSimplePairs;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('A=1' + LineEnding + 'B=two');
  AssertEquals('two pairs', 2, Length(Pairs));
  AssertEquals('name a', 'A', Pairs[0].Name);
  AssertEquals('value a', '1', Pairs[0].Value);
  AssertEquals('name b', 'B', Pairs[1].Name);
  AssertEquals('value b', 'two', Pairs[1].Value);
end;

procedure TEnvTest.TestIgnoresCommentsAndBlankLines;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('# comment' + LineEnding + LineEnding +
    '   ' + LineEnding + 'K=v');
  AssertEquals('one pair', 1, Length(Pairs));
  AssertEquals('name', 'K', Pairs[0].Name);
end;

procedure TEnvTest.TestStripsExportPrefix;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('export K=v');
  AssertEquals('one pair', 1, Length(Pairs));
  AssertEquals('name', 'K', Pairs[0].Name);
  AssertEquals('value', 'v', Pairs[0].Value);
end;

procedure TEnvTest.TestTrimsWhitespaceAndQuotes;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('K = "hello world"' + LineEnding + 'S=' + #39 + 'x y' +
    #39);
  AssertEquals('name trimmed', 'K', Pairs[0].Name);
  AssertEquals('double quotes stripped', 'hello world', Pairs[0].Value);
  AssertEquals('single quotes stripped', 'x y', Pairs[1].Value);
end;

procedure TEnvTest.TestKeepsEqualsInValue;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('URL=https://x/?a=1&b=2');
  AssertEquals('one pair', 1, Length(Pairs));
  AssertEquals('value keeps equals', 'https://x/?a=1&b=2', Pairs[0].Value);
end;

procedure TEnvTest.TestSkipsMalformedLines;
var
  Pairs: TEnvPairArray;
begin
  Pairs := ParseDotEnv('NOEQUALS' + LineEnding + '=novalue' + LineEnding +
    'OK=1');
  AssertEquals('one valid pair', 1, Length(Pairs));
  AssertEquals('name', 'OK', Pairs[0].Name);
end;

procedure TEnvTest.TestApplySkipsExistingEnvironment;
var
  Pairs: TEnvPairArray;
begin
  ClearTestVar;
  {$ifdef unix}
  c_setenv(PAnsiChar(AnsiString(TestVar)), PAnsiChar(AnsiString('existing')), 1);
  {$endif}
  try
    Pairs := ParseDotEnv(TestVar + '=new');
    AssertEquals('nothing applied', 0, ApplyEnv(Pairs));
    AssertEquals('existing kept', 'existing', GetEnvironmentVariable(TestVar));
  finally
    ClearTestVar;
  end;
end;

procedure TEnvTest.TestLoadMissingFileIsNoOp;
begin
  AssertEquals('missing file', 0, LoadDotEnvFile('/no/such/.env'));
end;

procedure TEnvTest.TestLoadAppliesNewVariable;
var
  FileName: string;
  F: TStringList;
begin
  ClearTestVar;
  FileName := IncludeTrailingPathDelimiter(GetTempDir) +
    'hildi_env_test.env';
  F := TStringList.Create;
  try
    F.Add('# sample');
    F.Add(TestVar + '=loaded');
    F.SaveToFile(FileName);
  finally
    F.Free;
  end;
  try
    AssertEquals('one applied', 1, LoadDotEnvFile(FileName));
    AssertEquals('value set', 'loaded', GetEnvironmentVariable(TestVar));
  finally
    ClearTestVar;
    DeleteFile(FileName);
  end;
end;

procedure TEnvTest.TestStorePathPrefersEnvOverride;
begin
  AssertEquals('env wins over everything', '/custom/store.db',
    ResolveStorePath('/custom/store.db', '/home/u', False, True));
end;

procedure TEnvTest.TestStorePathPrefersNewWhenPresent;
begin
  AssertEquals('new store wins once it exists',
    '/home/u/.hildi/store.db',
    ResolveStorePath('', '/home/u', True, True));
end;

procedure TEnvTest.TestStorePathFallsBackToLegacyWhenNewIsAbsent;
begin
  AssertEquals('legacy store is still addressed',
    '/home/u/.hildegard-helper/store.db',
    ResolveStorePath('', '/home/u', False, True));
end;

procedure TEnvTest.TestStorePathUsesNewWhenNeitherExists;
begin
  AssertEquals('a fresh install uses the new path',
    '/home/u/.hildi/store.db',
    ResolveStorePath('', '/home/u', False, False));
end;

initialization
  RegisterTest(TEnvTest);
end.
