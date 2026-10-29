unit TestShellCorpus;
{ Parse every recorded run_command argument and check the outcome.

  The corpus is a fixture (tests/data/shell_corpus.txt), so the test is hermetic:
  it needs no store and no bash. A parse failure inside the v1 subset is a bug;
  a failure outside it must be a named subset-gate message, never an internal
  error. The counts are pinned to a recorded baseline so a regression that
  rejects (or silently accepts) more is visible. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  ShellTypes, ShellAST, ShellParser;

type
  TShellCorpusTest = class(TTestCase)
  private
    function Decode(const ALine: string): string;
  published
    procedure TestEveryCommandHasAnExpectedOutcome;
  end;

implementation

const
  CorpusPath = 'tests/data/shell_corpus.txt';
  { Pinned when the fixture was recorded. }
  ExpectedTotal = 3255;
  ExpectedOk = 3182;
  ExpectedCommandSubstitution = 70;
  ExpectedProcessSubstitution = 1;
  ExpectedParameterExpansion = 1;
  ExpectedUnterminatedSingleQuote = 1;

function TShellCorpusTest.Decode(const ALine: string): string;
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
        else if ALine[I] = '\' then
          Result := Result + '\'
        else
          Result := Result + ALine[I];
      end;
    end
    else
      Result := Result + C;
    Inc(I);
  end;
end;

function IsNamedSubsetGate(const AMsg: string): Boolean;
begin
  Result := (AMsg = 'command substitution is not supported') or
    (AMsg = 'parameter-expansion operators are not supported') or
    (AMsg = 'backquote command substitution is not supported') or
    (AMsg = 'brace expansion is not supported') or
    (AMsg = 'ANSI-C quoting is not supported') or
    (AMsg = 'process substitution is not supported') or
    (AMsg = 'unterminated single quote') or
    (AMsg = 'unterminated double quote') or
    (AMsg = 'unterminated backquote') or
    (AMsg = 'unterminated here-document');
end;

function CountOf(AReasons: TStringList; const AMsg: string): Integer;
var
  I: Integer;
begin
  I := AReasons.IndexOfName(AMsg);
  if I < 0 then
    Result := 0
  else
    Result := StrToIntDef(AReasons.ValueFromIndex[I], 0);
end;

procedure TShellCorpusTest.TestEveryCommandHasAnExpectedOutcome;
var
  Lines: TStringList;
  I, Total, Ok, Bad: Integer;
  Src: string;
  S: TScript;
  E: TShellParseError;
  Msg: string;
  Reasons: TStringList;
  InSubset: Integer;
begin
  AssertTrue('corpus fixture exists', FileExists(CorpusPath));
  Lines := TStringList.Create;
  Reasons := TStringList.Create;
  try
    Lines.LoadFromFile(CorpusPath);
    Total := 0;
    Ok := 0;
    Bad := 0;
    InSubset := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if (Lines[I] = '') or (Lines[I][1] = '#') then
        Continue;
      Inc(Total);
      Src := Decode(Lines[I]);
      if ParseShellScript(Src, S, E) then
      begin
        Inc(Ok);
        S.Free;
      end
      else
      begin
        Inc(Bad);
        Msg := E.Message;
        { A syntax error (for example a truncated command) is not a subset-gate
          rejection; it is recorded separately. }
        if not IsNamedSubsetGate(Msg) then
          if (Pos('expected', Msg) = 0) and (Pos('unexpected', Msg) = 0) and
            (Pos('unsupported', Msg) = 0) then
            Inc(InSubset);
        if Reasons.IndexOfName(Msg) < 0 then
          Reasons.Add(Msg + '=1')
        else
          Reasons.Values[Msg] := IntToStr(StrToIntDef(Reasons.Values[Msg], 0) + 1);
      end;
    end;

    WriteLn('corpus: total=', Total, ' ok=', Ok, ' errors=', Bad);
    for I := 0 to Reasons.Count - 1 do
      WriteLn('  ', Reasons.Names[I], ' x', Reasons.ValueFromIndex[I]);

    AssertEquals('corpus size matches the recorded baseline', ExpectedTotal, Total);
    AssertEquals('every parse failure is a named gate or a syntax error', 0, InSubset);
    AssertEquals('parsed commands match the baseline', ExpectedOk, Ok);
    AssertEquals('command substitution rejections',
      ExpectedCommandSubstitution, CountOf(Reasons,
      'command substitution is not supported'));
    AssertEquals('process substitution rejections',
      ExpectedProcessSubstitution, CountOf(Reasons,
      'process substitution is not supported'));
    AssertEquals('parameter-expansion rejections',
      ExpectedParameterExpansion, CountOf(Reasons,
      'parameter-expansion operators are not supported'));
    AssertEquals('unterminated single quote rejections',
      ExpectedUnterminatedSingleQuote, CountOf(Reasons,
      'unterminated single quote'));
    { The corpus is mostly simple/linear; a large drop means the parser regressed. }
    AssertTrue('most of the corpus parses (' + IntToStr(Ok) + '/' +
      IntToStr(Total) + ')', Ok > Total * 6 div 10);
  finally
    Reasons.Free;
    Lines.Free;
  end;
end;

initialization
  RegisterTest(TShellCorpusTest);
end.
