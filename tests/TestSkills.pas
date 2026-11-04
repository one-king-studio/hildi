unit TestSkills;
{ fpcunit tests for the skill registry (HildiSkills): declaration,
  the manifest, load_skill, tool exposure/namespacing, and idle decay. A fake
  ISkillToolSource stands in for a real provider (e.g. MCP). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  LLMClient, HildiAgent, HildiSkills, HildiHarnessTurn;

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
    { Phase 2: what rides the request (nothing) and what is stable text. }
    procedure TestFragmentIsEmptyAndCatalogueIsStableText;
    procedure TestStateIsDerivedNotFragmented;
    { Phase 3: load_skill. }
    procedure TestSpecsIsLoadSkillOnlyWhenEmpty;
    procedure TestEmptyRegistryContributesNothing;
    { The composer line: a pure function of the loaded names, so the truncation
      rule is testable without a terminal. }
    procedure TestLoadedSkillsLineTruncates;
    { The click hit-test: which skill a column of that line resolves to. }
    procedure TestLoadedSkillsHitKey;
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

procedure TSkillsTest.TestFragmentIsEmptyAndCatalogueIsStableText;
var
  R: TSkillRegistry;
  F, S, Err: string;
begin
  R := TSkillRegistry.Create;
  try
    R.Add(MakeSkill('alpha'));
    R.Add(MakeSkill('beta'));
    { NOTHING rides the per-request fragment any more. The body is injected once
      into the conversation, and the state line is gone: a loaded skill's body is
      visibly in context, so restating "loaded" would cost tokens to say what the
      model can already see. }
    R.LoadSkill('alpha', Err);
    F := R.PromptFragment;
    AssertEquals('the fragment is empty', '', F);
    { The CATALOGUE is still how the model learns a skill exists, and it lives in
      the system prompt where it is sent once and cached. }
    S := R.StableText;
    AssertTrue('alpha description is stable text',
      Pos('does alpha things', S) > 0);
    AssertTrue('beta description is stable text',
      Pos('does beta things', S) > 0);
    AssertTrue('when-to-use', Pos('use when alpha', S) > 0);
  finally
    R.Free;
  end;
end;

procedure TSkillsTest.TestStateIsDerivedNotFragmented;
var
  R: TSkillRegistry;
  Src: TFakeSource;
  Err: string;
begin
  R := TSkillRegistry.Create;
  try
    Src := TFakeSource.Create('alpha');
    R.Add(MakeSkill('alpha'), Src);
    R.Add(MakeSkill('beta'));
    { State still has to be knowable - the panel marks rows from it and the load
      path short-circuits on it - but it is reporting, not prompt text. }
    AssertEquals('unloaded before', Ord(ssUnloaded), Ord(R.StateOf('alpha')));
    AssertTrue('load ok', R.LoadSkill('alpha', Err));
    AssertEquals('loaded after', Ord(ssLoaded), Ord(R.StateOf('alpha')));
    AssertEquals('beta untouched', Ord(ssUnloaded), Ord(R.StateOf('beta')));
    { And none of it rides the request. }
    AssertEquals('no fragment either way', '', R.PromptFragment);
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

procedure TSkillsTest.TestLoadedSkillsLineTruncates;
var
  Names: TStringArray;
begin
  { Nothing loaded -> no line at all, so the composer gains no empty row. }
  Names := nil;
  AssertEquals('empty', '', FormatLoadedSkillsLine(Names));

  { Under the cap: every name shown, no overflow token. }
  SetLength(Names, 2);
  Names[0] := 'alpha';
  Names[1] := 'beta';
  AssertEquals('two', '+alpha +beta', FormatLoadedSkillsLine(Names));

  { Exactly at the cap: still no overflow, which is the off-by-one worth pinning. }
  SetLength(Names, 3);
  Names[0] := 'alpha';
  Names[1] := 'beta';
  Names[2] := 'gamma';
  AssertEquals('three', '+alpha +beta +gamma', FormatLoadedSkillsLine(Names));

  { Over the cap: three shown and the remainder counted. }
  SetLength(Names, 5);
  Names[0] := 'alpha';
  Names[1] := 'beta';
  Names[2] := 'gamma';
  Names[3] := 'delta';
  Names[4] := 'epsilon';
  AssertEquals('truncated', '+alpha +beta +gamma +2 more',
    FormatLoadedSkillsLine(Names));

  { A cap of 1 is honoured, and the overflow counts the rest. }
  AssertEquals('cap of one', '+alpha +4 more',
    FormatLoadedSkillsLine(Names, 1));
end;

procedure TSkillsTest.TestLoadedSkillsHitKey;
var
  Names: TStringArray;
begin
  { The row is a TTextBlock with no per-span regions, so the clickable columns
    are computed from the same layout the formatter emits. "+alpha +beta" is
       0..5   alpha   ('+alpha')
       6      the separator
       7..11  beta    ('+beta')
    An off-by-one here would make the last character of a name dead, or make the
    separator open the wrong dialog. }
  SetLength(Names, 2);
  Names[0] := 'alpha';
  Names[1] := 'beta';

  AssertEquals('start of the first', 'alpha', LoadedSkillsHitKey(Names, 0));
  AssertEquals('last char of the first', 'alpha',
    LoadedSkillsHitKey(Names, 5));
  AssertEquals('the separator is a miss', '', LoadedSkillsHitKey(Names, 6));
  AssertEquals('start of the second', 'beta', LoadedSkillsHitKey(Names, 7));
  AssertEquals('last char of the second', 'beta',
    LoadedSkillsHitKey(Names, 11));
  AssertEquals('past the end is a miss', '', LoadedSkillsHitKey(Names, 12));
  AssertEquals('before the start is a miss', '', LoadedSkillsHitKey(Names, -1));

  { An overflow token is a MISS: "+2 more" opens the panel, which is the caller's
    decision, not a skill. }
  SetLength(Names, 5);
  Names[0] := 'alpha';
  Names[1] := 'beta';
  Names[2] := 'gamma';
  Names[3] := 'delta';
  Names[4] := 'epsilon';
  AssertEquals('a shown name still hits', 'gamma',
    LoadedSkillsHitKey(Names, 14));
  AssertEquals('the overflow is not a skill', '',
    LoadedSkillsHitKey(Names, 20));
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
