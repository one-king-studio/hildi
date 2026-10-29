unit TestCoordination;
{ Tests for coordination-mode detection and the prompt it produces.

  The mode must be DETECTED rather than declared, and it must never guess: an
  unreadable store reports crUnknown, not "alone", because the wrong answer
  silently removes the obligation to coordinate. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiStore, HildiSession,
  HildiCoordination;

type
  TCoordinationTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FWs: Integer;
    FSession: string;
    function AddRuntime(const ASessionId: string): Boolean;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { Alone: one runtime, no children. }
    procedure TestASoleSessionIsSingleMode;
    { A peer attached to the same workspace flips it. }
    procedure TestAPeerRuntimeMakesItMultiMode;
    { A spawned child is multi even before its parent's runtime row exists. }
    procedure TestASpawnedChildIsMultiMode;
    { No store: say unknown rather than guess. }
    procedure TestNoStoreReportsUnknown;
    { The text: both modes described, plus a short mode line. }
    procedure TestThePromptDescribesTheBoardAndTheTaskList;
    procedure TestThePromptNamesTheModeAndItsOpposite;
    procedure TestThePromptAsksForProtocolsToBePinnedInMultiMode;
    procedure TestThePromptSaysTheBoardIsNotPersistence;
    procedure TestThePromptDistinguishesPeersFromSubagents;
    procedure TestAnUnknownModeDoesNotClaimYouAreAlone;
  end;

implementation

procedure TCoordinationTest.SetUp;
var
  Cfg: TStoreConfig;
  E: TStoreError;
  Ws: Integer;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhco_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'co.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(E) then
    raise Exception.Create('open: ' + E.Message);
  AssertTrue('workspace', FStore.EnsureWorkspace(FDir, Ws, E));
  FWs := Ws;
  AssertTrue('session', FStore.CreateSession(FWs, FSession, E));
  { The creating session registers its own runtime row, as the runtime does. }
  AddRuntime(FSession);
end;

procedure TCoordinationTest.TearDown;
begin
  if FStore <> nil then
  begin
    FStore.Close;
    FStore.Free;
    FStore := nil;
  end;
  if FileExists(FDbPath) then
    DeleteFile(FDbPath);
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

function TCoordinationTest.AddRuntime(const ASessionId: string): Boolean;
var
  E: TStoreError;
  Row: TSessionRuntimeRow;
begin
  Row := Default(TSessionRuntimeRow);
  Row.SessionId := ASessionId;
  Row.Pid := 1;
  Row.SocketPath := '/tmp/sock-' + ASessionId;
  Row.StartedAt := 1700000000;
  Row.UpdatedAt := 1700000000;
  Result := FStore.RegisterRuntime(Row, E);
end;

procedure TCoordinationTest.TestASoleSessionIsSingleMode;
var
  Mode: TCoordinationMode;
  Reason: TCoordinationReason;
  Peers: Integer;
begin
  Mode := DetectCoordinationMode(FStore, FWs, FSession, Peers, Reason);
  AssertEquals('single', Ord(cmSingle), Ord(Mode));
  AssertEquals('because only one runtime', Ord(crOnlyRuntime), Ord(Reason));
  AssertEquals('no peers', 0, Peers);
end;

procedure TCoordinationTest.TestAPeerRuntimeMakesItMultiMode;
var
  Mode: TCoordinationMode;
  Reason: TCoordinationReason;
  Peers: Integer;
  E: TStoreError;
  Other: string;
begin
  AssertTrue('peer session', FStore.CreateSession(FWs, Other, E));
  AssertTrue('peer runtime', AddRuntime(Other));
  Mode := DetectCoordinationMode(FStore, FWs, FSession, Peers, Reason);
  AssertEquals('multi', Ord(cmMulti), Ord(Mode));
  AssertEquals('because a peer runtime', Ord(crPeerRuntime), Ord(Reason));
  AssertEquals('one peer', 1, Peers);
end;

procedure TCoordinationTest.TestASpawnedChildIsMultiMode;
var
  Mode: TCoordinationMode;
  Reason: TCoordinationReason;
  Peers: Integer;
  E: TStoreError;
  Child: string;
begin
  { A child is multi by construction: a parent exists whether or not its runtime
    row is fresh, and the parent is the whole reason coordination matters. }
  AssertTrue('child', FStore.CreateChildSession(FWs, FSession, 1, 'sub',
    Child, E));
  Mode := DetectCoordinationMode(FStore, FWs, Child, Peers, Reason);
  AssertEquals('multi', Ord(cmMulti), Ord(Mode));
  AssertEquals('because it was spawned', Ord(crSpawnedChild), Ord(Reason));
end;

procedure TCoordinationTest.TestNoStoreReportsUnknown;
var
  Mode: TCoordinationMode;
  Reason: TCoordinationReason;
  Peers: Integer;
begin
  Mode := DetectCoordinationMode(nil, 1, 'x', Peers, Reason);
  AssertEquals('unknown, not single', Ord(crUnknown), Ord(Reason));
  { The mode value is irrelevant when the reason is unknown; the text must not
    claim solitude. }
  AssertEquals('no peer count invented', 0, Peers);
end;

procedure TCoordinationTest.TestThePromptDescribesTheBoardAndTheTaskList;
var
  P: string;
begin
  P := CoordinationPromptFor(cmSingle, crOnlyRuntime);
  { Both surfaces must be taught by name: a model that has never seen them cannot
    infer what board_post or task_claim are for. }
  AssertTrue('board_post: ' + P, Pos('board_post', P) > 0);
  AssertTrue('board_read', Pos('board_read', P) > 0);
  AssertTrue('task_add', Pos('task_add', P) > 0);
  AssertTrue('task_claim', Pos('task_claim', P) > 0);
  { And the append-only discipline, which is the board's defining rule. }
  AssertTrue('supersedes', Pos('supersedes', P) > 0);
end;

procedure TCoordinationTest.TestThePromptNamesTheModeAndItsOpposite;
var
  Single, Multi: string;
begin
  Single := CoordinationPromptFor(cmSingle, crOnlyRuntime);
  Multi := CoordinationPromptFor(cmMulti, crPeerRuntime);
  AssertTrue('single says alone: ' + Single, Pos('ALONE', Single) > 0);
  AssertTrue('multi says not alone: ' + Multi, Pos('NOT alone', Multi) > 0);
  { Both describe both surfaces and both rule sets: the stable half must not
    change when a peer appears, or the cache churns on every peer arrival. }
  AssertTrue('single still teaches the board', Pos('board_post', Single) > 0);
  AssertTrue('multi still teaches the board', Pos('board_post', Multi) > 0);
  AssertTrue('both ask for claiming', Pos('Claim before you change', Multi) > 0);
end;

procedure TCoordinationTest.TestThePromptAsksForProtocolsToBePinnedInMultiMode;
var
  P: string;
begin
  P := CoordinationPromptFor(cmMulti, crPeerRuntime);
  { The one instruction that only makes sense with a peer: agree protocols up
    front and pin them to the board, so they outlive the conversation. }
  AssertTrue('names the protocols topic: ' + P, Pos('protocols', P) > 0);
  AssertTrue('says to pin them', Pos('PIN', P) > 0);
  AssertTrue('and names path ownership', Pos('paths', P) > 0);
end;

procedure TCoordinationTest.TestAnUnknownModeDoesNotClaimYouAreAlone;
var
  P: string;
begin
  P := CoordinationPromptFor(cmSingle, crUnknown);
  { crUnknown with cmSingle is exactly the dangerous combination: defaulting to
    "alone" would remove the obligation to coordinate on a workspace that might
    be shared. }
  AssertTrue('does not say alone: ' + P, Pos('ALONE', P) = 0);
  AssertTrue('says it may be shared', Pos('may be shared', P) > 0);
end;

procedure TCoordinationTest.TestThePromptSaysTheBoardIsNotPersistence;
var
  P: string;
begin
  { The correction the design doc exists to make: the board is frictionless, so
    it quietly replaces the durable record. The rule must ride every request, not
    only live in a document. }
  P := CoordinationPromptFor(cmSingle, crOnlyRuntime);
  AssertTrue('names coordination: ' + P, Pos('COORDINATION', P) > 0);
  AssertTrue('names persistence', Pos('persistence', P) > 0);
  AssertTrue('says artifacts belong in a FILE', Pos('FILE', P) > 0);
  AssertTrue('says it is pruned', Pos('pruned', P) > 0);
  AssertTrue('and invisible to the repo', Pos('repo', P) > 0);
end;

procedure TCoordinationTest.TestThePromptDistinguishesPeersFromSubagents;
var
  P: string;
begin
  { A subagent has a parent that decides; a peer is an equal. Conflating them
    applies consensus rules where an owner already exists. }
  P := CoordinationPromptFor(cmMulti, crPeerRuntime);
  AssertTrue('names peer sessions: ' + P, Pos('PEER SESSIONS', P) > 0);
  AssertTrue('says peers are equals', Pos('equals', P) > 0);
  AssertTrue('names subagent as the other thing', Pos('subagent', P) > 0);
  AssertTrue('and says a subagent has a parent', Pos('parent', P) > 0);
end;

initialization
  RegisterTest(TCoordinationTest);
end.
