unit test_shell_differential;
{ Replays recorded /bin/bash results against the interpreter.

  The fixtures were recorded once from /bin/bash (tests/data/shell_differential.txt),
  so the test is hermetic: no bash is needed at run time. A mismatch is either an
  interpreter bug or a deliberate, documented difference - there should be no
  silent ones. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  shell.types, shell.ast, shell.fs, shell.registry, shell.interpreter,
  test_shell_memfs;

type
  TShellDifferentialTest = class(TTestCase)
  private
    FMem: TMemoryFs;
    FReg: TShellRegistry;
    FShell: TShell;
    FEnv: TShellEnv;
    function Echo(const ACall: TShellCall): TShellResult;
    function Cat(const ACall: TShellCall): TShellResult;
    function TrueCmd(const ACall: TShellCall): TShellResult;
    function FalseCmd(const ACall: TShellCall): TShellResult;
    function Decode(const AText: string): string;
    procedure ResetShell;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFixturesMatchBash;
  end;

implementation

const
  FixturePath = 'tests/data/shell_differential.txt';

function TShellDifferentialTest.Decode(const AText: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(AText) do
  begin
    C := AText[I];
    if C = '\' then
    begin
      Inc(I);
      if I <= Length(AText) then
      begin
        if AText[I] = 'n' then
          Result := Result + #10
        else if AText[I] = 't' then
          Result := Result + #9
        else
          Result := Result + AText[I];
      end;
    end
    else
      Result := Result + C;
    Inc(I);
  end;
end;

procedure TShellDifferentialTest.SetUp;
begin
  inherited SetUp;
  ResetShell;
end;

procedure TShellDifferentialTest.ResetShell;
begin
  FShell.Free;
  FReg.Free;
  FEnv.Free;
  FMem := TMemoryFs.Create;
  FMem.AddDir('/work');
  FReg := TShellRegistry.Create;
  FReg.Register('echo', Echo);
  FReg.Register('cat', Cat);
  FReg.Register('true', TrueCmd);
  FReg.Register('false', FalseCmd);
  FEnv := TShellEnv.Create;
  FEnv.SetValue('HOME', '/work');
  FShell := TShell.Create(FReg, FMem, '/work', nil, DefaultShellLimits, FEnv);
end;

procedure TShellDifferentialTest.TearDown;
begin
  FShell.Free;
  FReg.Free;
  FEnv.Free;
  FMem := nil;
  inherited TearDown;
end;

function TShellDifferentialTest.Echo(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(ACall.Args) do
  begin
    if I > 0 then
      S := S + ' ';
    S := S + ACall.Args[I];
  end;
  Result := ShellResultOk(S + #10);
end;

function TShellDifferentialTest.Cat(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Data, E: string;
begin
  if Length(ACall.Args) = 0 then
    Exit(ShellResultOk(ACall.Stdin));
  Result := ShellResultOk('');
  for I := 0 to High(ACall.Args) do
  begin
    if not FMem.ReadFile(FMem.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
      Exit(ShellResultErr('cat: ' + ACall.Args[I] + ': ' + E + #10, 1));
    Result.Stdout := Result.Stdout + Data;
  end;
end;

function TShellDifferentialTest.TrueCmd(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultOk('');
end;

function TShellDifferentialTest.FalseCmd(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultErr('', 1);
end;

procedure TShellDifferentialTest.TestFixturesMatchBash;
var
  Lines: TStringList;
  I, P1, P2, ExpectedStatus, ActualStatus, Checked: Integer;
  Line, Script, ExpectedOut, ActualOut, ActualErr: string;
  Failures: TStringList;
begin
  AssertTrue('fixture exists', FileExists(FixturePath));
  Lines := TStringList.Create;
  Failures := TStringList.Create;
  try
    Lines.LoadFromFile(FixturePath);
    Checked := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Line = '') or (Line[1] = '#') then
        Continue;
      P1 := Pos(#9, Line);
      P2 := Pos(#9, Copy(Line, P1 + 1, MaxInt));
      AssertTrue('fixture line is script<TAB>stdout<TAB>status: ' + Line,
        (P1 > 0) and (P2 > 0));
      ResetShell;
      Script := Decode(Copy(Line, 1, P1 - 1));
      ExpectedOut := Decode(Copy(Line, P1 + 1, P2 - 1));
      ExpectedStatus := StrToIntDef(Copy(Line, P1 + P2 + 1, MaxInt), 0);
      ActualStatus := FShell.RunSource(Script, ActualOut, ActualErr);
      Inc(Checked);
      if (ActualOut <> ExpectedOut) or (ActualStatus <> ExpectedStatus) then
        Failures.Add('script: ' + Script + #10 +
          '  bash: status ' + IntToStr(ExpectedStatus) + ' out ' +
          QuotedStr(ExpectedOut) + #10 +
          '  ours: status ' + IntToStr(ActualStatus) + ' out ' +
          QuotedStr(ActualOut) + ' err ' + QuotedStr(ActualErr));
    end;
    AssertTrue('fixtures present', Checked >= 20);
    AssertEquals('every differential fixture matches bash' + #10 +
      Failures.Text, 0, Failures.Count);
  finally
    Failures.Free;
    Lines.Free;
  end;
end;

initialization
  RegisterTest(TShellDifferentialTest);
end.
