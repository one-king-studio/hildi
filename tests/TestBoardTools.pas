unit TestBoardTools;
{ Tests for the board's three tools. The interesting behaviours are the refusals:
  an unknown kind, a cross-topic supersede, a locked topic, and a denied
  moderation. All against a real store. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry,
  HildiLLM, HildiAgent, HildiApproval,
  HildiStore, HildiBoard, HildiBoardStore,
  HildiBoardTools;

type
  { Records the ask and answers however the test wants. }
  TFakeBoardApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Asks: Integer;
    LastSummary: string;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TBoardToolsTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FBoard: IBoardStore;
    FTools: TBoardTools;
    FToolsNoGate: TBoardTools;
    FApproval: TFakeBoardApproval;
    ApprovalRef: IApprovalService;
    FReg: TToolRegistry;
    function PostJson(const AKind, ATopic, ATitle: string;
      ASupersedes: Integer = 0): string;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPostAndReadRoundTrip;
    procedure TestReasonIsRequired;
    procedure TestUnknownKindListsTheValidOnes;
    procedure TestBodyRequiredExceptForANote;
    procedure TestSupersedeAcrossTopicsIsRefused;
    procedure TestPostToALockedTopicIsRefused;
    procedure TestReadOnAnEmptyBoardSaysSo;
    procedure TestModerateNeedsApprovalAndADenialChangesNothing;
    procedure TestModerateAllowedDeletes;
    procedure TestAllThreeToolsAreRegistered;
    { The TOC drops whole fields in a stated order, never truncating mid-field. }
    procedure TestTocDropOrderKeepsUnreadAndAge;
    { A peer is unaddressable if the board does not say who wrote an entry. }
    procedure TestReadNamesTheAuthor;
    { Full-text search spans titles, bodies and topics, and skips deleted. }
    procedure TestSearchFindsAnEntryByBodyTerm;
    { Pin is a MARKER, not a read-order. Pinned entries are recallable as a set;
      unpinning removes them from it. }
    procedure TestPinMarksAndPinnedRecallReturnsThemNewestFirst;
    procedure TestPinnedRecallIsEmptyWhenNothingIsPinned;
    procedure TestUnpinRemovesAnEntryFromThePinnedSet;
    procedure TestPinDoesNotChangeTheNormalReadOrder;
  end;

implementation

function TFakeBoardApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  Inc(Asks);
  if Length(AAsks) > 0 then
    LastSummary := AAsks[0].Summary;
  AResult := Default(TApprovalBatchResult);
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'operator said no';
  end;
  Result := True;
end;

function TBoardToolsTest.PostJson(const AKind, ATopic, ATitle: string;
  ASupersedes: Integer): string;
begin
  Result := '{"kind":"' + AKind + '","topic":"' + ATopic + '","title":"' +
    ATitle + '","body":"detail","reason":"test"' +
    IfThen(ASupersedes <> 0, ',"supersedes":' + IntToStr(ASupersedes)) + '}';
end;

procedure TBoardToolsTest.SetUp;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
  RStore: TSqliteStore;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhbt_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'bt.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  RStore := TSqliteStore.Create(Cfg);
  if not RStore.Open(Err) then
    raise Exception.Create('open: ' + Err.Message);
  FStore := RStore;
  FBoard := TSqliteBoardStore.Create(FStore);
  FApproval := TFakeBoardApproval.Create;
  { Hold the interface in a typed variable: `as` casting needs a GUID this
    interface does not declare. }
  ApprovalRef := FApproval;
  FTools := TBoardTools.Create(FBoard, 1, 'sess-a', 'parent', ApprovalRef);
  { A second instance with no gate at all, to prove ungated verbs are ungated
    rather than merely unasked. }
  FToolsNoGate := TBoardTools.Create(FBoard, 1, 'sess-a', 'parent', nil);
  FReg := TToolRegistry.Create;
  FToolsNoGate.Register(FReg);
end;

procedure TBoardToolsTest.TearDown;
begin
  FReg.Free;
  FToolsNoGate.Free;
  FTools.Free;
  FApproval := nil;
  FBoard := nil;
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

procedure TBoardToolsTest.TestPostAndReadRoundTrip;
var
  R, E: string;
  Ok: Boolean;
begin
  Ok := FTools.Post('{"kind":"finding","topic":"parser","title":"guard is in ' +
    'ParseWord","body":"not the lexer","reason":"test"}', R, E);
  AssertTrue('post ok: ' + E, Ok);
  AssertTrue('says posted', Pos('#1', R) > 0);
  Ok := FTools.ReadEntries('{"topic":"parser","reason":"test"}', R, E);
  AssertTrue('read ok: ' + E, Ok);
  AssertTrue('the title', Pos('guard is in ParseWord', R) > 0);
  AssertTrue('the body', Pos('not the lexer', R) > 0);
  { The newest live entry in its topic is marked current. }
  AssertTrue('marked current', Pos('current', R) > 0);
end;

procedure TBoardToolsTest.TestReasonIsRequired;
var
  R, E: string;
begin
  AssertFalse('refused', FTools.Post('{"kind":"note","topic":"t","title":"x"}',
    R, E));
  AssertTrue('names the reason', Pos('reason', E) > 0);
end;

procedure TBoardToolsTest.TestUnknownKindListsTheValidOnes;
var
  R, E: string;
begin
  AssertFalse('refused', FTools.Post('{"kind":"memo","topic":"t","title":"x",' +
    '"reason":"r"}', R, E));
  AssertTrue('names the valid kinds', Pos('finding', E) > 0);
  AssertTrue('all six', Pos('status', E) > 0);
end;

procedure TBoardToolsTest.TestBodyRequiredExceptForANote;
var
  R, E: string;
begin
  AssertFalse('a finding needs a body',
    FTools.Post('{"kind":"finding","topic":"t","title":"x","reason":"r"}',
      R, E));
  AssertTrue('says so', Pos('body', E) > 0);
  { A note may be empty. }
  AssertTrue('a note may be empty',
    FTools.Post('{"kind":"note","topic":"t","title":"x","reason":"r"}', R, E));
end;

procedure TBoardToolsTest.TestSupersedeAcrossTopicsIsRefused;
var
  R, E: string;
begin
  AssertTrue('first', FTools.Post(PostJson('finding', 'alpha', 'one'), R, E));
  { Entry 1 is in alpha; superseding it from beta would silently retire another
    page. }
  AssertFalse('refused', FTools.Post(PostJson('finding', 'beta', 'two', 1), R,
    E));
  AssertTrue('names the topic', Pos('alpha', E) > 0);
end;

procedure TBoardToolsTest.TestPostToALockedTopicIsRefused;
var
  R, E: string;
begin
  FApproval.Allow := True;
  AssertTrue('lock', FTools.Moderate('{"op":"lock","topic":"debate",' +
    '"reason":"cool off"}', R, E));
  AssertFalse('post refused',
    FTools.Post(PostJson('note', 'debate', 'my view'), R, E));
  AssertTrue('names the locker', Pos('locked by', E) > 0);
end;

procedure TBoardToolsTest.TestReadOnAnEmptyBoardSaysSo;
var
  R, E: string;
begin
  AssertTrue('read', FTools.ReadEntries('{"topic":"nothing","reason":"r"}', R,
    E));
  AssertEquals('absence is stated, not empty', '(no board messages)', R);
end;

procedure TBoardToolsTest.TestModerateNeedsApprovalAndADenialChangesNothing;
var
  R, E: string;
begin
  AssertTrue('post', FTools.Post(PostJson('note', 't', 'keep me'), R, E));
  FApproval.Allow := False;
  AssertFalse('denied', FTools.Moderate('{"op":"delete","id":1,"reason":"r"}',
    R, E));
  AssertTrue('an ask was raised', FApproval.Asks = 1);
  AssertTrue('the summary names the entry', Pos('keep me',
    FApproval.LastSummary) > 0);
  { The entry is still readable. }
  AssertTrue('read', FTools.ReadEntries('{"topic":"t","reason":"r"}', R, E));
  AssertTrue('still there', Pos('keep me', R) > 0);
end;

procedure TBoardToolsTest.TestModerateAllowedDeletes;
var
  R, E: string;
begin
  AssertTrue('post', FTools.Post(PostJson('note', 't', 'doomed'), R, E));
  FApproval.Allow := True;
  AssertTrue('allowed', FTools.Moderate('{"op":"delete","id":1,"reason":"r"}',
    R, E));
  AssertTrue('read', FTools.ReadEntries('{"topic":"t","reason":"r"}', R, E));
  AssertEquals('gone from reads', '(no board messages)', R);
end;

procedure TBoardToolsTest.TestSearchFindsAnEntryByBodyTerm;
{ Search spans titles, bodies and topics, and an empty result is stated rather
  than returned blank - the same treatment a bare read gets. }
var
  R, E: string;
begin
  AssertTrue('one', FTools.Post('{"kind":"finding","topic":"parser",' +
    '"title":"the guard","body":"the guard lives in ParseWord not the lexer",' +
    '"reason":"r"}', R, E));
  AssertTrue('two', FTools.Post('{"kind":"finding","topic":"retry",' +
    '"title":"backoff","body":"full jitter with a cap","reason":"r"}', R, E));

  { A term that appears only in one body. }
  AssertTrue('search', FTools.ReadEntries('{"query":"ParseWord","reason":"r"}',
    R, E));
  AssertTrue('found it', Pos('the guard', R) > 0);
  AssertTrue('and not the other', Pos('full jitter', R) = 0);

  { A term in a topic. }
  AssertTrue('by topic', FTools.ReadEntries('{"query":"retry","reason":"r"}',
    R, E));
  AssertTrue('found the retry entry', Pos('backoff', R) > 0);

  { Nothing matches: stated, not blank. }
  AssertTrue('no match', FTools.ReadEntries('{"query":"zzzznothing","reason":"r"}',
    R, E));
  AssertTrue('says so', Pos('nothing matched', R) > 0);
end;

procedure TBoardToolsTest.TestTocDropOrderKeepsUnreadAndAge;
{ The element is capped, and under pressure it must drop whole FIELDS in the
  stated order - f, then d, then q - never truncating mid-attribute and never
  losing `unread` or the age. A TOC that says only "2 unread" is actionable; one
  cut mid-field is not. }
var
  R, E: string;
  Line: string;
  I: Integer;
begin
  { Enough entries that all four counts are non-zero and the element is wide. }
  for I := 1 to 9 do
    AssertTrue('q', FTools.Post(PostJson('question', 't', 'q' + IntToStr(I)),
      R, E));
  for I := 1 to 9 do
    AssertTrue('d', FTools.Post(PostJson('decision', 't', 'd' + IntToStr(I)),
      R, E));
  for I := 1 to 9 do
    AssertTrue('f', FTools.Post(PostJson('finding', 't', 'f' + IntToStr(I)),
      R, E));

  Line := FTools.TocLine(E);
  AssertTrue('the element exists', Line <> '');
  { Bounded, and never truncated mid-field: it must end with the closing tag. }
  AssertTrue('bounded', Length(Line) <= MaxBoardTocBytes);
  AssertTrue('a complete element, not a cut one',
    Pos('</board>', Line) = Length(Line) - Length('</board>') + 1);
  { The two fields that always survive. }
  AssertTrue('unread survives', Pos('unread=', Line) > 0);
  AssertTrue('the age survives', Pos('last ', Line) > 0);
  { And if a field was dropped, it is never one of the two protected ones. }
  if Pos('f="', Line) = 0 then
    AssertTrue('unread still there when f went', Pos('unread=', Line) > 0);
end;

procedure TBoardToolsTest.TestAllThreeToolsAreRegistered;
var
  Tool: TRegisteredTool;
  Specs: TToolSpecArray;
  I: Integer;
  SawPost, SawRead, SawMod: Boolean;
begin
  Specs := FReg.Specs;
  SawPost := False;
  SawRead := False;
  SawMod := False;
  for I := 0 to High(Specs) do
  begin
    if Specs[I].Name = BoardPostTool then SawPost := True;
    if Specs[I].Name = BoardReadTool then SawRead := True;
    if Specs[I].Name = BoardModerateTool then SawMod := True;
  end;
  AssertTrue('board_post', SawPost);
  AssertTrue('board_read', SawRead);
  AssertTrue('board_moderate', SawMod);
  AssertTrue('findable', FReg.Find(BoardReadTool, Tool));
end;

procedure TBoardToolsTest.TestPinMarksAndPinnedRecallReturnsThemNewestFirst;
var
  A, B, C: Integer;
  Res, Err: string;
begin
  { Pin is a marker: "keep this one, I will want it again". Recall is the new
    half - before this, Pinned was stored and rendered but nothing could ask for
    the set. }
  AssertTrue('post A', FTools.Post(PostJson('decision', 'retry', 'first'), Res,
    Err));
  A := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));
  AssertTrue('post B', FTools.Post(PostJson('decision', 'retry', 'second'), Res,
    Err));
  B := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));
  AssertTrue('post C', FTools.Post(PostJson('finding', 'drain', 'third'), Res,
    Err));
  C := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));

  FApproval.Allow := True;
  AssertTrue('pin A', FTools.Moderate('{"op":"pin","id":' + IntToStr(A) +
    ',"reason":"keep"}', Res, Err));
  AssertTrue('pin C', FTools.Moderate('{"op":"pin","id":' + IntToStr(C) +
    ',"reason":"keep"}', Res, Err));

  AssertTrue('recall pinned', FTools.ReadEntries('{"pinned":true,' +
    '"reason":"t"}', Res, Err));
  { Newest first, so the freshest pin is the first thing read. }
  AssertTrue('A is there: ' + Res, Pos('#' + IntToStr(A), Res) > 0);
  AssertTrue('C is there: ' + Res, Pos('#' + IntToStr(C), Res) > 0);
  AssertTrue('C comes before A: ' + Res, Pos('#' + IntToStr(C), Res) <
    Pos('#' + IntToStr(A), Res));
  { B was never pinned. }
  AssertTrue('B is not pinned and not shown: ' + Res,
    Pos('#' + IntToStr(B) + ' ', Res) = 0);
