unit hildegard.helper.skills;
{ A capability layer for the agent loop: a *skill* is a named, on-demand
  capability (instructions and/or tools) advertised by a manifest and activated
  by `load_skill`. The default tool surface stays O(base); a skill costs nothing
  until it is loaded, and it is released when idle.

  The registry IS an IToolProvider (the Turn_Injection seam) - it adds no second
  seam. Its PromptFragment is the manifest (a request-only system fragment, never
  persisted); its Specs are the active skills' tools plus the always-on
  `load_skill`; its Find resolves a called name (sources in order, then
  `load_skill`); its Prepare runs decay at the turn boundary.

  MCP is the first source (see Lazy_MCP); a source supplies its own tools and
  namespaces them (e.g. mcp_<server>_<tool>). See
  docs/features/Skills/Skills_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils,
  hildegard.helper.llm, hildegard.helper.agent;

type
  TSkillState = (ssUnloaded, ssLoaded);

  { What a skill needs to connect and offer tools. Nil for an instruction-only
    skill (which activates with instructions alone). The registry calls
    Deactivate only on a source it Activated. }
  ISkillToolSource = interface
    { Connect + discover. False + AError on failure, leaving nothing half-open.
      Idempotent: activating an active source is a no-op that succeeds. }
    function Activate(out AError: string): Boolean;
    { Release the connection and any provider-owned resources. Idempotent. }
    procedure Deactivate;
    { The tools while active (already reason-augmented; namespaced by the
      source). Empty when inactive. }
    function Specs: TToolSpecArray;
    { Resolve a called name to a handler. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

  { A declared skill. Key is the stable, snake_case identity (part of the
    approval ref via the tool namespace); Name/Description/WhenToUse are CURATED
    (operator or a template) - never a provider's server-authored text. }
  TSkill = record
    Key: string;
    Name: string;
    Description: string;
    WhenToUse: string;
    Instructions: string;   // injected while loaded; '' for a tool-only skill
    TTLMs: Int64;           // idle TTL; 0 => DefaultSkillTtlMs
  end;

  TSkillEntry = class
  public
    Skill: TSkill;
    Source: ISkillToolSource;
    State: TSkillState;
    LastUsedMs: Int64;
    Tools: TToolSpecArray;   // captured on load, for reporting
  end;

  { The manifest/activation engine. One registry per session, registered with
    the loop as an IToolProvider. Loop-thread only (like every provider). }
  TSkillRegistry = class(TInterfacedObject, IToolProvider)
  private
    FEntries: TObjectList;
    function IndexOfKey(const AKey: string): Integer;
    function TtlOf(const AEntry: TSkillEntry): Int64;
    function ActiveInstructions: string;
    function LoadSpec: TToolSpec;
    function HandleLoad(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { The monotonic clock for the idle TTL. Called directly (SysUtils
      GetTickCount64), not via the TUI clock - the registry must not link a TUI
      unit (the Process Split). }
    function NowMs: Int64;
  public
    constructor Create;
    destructor Destroy; override;

    { Declare a skill. ASource is nil for an instruction-only skill. The same
      key twice replaces the declaration. }
    procedure Add(const ASkill: TSkill; const ASource: ISkillToolSource = nil);
    { Remove a skill by key (deactivates it first). True when it was present. }
    function Remove(const AKey: string): Boolean;
    { The declared keys, in declaration order. }
    function Keys: TStringArray;

    { Activate by key. False + AError (structured) on unknown key or a source
      failure; nothing changes on failure. Resets the idle timer. }
    function LoadSkill(const AKey: string; out AError: string): Boolean;
    { The current state of a declared key. }
    function StateOf(const AKey: string): TSkillState;
    { The rendered manifest (stable per state change). }
    function Manifest: string;

    { IToolProvider }
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

const
  { The default idle TTL for a skill that does not set one. }
  DefaultSkillTtlMs = 600000;   // 10 minutes
  { The always-present activation tool's name. }
  LoadSkillToolName = 'load_skill';
  { The manifest header: explains the model's contract (load on demand, decay by
    idle time, and that the state shown is honest). }
  SkillManifestHeader =
    'Skills you can load on demand with load_skill. A skill is unloaded when it ' +
    'has been idle, so check the state here before relying on its tools:';

implementation

uses
  fpjson, jsonparser;

const
  LoadSkillParametersJson =
    '{"type":"object","properties":{"name":{"type":"string",' +
    '"description":"the skill key to load"}},"required":["name"]}';

{ --- TSkillRegistry ----------------------------------------------------- }

constructor TSkillRegistry.Create;
begin
  inherited Create;
  FEntries := TObjectList.Create(True);
end;

destructor TSkillRegistry.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

function TSkillRegistry.IndexOfKey(const AKey: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    if TSkillEntry(FEntries[I]).Skill.Key = AKey then
      Exit(I);
  Result := -1;
end;

function TSkillRegistry.TtlOf(const AEntry: TSkillEntry): Int64;
begin
  if AEntry.Skill.TTLMs > 0 then
    Result := AEntry.Skill.TTLMs
  else
    Result := DefaultSkillTtlMs;
end;

procedure TSkillRegistry.Add(const ASkill: TSkill;
  const ASource: ISkillToolSource);
var
  Entry: TSkillEntry;
  I: Integer;
begin
  I := IndexOfKey(ASkill.Key);
  if I >= 0 then
    Entry := TSkillEntry(FEntries[I])
  else
  begin
    Entry := TSkillEntry.Create;
    Entry.State := ssUnloaded;
    Entry.LastUsedMs := 0;
    FEntries.Add(Entry);
  end;
  Entry.Skill := ASkill;
  Entry.Source := ASource;
end;

function TSkillRegistry.StateOf(const AKey: string): TSkillState;
var
  I: Integer;
begin
  I := IndexOfKey(AKey);
  if I < 0 then
    Result := ssUnloaded
  else
    Result := TSkillEntry(FEntries[I]).State;
end;

function TSkillRegistry.Remove(const AKey: string): Boolean;
var
  I: Integer;
  E: TSkillEntry;
begin
  I := IndexOfKey(AKey);
  if I < 0 then
    Exit(False);
  E := TSkillEntry(FEntries[I]);
  if (E.State = ssLoaded) and (E.Source <> nil) then
    E.Source.Deactivate;
  FEntries.Delete(I);
  Result := True;
end;

function TSkillRegistry.Keys: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FEntries.Count);
  for I := 0 to FEntries.Count - 1 do
    Result[I] := TSkillEntry(FEntries[I]).Skill.Key;
end;

function TSkillRegistry.Manifest: string;
var
  I: Integer;
  E: TSkillEntry;
  State: string;
begin
  Result := SkillManifestHeader + LineEnding;
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if E.State = ssLoaded then
      State := 'loaded'
    else
      State := 'unloaded';
    Result := Result + '- ' + E.Skill.Key + ' (' + State + '): ' +
      E.Skill.Description;
    if E.Skill.WhenToUse <> '' then
      Result := Result + ' ' + E.Skill.WhenToUse;
    Result := Result + LineEnding;
  end;
end;

function TSkillRegistry.ActiveInstructions: string;
var
  I: Integer;
  E: TSkillEntry;
begin
  Result := '';
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if (E.State = ssLoaded) and (E.Skill.Instructions <> '') then
    begin
      if Result <> '' then
        Result := Result + LineEnding;
      Result := Result + E.Skill.Instructions;
    end;
  end;
end;

function TSkillRegistry.NowMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

function TSkillRegistry.LoadSpec: TToolSpec;
begin
  Result := MakeToolSpec(LoadSkillToolName,
    'Load a skill by key. Skills load on demand; the manifest shows each ' +
    'skill''s current state. Loading a skill registers its tools.',
    LoadSkillParametersJson);
end;

function TSkillRegistry.HandleLoad(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Key: string;
  I, K: Integer;
  Names: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Data := nil;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'invalid arguments';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if (Root.Find('name') = nil) or (Root.Find('name').JSONType <> jtString) then
    begin
      AError := 'name is required';
      Exit(False);
    end;
    Key := Root.Find('name').AsString;
    if not LoadSkill(Key, AError) then
      Exit(False);
    I := IndexOfKey(Key);
    Names := '';
    if I >= 0 then
      for K := 0 to High(TSkillEntry(FEntries[I]).Tools) do
      begin
        if Names <> '' then
          Names := Names + ', ';
        Names := Names + TSkillEntry(FEntries[I]).Tools[K].Name;
      end;
    if Names <> '' then
      AResult := 'loaded ' + Key + '; tools: ' + Names
    else
      AResult := 'loaded ' + Key;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TSkillRegistry.LoadSkill(const AKey: string; out AError: string): Boolean;
var
  I: Integer;
  E: TSkillEntry;
begin
  AError := '';
  I := IndexOfKey(AKey);
  if I < 0 then
  begin
    AError := 'unknown skill: ' + AKey;
    Exit(False);
  end;
  E := TSkillEntry(FEntries[I]);
  if E.State = ssLoaded then
  begin
    { Idempotent: a reload just resets the idle timer. }
    E.LastUsedMs := NowMs;
    Exit(True);
  end;
  if E.Source <> nil then
  begin
    if not E.Source.Activate(AError) then
    begin
      AError := 'load failed: ' + AError;
      Exit(False);
    end;
    E.Tools := E.Source.Specs;
  end
  else
    E.Tools := nil;
  E.State := ssLoaded;
  E.LastUsedMs := NowMs;
  Result := True;
end;

procedure TSkillRegistry.Prepare;
var
  I: Integer;
  E: TSkillEntry;
  Now: Int64;
begin
  { Decay at the turn boundary only: unload an idle skill. }
  Now := NowMs;
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if (E.State = ssLoaded) and (Now - E.LastUsedMs > TtlOf(E)) then
    begin
      if E.Source <> nil then
        E.Source.Deactivate;
      E.Tools := nil;
      E.State := ssUnloaded;
    end;
  end;
end;

function TSkillRegistry.Specs: TToolSpecArray;
var
  I, K: Integer;
  E: TSkillEntry;
begin
  Result := nil;
  { With no skills declared the registry contributes nothing, so a session with
    no capabilities is byte-identical to one without the registry. }
  if FEntries.Count = 0 then
    Exit;
  { load_skill is present once there is something to load. }
  SetLength(Result, 1);
  Result[0] := LoadSpec;
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if E.State <> ssLoaded then
      Continue;
    for K := 0 to High(E.Tools) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := E.Tools[K];
    end;
  end;
end;

function TSkillRegistry.PromptFragment: string;
var
  Instr: string;
begin
  { No skills declared: contribute no fragment (keep the prompt unchanged). }
  if FEntries.Count = 0 then
    Exit('');
  Result := Manifest;
  Instr := ActiveInstructions;
  if Instr <> '' then
    Result := Result + LineEnding + Instr;
end;

function TSkillRegistry.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I: Integer;
  E: TSkillEntry;
begin
  ATool := Default(TRegisteredTool);
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if E.State <> ssLoaded then
      Continue;
    if (E.Source <> nil) and E.Source.Find(AName, ATool) then
    begin
      { A use resets the idle timer. }
      E.LastUsedMs := NowMs;
      Exit(True);
    end;
  end;
  if AName = LoadSkillToolName then
  begin
    ATool.Spec := LoadSpec;
    ATool.Handler := HandleLoad;
    Exit(True);
  end;
  Result := False;
end;

end.
