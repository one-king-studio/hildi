program hildegard_helper_tests;
{ Console test runner for the hildegard-helper suite.

  Run all:        ./hildegard-helper-tests --all --format=plain
  List tests:     ./hildegard-helper-tests --list
  Run one suite:  ./hildegard-helper-tests --suite=TCommandRunnerTest --format=plain
  JUnit for CI:   ./hildegard-helper-tests --all --format=xml --file=results.xml }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, fpcunit, testregistry, consoletestrunner,
  test_hildegard_helper, test_store, test_llm;

var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Title := 'hildegard-helper test suite';
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