end;

procedure TBoardToolsTest.TestPinnedRecallIsEmptyWhenNothingIsPinned;
var
  Res, Err: string;
begin
  AssertTrue('post', FTools.Post(PostJson('note', 'scratch', 'an unpinned note'),
    Res, Err));
  { An empty result is a success with a message, not a miss. }
  AssertTrue('recall', FTools.ReadEntries('{"pinned":true,"reason":"t"}', Res,
    Err));
  AssertTrue('says there are none: ' + Res, Pos('pinned', LowerCase(Res)) > 0);
end;

procedure TBoardToolsTest.TestUnpinRemovesAnEntryFromThePinnedSet;
var
  A: Integer;
  Res, Err: string;
begin
  AssertTrue('post', FTools.Post(PostJson('decision', 'retry', 'to unpin'), Res,
    Err));
  A := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));
  FApproval.Allow := True;
  AssertTrue('pin', FTools.Moderate('{"op":"pin","id":' + IntToStr(A) +
    ',"reason":"keep"}', Res, Err));
  AssertTrue('recall shows it', FTools.ReadEntries('{"pinned":true,"reason":"t"}',
    Res, Err));
  AssertTrue('present: ' + Res, Pos('#' + IntToStr(A), Res) > 0);

  AssertTrue('unpin', FTools.Moderate('{"op":"unpin","id":' + IntToStr(A) +
    ',"reason":"done with it"}', Res, Err));
  AssertTrue('recall again', FTools.ReadEntries('{"pinned":true,"reason":"t"}',
    Res, Err));
  AssertTrue('gone from the pinned set: ' + Res,
    Pos('#' + IntToStr(A), Res) = 0);
