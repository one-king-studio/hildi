unit HildiSkills;
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
  HildiLLM, HildiAgent, HildiApproval;

type
  TSkillState = (ssUnloaded, ssLoaded);

  { Returns the keys whose bodies are IN THE CURRENT CONTEXT. Supplied by the
    owner (the session), because only it knows the store - and the store, not the
    registry, is the source of truth: a /checkpoint rebuild resumes from a
    snapshot, so a body written before the boundary is no longer in context even
    though it was loaded earlier.

    ONE call for all keys, not one per key: this is refreshed once per turn in
    Prepare and the result is cached, because Specs/Find/Manifest are consulted
    on every tool resolution and a query there would be a round trip per call.

    Unset means the registry falls back to its own activation state, which keeps
    it standalone-usable for tests and headless callers. }
  TSkillKeysQuery = function: TStringArray of object;

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
    { A FILE-BACKED skill (a SKILL.md directory) carries its home, so relative
      references in its body resolve and its bundled files can be listed.
      Empty for a hand-registered or provider-backed skill. }
    Location: string;
    Resources: TStringArray;      // paths relative to Location, sorted
    ResourcesTruncated: Boolean;
    { Carried from the frontmatter for DISPLAY. AllowedTools in particular is
      never consulted when deciding what to approve: the spec marks it
      experimental, and honouring it would let a downloaded skill widen its own
      permissions. }
    AllowedTools: string;
    License: string;
    Compatibility: string;
  end;

  { A skill finished ACTIVATING. Declared after TSkill (declaration order
    matters here: the record must exist before an event can carry it).

    The handler only ANNOUNCES. The body is delivered to the model by the owner
    writing it into the conversation, and the owner must not do that from inside
    the load_skill handler: the loop appends the tool result AFTER the handler
    returns, so an append here would put a user message between the assistant's
    tool_calls message and its result, which providers reject. The owner
    therefore enqueues, and the loop drains at the next request boundary. }
  TSkillLoadedEvent = procedure(const ASkill: TSkill) of object;

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
    { nil => no gate. Tests and headless callers legitimately have no approval
      service; the gate is the caller's to supply rather than something to fake. }
    FApproval: IApprovalService;
    FWorkspaceId: Integer;
    FSessionId: string;
    FOnLoaded: TSkillLoadedEvent;
    FKeysQuery: TSkillKeysQuery;
    { The keys in context, refreshed once per turn in Prepare. Cached because
      Specs/Find/Manifest are consulted on every tool resolution; a live query
      there would be a store round trip per call. }
    FLoadedKeys: TStringArray;
    { Is this skill's body IN CONTEXT right now? The single answer every other
      method uses, so the registry cannot disagree with itself about it. }
    function IsLoaded(const AEntry: TSkillEntry): Boolean;
    function IndexOfKey(const AKey: string): Integer;
    function TtlOf(const AEntry: TSkillEntry): Int64;
    function LoadSpec: TToolSpec;
    function HandleLoad(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { The monotonic clock for the idle TTL. Called directly (SysUtils
      GetTickCount64), not via the TUI clock - the registry must not link a TUI
      unit (the Process Split). }
    function NowMs: Int64;
    { IS THIS LOAD ALLOWED? Activating a skill puts instructions into the context
      that the operator did not write, so a FILE-BACKED skill is gated. The ask
      offers the standard scopes; the approval service fast-paths an existing
      rule, which is what makes a workspace-scope grant work for every session in
      the workspace without any bookkeeping here.

      A registry with no approval service (tests, headless callers) loads
      directly - the gate is the caller's to supply, not something to fake. }
    function ApproveLoad(const ASkill: TSkill; out AError: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Declare a skill. ASource is nil for an instruction-only skill. The same
      key twice replaces the declaration. }
    procedure Add(const ASkill: TSkill; const ASource: ISkillToolSource = nil);
    { Supply the approval gate. Without one, a file-backed skill loads without
      asking; with one, activation is an ask. AWorkspaceId/ASessionId identify
      the scopes an approval can be granted at, so a workspace-scope grant is
      honoured by every session in that workspace. }
    procedure SetApproval(const AApproval: IApprovalService;
      AWorkspaceId: Integer; const ASessionId: string);
    { Remove a skill by key (deactivates it first). True when it was present. }
    function Remove(const AKey: string): Boolean;
    { The declared keys, in declaration order. }
    function Keys: TStringArray;
    { The keys whose bodies are IN THE CURRENT CONTEXT. A subset of Keys, so the
      UI can mark each row without a parallel flags array that could drift out of
      order. }
    function LoadedKeys: TStringArray;

    { Activate by key. False + AError (structured) on unknown key or a source
      failure; nothing changes on failure. Resets the idle timer. }
    function LoadSkill(const AKey: string; out AError: string): Boolean;
    { The current state of a declared key. }
    function StateOf(const AKey: string): TSkillState;
    { Read back a declared skill. SkillOf returns a zeroed record for an unknown
      key, so a caller can test Key <> '' rather than catching an exception. }
    function SkillOf(const AKey: string): TSkill;
    { The spec-level name (may contain hyphens) for a key. }
    function NameOf(const AKey: string): string;
    { The body/instructions for a key. }
    function InstructionsOf(const AKey: string): string;

    { IToolProvider }
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    { The STABLE half of the manifest: each skill's description and when-to-use,
      with no activation state. It goes in the system prompt, where stable text
      belongs, rather than riding every request in the prompt fragment. }

    function StableText: string;

    { Announce activation. The owner turns this into a conversation append; the
      registry itself never touches the store. }
    property OnLoaded: TSkillLoadedEvent read FOnLoaded write FOnLoaded;

    { Where "in context" comes from. Unset => the registry's own activation
      state (standalone use). Set => the store decides, refreshed once per turn
      in Prepare. }
    property KeysQuery: TSkillKeysQuery read FKeysQuery write FKeysQuery;
  end;

{ The activation payload for a skill: the body wrapped in <skill_content>, with
  its directory and a listed (not read) resource set. The owner calls this to
  inject the body into the conversation. }
function RenderSkillContent(const ASkill: TSkill): string;

const
  { The default idle TTL for a skill that does not set one. }
  DefaultSkillTtlMs = 600000;   // 10 minutes
  { The always-present activation tool's name. }
  LoadSkillToolName = 'load_skill';
  { The approval ref for activating a skill. The skill KEY is the parameter, so
    approving one skill never approves another. }
  SkillLoadRef = 'skill:load';
  { The explanation, once per session, alongside the descriptions. It must be
    TRUE: skills no longer decay (only MCP connections do), so the old text
    claiming idle unload, and pointing at a state line that no longer exists,
    would have told the model to look for something it cannot see. }
  SkillManifestHeader =
    'Skills you can load on demand with load_skill. A loaded skill stays in ' +
    'your context for the rest of the session:';

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
  E: TSkillEntry;
begin
  { Accept EITHER the key or the spec name. The catalogue now shows the name
    (changelog-writer), and the model calls load_skill with what it was shown -
    so refusing the name would break loading the moment the display was fixed.
    Key first: it is the canonical identifier, and a skill whose key and name
    differ only in punctuation must resolve by key. }
  for I := 0 to FEntries.Count - 1 do
    if TSkillEntry(FEntries[I]).Skill.Key = AKey then
      Exit(I);
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if SameText(E.Skill.Name, AKey) then
      Exit(I);
  end;
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

function TSkillRegistry.IsLoaded(const AEntry: TSkillEntry): Boolean;
var
  J: Integer;
begin
  { THE STORE DECIDES, when the owner supplied a query - but only for a skill
    that HAS a body. A tool-only source (an MCP server, today) writes no body
    row, so the store has nothing to answer with; asking it would report every
    such source as unloaded and silently remove its tools. Those keep their own
    activation state until the MCP split gives them their own lifecycle. }
  if Assigned(FKeysQuery) and (AEntry.Skill.Instructions <> '') then
  begin
    Result := False;
    for J := 0 to High(FLoadedKeys) do
      if FLoadedKeys[J] = AEntry.Skill.Key then
        Exit(True);
  end
  else
    Result := AEntry.State = ssLoaded;
end;

function TSkillRegistry.StateOf(const AKey: string): TSkillState;
var
  I: Integer;
begin
  I := IndexOfKey(AKey);
  if (I >= 0) and IsLoaded(TSkillEntry(FEntries[I])) then
    Result := ssLoaded
  else
    Result := ssUnloaded;
end;

function TSkillRegistry.SkillOf(const AKey: string): TSkill;
var
  I: Integer;
begin
  Result := Default(TSkill);
  I := IndexOfKey(AKey);
  if I >= 0 then
    Result := TSkillEntry(FEntries[I]).Skill;
end;

function TSkillRegistry.NameOf(const AKey: string): string;
begin
  Result := SkillOf(AKey).Name;
end;

function TSkillRegistry.InstructionsOf(const AKey: string): string;
begin
  Result := SkillOf(AKey).Instructions;
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

function TSkillRegistry.LoadedKeys: TStringArray;
var
  I: Integer;
begin
  { Derived, not stored: IsLoaded is the single answer, so this cannot disagree
    with what the manifest says or with what the store holds. }
  Result := nil;
  for I := 0 to FEntries.Count - 1 do
    if IsLoaded(TSkillEntry(FEntries[I])) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := TSkillEntry(FEntries[I]).Skill.Key;
    end;
end;

function RenderSkillContent(const ASkill: TSkill): string;
var
  I: Integer;
begin
  { The activation payload, in the shape the client guide recommends: an
    identifying tag, the body, the skill directory (so relative references
    resolve), and the bundled files. Resources are LISTED, not read - the model
    fetches what it needs with its file tools.

    The tag matters for two reasons beyond readability: the model can tell skill
    instructions from conversation, and compaction can recognise skill content
    when deciding what to prune. Losing instructions silently degrades the agent
    with no visible error. }
  Result := '<skill_content name="' + ASkill.Name + '">' + LineEnding;
  Result := Result + ASkill.Instructions + LineEnding;
  Result := Result + LineEnding;
  Result := Result + 'Skill directory: ' + ASkill.Location + LineEnding;
  Result := Result + 'Relative paths in this skill are relative to the skill '
    + 'directory.' + LineEnding;
  if Length(ASkill.Resources) > 0 then
  begin
    Result := Result + LineEnding + '<skill_resources>' + LineEnding;
    for I := 0 to High(ASkill.Resources) do
      Result := Result + '  <file>' + ASkill.Resources[I] + '</file>' + LineEnding;
    if ASkill.ResourcesTruncated then
      Result := Result + '  <note>the listing is incomplete</note>' + LineEnding;
    Result := Result + '</skill_resources>' + LineEnding;
  end;
  Result := Result + '</skill_content>';
end;

function TSkillRegistry.StableText: string;
var
  I: Integer;
  E: TSkillEntry;
begin
  { The description and when-to-use per skill: stable across a session, so it
    belongs in the system prompt rather than being re-sent on every request.

    A FILE-BACKED skill also carries its LOCATION. Without it a body saying "run
    scripts/extract.py" is unfollowable - the model has a file tool but no idea
    where the skill's own files live. The location is stable too, so it belongs
    here rather than in the per-request fragment. }
  Result := '';
  for I := 0 to FEntries.Count - 1 do
  begin
    E := TSkillEntry(FEntries[I]);
    if Result = '' then
      Result := SkillManifestHeader + LineEnding;
    Result := Result + '- ' + E.Skill.Name + ': ' + E.Skill.Description;
    if E.Skill.WhenToUse <> '' then
      Result := Result + ' ' + E.Skill.WhenToUse;
    { NO "(at <path>)" any more. The body is injected with its own
      "Skill directory:" line, so repeating the path here was the most visually
      prominent thing on the line and pure noise. }
    Result := Result + LineEnding;
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
    { A FILE-BACKED skill returns its body wrapped in identifying tags, with its
      directory and a resource listing. The tags are not decoration: they let the
      model tell skill instructions from conversation, and let compaction
      recognise skill content when deciding what to prune. The frontmatter is
      stripped because we already parsed it and re-sending it wastes tokens. }
    { The BODY is not returned here. It is injected into the conversation
      instead (see TSkillLoadedEvent): returning it would put the same text in
      the tool result AND in the context, and the tool result is the copy that
      gets truncated at the tool-result cap. The receipt below is the transcript
      record of what happened. }
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

procedure TSkillRegistry.SetApproval(const AApproval: IApprovalService;
  AWorkspaceId: Integer; const ASessionId: string);
begin
  FApproval := AApproval;
  FWorkspaceId := AWorkspaceId;
  FSessionId := ASessionId;
end;

function TSkillRegistry.ApproveLoad(const ASkill: TSkill;
  out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;

  { One option, persisted at AScope. Registered under Ref 'skill:load' with the
    skill KEY as the parameter, so approving one skill never approves another. }
  procedure AddOption(const AScope: TApprovalScope; const ACaption: string);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := 'skill_' + ACaption;
    Opt.Caption := ACaption;
    Opt.Persists := True;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Scope := AScope;
    Opt.Rule.WorkspaceId := FWorkspaceId;
    if AScope = asSession then
      Opt.Rule.SessionId := FSessionId
    else
      Opt.Rule.SessionId := '';
    Opt.Rule.Ref := SkillLoadRef;
    SetLength(Opt.Rule.Params, 1);
    Opt.Rule.Params[0] := ASkill.Key;
    Opt.Rule.AnyParams := False;
    SetLength(Ask.Options, Length(Ask.Options) + 1);
    Ask.Options[High(Ask.Options)] := Opt;
  end;

begin
  AError := '';
  { No service => no gate. A headless caller or a test supplies none and is not
    asked; the gate is the caller's to provide, not something to simulate. }
  if FApproval = nil then
    Exit(True);

  Ask := Default(TApprovalAsk);
  Ask.Summary := 'load skill "' + ASkill.Name + '"';
  Ask.Reason := 'Loading a skill puts its instructions into the conversation.';
  Ask.Subject.Ref := SkillLoadRef;
  SetLength(Ask.Subject.Params, 1);
  Ask.Subject.Params[0] := ASkill.Key;

  { Once is narrowest and leads, matching the dialog's risk ordering. The scoped
    grants follow: workspace is the useful default for a project skill - answer
    once and every session on that repo loads it without asking. }
  AddOption(asSession, 'once');
  AddOption(asWorkspace, 'always in this workspace');
  AddOption(asGlobal, 'always, everywhere');

  SetLength(Asks, 1);
  Asks[0] := Ask;
  if not FApproval.Resolve(Asks, Batch) then
  begin
    AError := 'approval error: ' + Batch.Reason;
    Exit(False);
  end;
  if Batch.Denied then
  begin
    { Reported as a refusal with its reason, so the model can proceed without the
      skill rather than retrying blindly. }
    AError := 'skill load refused: ' + Batch.Reason;
    Exit(False);
  end;
  Result := True;
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
  { NOT "is it activated" but "is its body in context". After a /checkpoint
    rebuild the store no longer has the row, so this is False and the load runs
    again - re-injecting the body. The approval gate below is a fast-path hit
    (the session-scope rule from the first load still stands), and the source
    activate is idempotent, so a recall re-delivers without re-prompting. }
  if IsLoaded(E) then
  begin
    { Already in context: a reload just resets the idle timer. }
    E.LastUsedMs := NowMs;
    Exit(True);
  end;
  { THE GATE, and only for a FILE-BACKED skill. A hand-registered or
    provider-backed skill was installed deliberately by the operator (an MCP
    server they configured), so it needs no per-load consent. A SKILL.md from a
    directory - including a cloned repo's - carries instructions nobody here
    wrote, so activating it is the moment to ask. }
  if E.Skill.Location <> '' then
  begin
    if not ApproveLoad(E.Skill, AError) then
      Exit(False);
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
  { ANNOUNCE, do not append. The owner delivers the body at a request boundary;
    appending from here would land a user message between the assistant's
    tool_calls message and its result. }
  if Assigned(FOnLoaded) then
    FOnLoaded(E.Skill);
  { Refresh the in-context cache NOW rather than waiting for the next turn: an
    operator load appends immediately, and until this runs every caller would see
    the skill as unloaded and could load it a second time. }
  if Assigned(FKeysQuery) then
    FLoadedKeys := FKeysQuery();
  Result := True;
end;

procedure TSkillRegistry.Prepare;
var
  I: Integer;
  E: TSkillEntry;
  Now: Int64;
begin
  { Decay at the turn boundary only: unload an idle skill - and, for a skill
    whose body lives in the store, re-read what is actually in context. This is
    the once-per-turn refresh that makes a /checkpoint rebuild visible: the body
    written before the boundary is gone, so the skill reads as unloaded and can
    be recalled. }
  if Assigned(FKeysQuery) then
    FLoadedKeys := FKeysQuery();
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
    if not IsLoaded(E) then
      Continue;
    for K := 0 to High(E.Tools) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := E.Tools[K];
    end;
  end;
end;

function TSkillRegistry.PromptFragment: string;
begin
  { NOTHING rides the per-request fragment any more.

    The BODY is injected once into the conversation as an mrSkill row and stays
    there, so re-sending it would only inflate the request. The STATE line that
    used to live here is gone too: a loaded skill's body is visibly in context,
    so restating "loaded" costs tokens to tell the model something it can see.
    The catalogue (descriptions) lives in StableText, in the system prompt. }
  Result := '';
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
    if not IsLoaded(E) then
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
