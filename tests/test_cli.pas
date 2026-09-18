unit test_cli;
{ fpcunit tests for hildegard.helper.cli (pure argument parsing). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, hildegard.helper.cli;

type
  TCLITest = class(TTestCase)
  private
    function Raises(const AArgs: array of string): Boolean;
  published
    procedure TestDefaultsToInteractive;
    procedure TestPromptImpliesOnce;
    procedure TestPositionalPrompt;
    procedure TestDashPromptReadsStdin;
    procedure TestNoReasoningAndNoToolsFlags;
    procedure TestMaxTpsFlag;
    procedure TestColorFlagsSetTriState;
    procedure TestModelSystemEndpointFlags;
    procedure TestLongFlagsWithEquals;
    procedure TestHelpFlag;
    procedure TestUnknownOptionRaises;
    procedure TestMissingValueRaises;
  end;

implementation

function TCLITest.Raises(const AArgs: array of string): Boolean;
begin
  try
    ParseCLIOptions(AArgs);
    Result := False;
  except
    on E: ECLIError do
      Result := True;
  end;
end;

procedure TCLITest.TestDefaultsToInteractive;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions([]);
  AssertEquals('interactive', Ord(cmInteractive), Ord(O.Mode));
  AssertTrue('show user', O.ShowUser);
  AssertTrue('show tools', O.ShowTools);
  AssertEquals('reasoning default', Ord(tsDefault), Ord(O.Reasoning));
  AssertEquals('color default', Ord(tsDefault), Ord(O.ColorMode));
  AssertEquals('no rate limit', 0, O.MaxTokensPerSecond);
end;

procedure TCLITest.TestPromptImpliesOnce;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['-p', 'what time is it']);
  AssertEquals('once', Ord(cmOnce), Ord(O.Mode));
  AssertEquals('prompt', 'what time is it', O.Prompt);
  AssertFalse('not from stdin', O.PromptFromStdin);
end;

procedure TCLITest.TestPositionalPrompt;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['do a thing']);
  AssertEquals('once', Ord(cmOnce), Ord(O.Mode));
  AssertEquals('prompt', 'do a thing', O.Prompt);
end;

procedure TCLITest.TestDashPromptReadsStdin;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['-p', '-']);
  AssertEquals('once', Ord(cmOnce), Ord(O.Mode));
  AssertTrue('from stdin', O.PromptFromStdin);
  AssertEquals('empty prompt', '', O.Prompt);
end;

procedure TCLITest.TestNoReasoningAndNoToolsFlags;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['--no-reasoning', '--no-tools']);
  AssertEquals('reasoning off', Ord(tsOff), Ord(O.Reasoning));
  AssertFalse('tools off', O.ShowTools);
end;

procedure TCLITest.TestMaxTpsFlag;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['--max-tps', '25']);
  AssertEquals('space form', 25, O.MaxTokensPerSecond);
  O := ParseCLIOptions(['--max-tps=50']);
  AssertEquals('equals form', 50, O.MaxTokensPerSecond);
  AssertTrue('negative rejected', Raises(['--max-tps', '-1']));
end;

procedure TCLITest.TestColorFlagsSetTriState;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['--color']);
  AssertEquals('on', Ord(tsOn), Ord(O.ColorMode));
  O := ParseCLIOptions(['--no-color']);
  AssertEquals('off', Ord(tsOff), Ord(O.ColorMode));
end;

procedure TCLITest.TestModelSystemEndpointFlags;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['-m', 'model-x', '-s', 'be terse', '--endpoint',
    'https://e/x']);
  AssertEquals('model', 'model-x', O.Model);
  AssertEquals('system', 'be terse', O.SystemPrompt);
  AssertEquals('endpoint', 'https://e/x', O.Endpoint);
end;

procedure TCLITest.TestLongFlagsWithEquals;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['--model=x', '--system=y', '--endpoint=z',
    '--prompt=hi']);
  AssertEquals('model', 'x', O.Model);
  AssertEquals('system', 'y', O.SystemPrompt);
  AssertEquals('endpoint', 'z', O.Endpoint);
  AssertEquals('prompt', 'hi', O.Prompt);
end;

procedure TCLITest.TestHelpFlag;
var
  O: TCLIOptions;
begin
  O := ParseCLIOptions(['-h']);
  AssertTrue('help', O.Help);
end;

procedure TCLITest.TestUnknownOptionRaises;
begin
  AssertTrue('unknown', Raises(['--bogus']));
end;

procedure TCLITest.TestMissingValueRaises;
begin
  AssertTrue('missing value', Raises(['-p']));
end;

initialization
  RegisterTest(TCLITest);
end.
