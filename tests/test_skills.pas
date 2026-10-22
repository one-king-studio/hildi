unit test_skills;
{ fpcunit tests for the skill registry (hildegard.helper.skills): declaration,
  the manifest, load_skill, tool exposure/namespacing, and idle decay. A fake
  ISkillToolSource stands in for a real provider (e.g. MCP). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.skills;

type
  { A fake tool source: records Activate/Deactivate, offers one tool, and can be
    made to fail activation. }
  TFakeSource = class(TInterfacedObject, ISkillToolSource)
  private
    FPrefix: string;
    FActive: Boolean;
    FFailWith: string;
  public
    ActivateCalls: Integer;
    DeactivateCalls: Integer;
    constructor Create(const APrefix: string);
    function Activate(out AError: string): Boolean;
    procedure Deactivate;
    function Specs: TToolSpecArray;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    property FailWith: string read FFailWith write FFailWith;
    property Active: Boolean read FActive;
  end;

  TSkillsTest = class(TTestCase)
  private
    function MakeSkill(const AKey: string): TSkill;
    function LoadArgs(const AKey: string): string;
  published
    { Phase 1: declaration. }
    procedure TestAddDeclaresUnloaded;
    procedure TestAddReplacesSameKey;
    { Phase 2: manifest. }
    procedure TestManifestListsAllUnloaded;
    procedure TestManifestStateChangeIsOneLine;
    { Phase 3: load_skill. }
    procedure TestSpecsIsLoadSkillOnlyWhenEmpty;
    procedure TestEmptyRegistryContributesNothing;
    procedure TestFindResolvesLoadSkill;
    procedure TestLoadActivatesAndReportsTools;
    procedure TestLoadUnknownKeyErrors;
    procedure TestLoadActivateFailureChangesNothing;
    procedure TestLoadTwiceIsIdempotent;
    { Phase 4: tools + namespacing. }
    procedure TestSpecsIncludesLoadedTools;
    procedure TestFindResolvesNamespacedToolAndResetsTimer;
    { Phase 5: decay. }
    procedure TestIdleSkillIsUnloadedAtPrepare;
    procedure TestLoadSkillAlwaysPresent;
    procedure TestLoadThenUnloadReleasesTheSource;
    procedure TestUsedSkillIsKeptAliveAcrossBoundaries;
    procedure TestSkillsAndBaseToolsCoexist;
  end;

implementation

{ TFakeSource }

constructor TFakeSource.Create(const APrefix: string);
begin
  inherited Create;
  FPrefix := APrefix;
  FActive := False;
  FFailWith := '';
end;

function TFakeSource.Activate(out AError: string): Boolean;
begin
  AError := '';
  Inc(ActivateCalls);
  if FFailWith <> '' then
  begin
    AError := FFailWith;
    Exit(False);
  end;
  FActive := True;
  Result := True;
end;

procedure TFakeSource.Deactivate;
begin
  Inc(DeactivateCalls);
  FActive := False;
end;

function TFakeSource.Specs: TToolSpecArray;
begin
  Result := nil;
  if not FActive then
    Exit;
  SetLength(Result, 1);
  Result[0] := MakeToolSpec(FPrefix + '_one', 'the ' + FPrefix + ' tool',
    '{"type":"object","properties":{}}');
end;

function TFakeSource.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  ATool := Default(TRegisteredTool);
  if FActive and (AName = FPrefix + '_one') then
  begin
    ATool.Spec := MakeToolSpec(FPrefix + '_one', 'the ' + FPrefix + ' tool',
      '{"type":"object","properties":{}}');
    Exit(True);
  end;
  Result := False;
end;

{ TSkillsTest }

function TSkillsTest.MakeSkill(const AKey: string): TSkill;
begin
  Result := Default(TSkill);
  Result.Key := AKey;
  Result.Name := AKey;
  Result.Description := 'does ' + AKey + ' things';
  Result.WhenToUse := 'use when ' + AKey;
end;

function TSkillsTest.LoadArgs(const AKey: string): string;
begin
  Result := '{"reason":"test","name":"' + AKey + '"}';
end;

procedure TSkillsTest.TestAddDeclaresUnloaded;
var
  R: TSkillRegistry;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    R.Add(MakeSkill('beta'));
    AssertEquals('alpha unloaded', Ord(ssUnloaded), Ord(R.StateOf('alpha')));
    AssertEquals('beta unloaded', Ord(ssUnloaded), Ord(R.StateOf('beta')));
    AssertEquals('unknown is unloaded', Ord(ssUnloaded), Ord(R.StateOf('nope')));
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestAddReplacesSameKey;
var
  R: TSkillRegistry;
  S: TSkill;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    S := MakeSkill('alpha');
    S.Description := 'replaced';
    R.Add(S);
    { The description is stable text now, not part of the per-request fragment. }
    AssertTrue('one entry', Pos('replaced', R.StableText) > 0);
    AssertTrue('no duplicate', Pos('does alpha things', R.StableText) = 0);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestManifestListsAllUnloaded;
var
  R: TSkillRegistry;
  M, S: string;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    R.Add(MakeSkill('beta'));
    { The per-request fragment carries STATE only: descriptions moved to the
      system prompt so they are not re-sent on every request. }
    M := R.Manifest;
    AssertTrue('alpha listed with state', Pos('- alpha (unloaded)', M) > 0);
    AssertTrue('beta listed with state', Pos('- beta (unloaded)', M) > 0);
    AssertTrue('alpha before beta', Pos('alpha', M) < Pos('beta', M));
    { The stable text carries the descriptions and when-to-use. }
    S := R.StableText;
    AssertTrue('alpha description is stable text',
      Pos('does alpha things', S) > 0);
    AssertTrue('beta description is stable text',
      Pos('does beta things', S) > 0);
    AssertTrue('when-to-use', Pos('use when alpha', S) > 0);
    { And the fragment does NOT repeat them. }
    AssertTrue('the fragment carries no description',
      Pos('does alpha things', M) = 0);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestManifestStateChangeIsOneLine;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Before, After: string;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    R.Add(MakeSkill('beta'));
    Before := R.Manifest;
    R.LoadSkill('alpha', Err);
    After := R.Manifest;
    AssertTrue('before: alpha unloaded', Pos('- alpha (unloaded)', Before) > 0);
    AssertTrue('after: alpha loaded', Pos('- alpha (loaded)', After) > 0);
    AssertTrue('beta unchanged', Pos('- beta (unloaded)', After) > 0);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestSpecsIsLoadSkillOnlyWhenEmpty;
var
  R: TSkillRegistry;
  Specs: TToolSpecArray;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    Specs := R.Specs;
    AssertEquals('only load_skill', 1, Length(Specs));
    AssertEquals('its name', 'load_skill', Specs[0].Name);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestFindResolvesLoadSkill;
var
  R: TSkillRegistry;
  T: TRegisteredTool;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    AssertTrue('load_skill resolves', R.Find('load_skill', T));
    AssertEquals('name', 'load_skill', T.Spec.Name);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestEmptyRegistryContributesNothing;
var
  R: TSkillRegistry;
begin
  R := TSkillRegistry.Create;
  try
    AssertEquals('no tools', 0, Length(R.Specs));
    AssertEquals('no fragment', '', R.PromptFragment);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadActivatesAndReportsTools;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  T: TRegisteredTool;
  Res, Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    AssertTrue('load_skill resolves', R.Find('load_skill', T));
    AssertTrue('handler runs', T.Handler(LoadArgs('alpha'), Res, Err));
    AssertEquals('reports the tool names', 'loaded alpha; tools: alpha_one', Res);
    AssertEquals('activated', 1, Src.ActivateCalls);
    AssertEquals('loaded', Ord(ssLoaded), Ord(R.StateOf('alpha')));
    { An unknown key via the tool is a structured error. }
    AssertFalse('unknown fails', T.Handler(LoadArgs('nope'), Res, Err));
    AssertEquals('structured error', 'unknown skill: nope', Err);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadUnknownKeyErrors;
var
  R: TSkillRegistry;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    AssertFalse('unknown fails', R.LoadSkill('nope', Err));
    AssertEquals('structured error', 'unknown skill: nope', Err);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadActivateFailureChangesNothing;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    Src.FailWith := 'connection refused';
    R.Add(MakeSkill('alpha'), Src);
    AssertFalse('load fails', R.LoadSkill('alpha', Err));
    AssertEquals('error surfaces', 'load failed: connection refused', Err);
    AssertEquals('stays unloaded', Ord(ssUnloaded), Ord(R.StateOf('alpha')));
    AssertEquals('no tools', 1, Length(R.Specs));
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadTwiceIsIdempotent;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    AssertTrue('first', R.LoadSkill('alpha', Err));
    AssertTrue('second', R.LoadSkill('alpha', Err));
    AssertEquals('activated once', 1, Src.ActivateCalls);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestSpecsIncludesLoadedTools;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Specs: TToolSpecArray;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    R.LoadSkill('alpha', Err);
    Specs := R.Specs;
    AssertEquals('load_skill + one tool', 2, Length(Specs));
    AssertEquals('first is load_skill', 'load_skill', Specs[0].Name);
    AssertEquals('then the source tool', 'alpha_one', Specs[1].Name);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestFindResolvesNamespacedToolAndResetsTimer;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  T: TRegisteredTool;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    AssertFalse('not found before load', R.Find('alpha_one', T));
    R.LoadSkill('alpha', Err);
    AssertTrue('found after load', R.Find('alpha_one', T));
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestIdleSkillIsUnloadedAtPrepare;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  S: TSkill;
  Err: string;
  I: Integer;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    S := MakeSkill('alpha');
    S.TTLMs := 1;   { expire almost immediately }
    R.Add(S, Src);
    R.LoadSkill('alpha', Err);
    AssertEquals('loaded', Ord(ssLoaded), Ord(R.StateOf('alpha')));
    { Wait past the TTL, then a turn boundary unloads it. }
    for I := 1 to 5 do
      Sleep(1);
    R.Prepare;
    AssertEquals('decayed to unloaded', Ord(ssUnloaded), Ord(R.StateOf('alpha')));
    AssertEquals('deactivated', 1, Src.DeactivateCalls);
    AssertEquals('tools gone', 1, Length(R.Specs));
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadSkillAlwaysPresent;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    R.LoadSkill('alpha', Err);
    AssertTrue('present when loaded', Pos('load_skill', R.Specs[0].Name) > 0);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestLoadThenUnloadReleasesTheSource;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  S: TSkill;
  Err: string;
begin
  { Load then decay: the source is Deactivated and the registry drops its tools
    (the leak gate enforces the release; here we assert the contract). }
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    S := MakeSkill('alpha');
    S.TTLMs := 1;
    R.Add(S, Src);
    R.LoadSkill('alpha', Err);
    AssertEquals('active', Ord(ssLoaded), Ord(R.StateOf('alpha')));
    Sleep(5);
    R.Prepare;
    AssertEquals('released', 1, Src.DeactivateCalls);
    AssertEquals('tools gone', 1, Length(R.Specs));   { only load_skill remains }
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestUsedSkillIsKeptAliveAcrossBoundaries;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  S: TSkill;
  T: TRegisteredTool;
  Err: string;
  I: Integer;
begin
  { A skill whose TTL is longer than the test: using it each turn (a Find hit)
    resets the timer, so Prepare never unloads it. }
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    S := MakeSkill('alpha');
    S.TTLMs := 1000;
    R.Add(S, Src);
    R.LoadSkill('alpha', Err);
    for I := 1 to 3 do
    begin
      AssertTrue('used each turn', R.Find('alpha_one', T));
      R.Prepare;
    end;
    AssertEquals('still loaded', Ord(ssLoaded), Ord(R.StateOf('alpha')));
    AssertEquals('never deactivated', 0, Src.DeactivateCalls);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestSkillsAndBaseToolsCoexist;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Base: TToolRegistry;
  Err: string;
begin
  { A skill's tools join, they do not replace, the base registry's. }
  R := TSkillRegistry.Create;
  Base := TToolRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    R.LoadSkill('alpha', Err);
    { The registry contributes load_skill + the source's tool; the base registry
      is untouched and still reports its own tools. }
    AssertEquals('registry tools', 2, Length(R.Specs));
    AssertEquals('base registry untouched', 0, Base.Count);
  finally
    Base.Free;
    R.Free;
  end;
end;

initialization
  RegisterTest(TSkillsTest);
end.
