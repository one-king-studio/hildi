unit test_shell_tier_corpus;
{ How much of the recorded corpus the builtin tier actually handles today.

  This is an evidence gate, not a target: the tier is deliberately closed, so a
  script with `git` or `sed` falls back. The test pins the current coverage so a
  parser/pre-flight regression that silently loses whole commands is visible, and
  prints the number the coverage document cites. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.shell.commands, hildegard.helper.shell.tier;

type
  TShellTierCorpusTest = class(TTestCase)
  private
    function Decode(const ALine: string): string;
  published
    procedure TestCorpusCoverage;
  end;

implementation

const
  CorpusPath = 'tests/data/shell_corpus.txt';
  { Pinned when the coverage was recorded (see COMMAND_COVERAGE.md). }
  ExpectedTotal = 3255;
  MinSupported = 70;

function TShellTierCorpusTest.Decode(const ALine: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(ALine) do
  begin
    C := ALine[I];
    if C = '\' then
    begin
      Inc(I);
      if I <= Length(ALine) then
      begin
        if ALine[I] = 'n' then
          Result := Result + #10
        else if ALine[I] = 't' then
          Result := Result + #9
        else
          Result := Result + ALine[I];
      end;
    end
    else
      Result := Result + C;
    Inc(I);
  end;
end;

procedure TShellTierCorpusTest.TestCorpusCoverage;
var
  Lines: TStringList;
  I, Total, Supported, Declined, J: Integer;
  Why, Source: string;
  Reasons: TStringList;
begin
  AssertTrue('corpus fixture exists', FileExists(CorpusPath));
  Lines := TStringList.Create;
  Reasons := TStringList.Create;
  try
    Lines.LoadFromFile(CorpusPath);
    Total := 0;
    Supported := 0;
    Declined := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if (Lines[I] = '') or (Lines[I][1] = '#') then
        Continue;
      Source := Decode(Lines[I]);
      Inc(Total);
      if TierSupportsCommand(Source, Why) then
        Inc(Supported)
      else
      begin
        Inc(Declined);
        if Reasons.IndexOfName(Why) < 0 then
          Reasons.Add(Why + '=1')
        else
          Reasons[Reasons.IndexOfName(Why)] := Why + '=' +
            IntToStr(StrToIntDef(Reasons.Values[Why], 0) + 1);
      end;
    end;
    for J := 0 to Reasons.Count - 1 do
      if StrToIntDef(Reasons.ValueFromIndex[J], 0) >= 20 then
        WriteLn('  declined x', Reasons.ValueFromIndex[J], ': ',
          Reasons.Names[J]);
  finally
    Reasons.Free;
    Lines.Free;
  end;
  WriteLn('tier corpus coverage: ', Supported, '/', Total, ' = ',
    (Supported * 100) div Total, '%  (declined: ', Declined, ')');
  AssertEquals('corpus size matches the baseline', ExpectedTotal, Total);
  AssertTrue('coverage is not below the recorded floor (' + IntToStr(Supported) +
    ' < ' + IntToStr(MinSupported) + ')', Supported >= MinSupported);
end;

initialization
  RegisterTest(TShellTierCorpusTest);
end.