end;

procedure TBoardToolsTest.TestPinDoesNotChangeTheNormalReadOrder;
var
  A, B: Integer;
  Res, Err: string;
begin
  { The design decision this locks in: pin means "marked", not "first". Reading
    without `pinned` returns newest-first whether or not anything is pinned, so a
    pin can never reorder what a peer reads. Oldest-first or pinned-first would
    be a different feature, and this test exists so nobody drifts into it. }
  AssertTrue('post A', FTools.Post(PostJson('decision', 'retry', 'older'), Res,
    Err));
  A := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));
  AssertTrue('post B', FTools.Post(PostJson('decision', 'retry', 'newer'), Res,
    Err));
  B := StrToInt(Copy(Res, Pos('#', Res) + 1, 1));
  FApproval.Allow := True;
  AssertTrue('pin the OLDER one', FTools.Moderate('{"op":"pin","id":' +
    IntToStr(A) + ',"reason":"keep"}', Res, Err));

  AssertTrue('normal read', FTools.ReadEntries('{"topic":"retry","limit":10,' +
    '"reason":"t"}', Res, Err));
  AssertTrue('the newer is still first: ' + Res,
    Pos('#' + IntToStr(B), Res) < Pos('#' + IntToStr(A), Res));
end;

procedure TBoardToolsTest.TestReadNamesTheAuthor;
var
  Res, Err: string;
begin
  { Without authorship every entry is anonymous: an agent cannot tell its own
    note from a peer's, and must reconstruct that from conversation memory -
    which dies at the next context reset. }
  AssertTrue('post', FTools.Post(PostJson('decision', 'retry', 'attributed'),
    Res, Err));
  AssertTrue('read', FTools.ReadEntries('{"topic":"retry","reason":"t"}', Res,
    Err));
  { The label is preferred over the raw id: "by parent" reads better than a hex
    session id, and FromLabel is what a session declares about itself. }
  AssertTrue('names the author: ' + Res, Pos('by parent', Res) > 0);
end;

initialization
  RegisterTest(TBoardToolsTest);
end.
