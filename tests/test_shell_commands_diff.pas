unit test_shell_commands_diff;
{ Differential fixtures for the builtin command set: each script runs in the
  builtin tier over a prepared workspace, and its stdout/status must match the
  recorded /bin/bash result. A decline is a failure here: these scripts must
  stay in the tier. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.approval, hildegard.helper.shell.fs,
  hildegard.helper.shell.tier;

type
  TAllowAll = class(TInterfacedObject, IApprovalService)
  public
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TShellCommandsDiffTest = class(TTestCase)
  private
    FRoot: string;
    FTier: TBuiltinShell;
    function Decode(const AText: string): string;
    procedure Populate;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFixturesMatchBash;
  end;

implementation

const
  FixturePath = 'tests/data/shell_commands_differential.txt';

function TAllowAll.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  AResult := Default(TApprovalBatchResult);
  AResult.Allowed := True;
  Result := True;
end;

function TShellCommandsDiffTest.Decode(const AText: string): string;
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

procedure TShellCommandsDiffTest.Populate;
var
  E: string;
  FFs: TWorkspaceShellFs;
begin
  FFs := TWorkspaceShellFs.Create(FRoot);
  try
    FFs.WriteFile(FRoot + '/a.txt', 'alpha' + #10 + 'beta' + #10 + 'gamma' + #10,
      False, E);
    FFs.WriteFile(FRoot + '/b.txt', 'a' + #10 + 'a' + #10 + 'b' + #10, False, E);
    FFs.WriteFile(FRoot + '/c.log', 'note' + #10, False, E);
    FFs.MakeDir(FRoot + '/sub', False, E);
  finally
    FFs.Free;
  end;
end;

procedure TShellCommandsDiffTest.SetUp;
var
  Cfg: TBuiltinShellConfig;
begin
  inherited SetUp;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'shellcmddiff-' +
    IntToStr(Random(100000000));
  ForceDirectories(FRoot);
  Populate;
  Cfg := Default(TBuiltinShellConfig);
  Cfg.Root := FRoot;
  Cfg.MaxOutputBytes := 32768;
  FTier := TBuiltinShell.Create(Cfg, TAllowAll.Create, nil);
end;

procedure TShellCommandsDiffTest.TearDown;
var
  Tmp: TWorkspaceShellFs;
  E: string;
begin
  FTier.Free;
  if DirectoryExists(FRoot) then
  begin
    Tmp := TWorkspaceShellFs.Create(FRoot);
    try
      Tmp.Delete(FRoot, True, E);
    finally
      Tmp.Free;
    end;
  end;
  inherited TearDown;
end;

procedure TShellCommandsDiffTest.TestFixturesMatchBash;
var
  Lines: TStringList;
  I, P1, P2, P3, ExpectedStatus, ActualStatus, Checked: Integer;
  Line, Script, ExpectedOut, ExpectedErr, ActualOut: string;
  Failures: TStringList;
  Cfg: TBuiltinShellConfig;
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
      P3 := Pos(#9, Copy(Line, P1 + P2 + 1, MaxInt));
      AssertTrue('fixture line is four fields: ' + Line,
        (P1 > 0) and (P2 > 0) and (P3 > 0));
      Script := Decode(Copy(Line, 1, P1 - 1));
      ExpectedOut := Decode(Copy(Line, P1 + 1, P2 - 1));
      ExpectedErr := Decode(Copy(Line, P1 + P2 + 1, P3 - 1));
      ExpectedStatus := StrToIntDef(Copy(Line, P1 + P2 + P3 + 1, MaxInt), 0);
      { A fresh shell per fixture, like bash's separate invocations. }
      FTier.Free;
      Populate;
      Cfg := Default(TBuiltinShellConfig);
      Cfg.Root := FRoot;
      Cfg.MaxOutputBytes := 32768;
      FTier := TBuiltinShell.Create(Cfg, TAllowAll.Create, nil);
      if not FTier.TryRun(Script, FRoot, 'test reason', 0, ActualOut,
        ActualStatus) then
      begin
        Failures.Add('declined: ' + Script + ' :: ' + FTier.LastError);
        Continue;
      end;
      Inc(Checked);
      if (ActualOut <> ExpectedOut) or (ActualStatus <> ExpectedStatus) then
        Failures.Add('script: ' + Script + #10 +
          '  bash: status ' + IntToStr(ExpectedStatus) + ' out ' +
          QuotedStr(ExpectedOut) + ' err ' + QuotedStr(ExpectedErr) + #10 +
          '  ours: status ' + IntToStr(ActualStatus) + ' out ' +
          QuotedStr(ActualOut));
    end;
    AssertTrue('fixtures present', Checked >= 20);
    AssertEquals('every command fixture matches bash' + #10 + Failures.Text,
      0, Failures.Count);
  finally
    Failures.Free;
    Lines.Free;
  end;
end;

initialization
  RegisterTest(TShellCommandsDiffTest);
end.
