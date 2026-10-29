unit TestTUIChat;
{ fpcunit tests for TUIWidgetsChat: the mutable message blocks and
  the scrolling stream. Rendering is asserted through TSurfaceMemory. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput,
  TUISurface, TUITheme,
  TUIClock, TUIWidgetsChat;

type
  TTuiChatTest = class(TTestCase)
  private
    FTheme: TTheme;
    FToggles: Integer;
    FNeedOlder: Integer;
    FScrolled: Integer;
    FClickedPath: string;
    procedure OnToggle(Sender: TObject);
    procedure NoteFile(Sender: TObject; ATurnId: Int64;
      const APath: string);
    procedure NoteNeedOlder(Sender: TObject);
    procedure NoteScrolled(Sender: TObject);
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Avail(AW, AH: Integer): TSize;
    function MouseEvent(AX, AY: Integer): TInputEvent;
  protected
    procedure SetUp; override;
  published
    { Blocks. }
    procedure TestItemKeepsKindLabelAndText;
    procedure TestSetTextReplacesAndChangesHeight;
    procedure TestAppendTextAccumulates;
    procedure TestSetTextFiresOnChange;
    { Rendering. }
    procedure TestUserBubbleDrawsRaisedChrome;
    procedure TestAssistantRendersPlainText;
    procedure TestAssistantRendersMarkdown;
    procedure TestStreamedAssistantDoesNotSplitTheFirstToken;
    procedure TestFinalizeRendersTheLastStreamedBlock;
    procedure TestSetTextAfterStreamResetsStreaming;
    procedure TestStreamSurvivesAReleaseAndRebuild;
    procedure TestSetTextThenAppendRendersOneBlock;
    procedure TestCollapsedThoughtDrawsADimmedRule;
    procedure TestTurnDividerDrawsRuleAndRightAlignedStats;
    { A turn-changes block resolves a click's ROW back to a workspace path, so the
      host can open that file's diff without knowing the frame geometry. }
    procedure TestFileRowResolvesToItsPath;
    { The `· N more files` tail row is not a file: it resolves to '' rather than
      to the last file or to garbage. }
    procedure TestTheMoreFilesTailIsNotAFile;
    { A click outside the file rows, and on a block with no file paths, resolves
      to '' instead of crashing or inventing a path. }
    procedure TestARowOutsideTheFilesSelectsNothing;
    { The whole chain: a click on a file row reaches the host with that file's
      path, so the app can open its diff. }
    procedure TestClickingAFileRowRaisesThePath;
    procedure TestCollapsedToolDrawsAThinFullContrastRule;
    procedure TestAmbientBlockRenders;
    procedure TestAmbientRendersMarkdownInABox;
    procedure TestAmbientCaretRidesTheBottomBorder;
    procedure TestCollapsedAmbientIsShorter;
    procedure TestHandoffRendersAsACarriedContextBox;
    procedure TestCollapsedToolCaretRidesTheBottomBorder;
    procedure TestLongToolTitleIsTruncated;
    procedure TestLiveThoughtShowsTheTail;
    procedure TestExpandedThoughtDrawsABox;
    procedure TestThinkingIndicatorRenders;
    procedure TestThinkingAnimates;
    { Activity spinner. }
    procedure TestActivityFrameAdvances;
    procedure TestLiveThoughtShrinksToItsContent;
    procedure TestLiveBoxDrawsTheSpinner;
    procedure TestIdleBoxShowsTheCaret;
    procedure TestThinkingRowDrawsTheSpinner;
    { Interaction. }
    procedure TestClickTogglesAThoughtBlock;
    procedure TestClickOnAssistantIsIgnored;
    { Stream. }
    procedure TestStreamAddAccessAndClear;
    procedure TestStreamRemoveDropsOneBlock;
    procedure TestStreamKeepsTheNewestBlockVisible;
    procedure TestStreamReservesTheBottomInset;
    procedure TestStreamFiresNeedOlderAtTheTop;
    procedure TestANewBlockDoesNotYankAScrolledUpReader;
    procedure TestAReaderAtTheBottomKeepsFollowing;
    procedure TestPreserveAnchorKeepsTheVisibleContent;
    procedure TestScrollToStopsFollowingAndMoves;
    procedure TestScrollNotifiesTheHost;
    procedure TestOffsetOfReportsTheBlockTop;
    procedure TestStackMaterializesOnlyTheWindow;
    procedure TestStackLayoutDoesNotThrashAcrossMeasureAndArrange;
    procedure TestStreamWidthFollowsTheViewport;
    procedure TestStackTracksAnimatingBlocks;
    procedure TestStreamOnChangeFiresWhenABlockGrows;
    procedure TestToggleKeepsTheBlockTopInPlace;
    procedure TestToggleThroughTheStreamKeepsTheBlockTop;
  end;

implementation

procedure TTuiChatTest.SetUp;
begin
  FTheme := DarkTheme;
  FToggles := 0;
  FNeedOlder := 0;
  FScrolled := 0;
end;

procedure TTuiChatTest.OnToggle(Sender: TObject);
begin
  Inc(FToggles);
end;

procedure TTuiChatTest.NoteFile(Sender: TObject; ATurnId: Int64;
  const APath: string);
begin
  FClickedPath := APath;
end;

procedure TTuiChatTest.NoteNeedOlder(Sender: TObject);
begin
  Inc(FNeedOlder);
end;

procedure TTuiChatTest.NoteScrolled(Sender: TObject);
begin
  Inc(FScrolled);
end;

function TTuiChatTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiChatTest.Avail(AW, AH: Integer): TSize;
begin
  Result := Default(TSize);
  Result.W := AW;
  Result.H := AH;
end;

function TTuiChatTest.MouseEvent(AX, AY: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := AX;
  Result.Mouse.Y := AY;
  Result.Mouse.Button := mbLeft;
end;

procedure TTuiChatTest.TestItemKeepsKindLabelAndText;
var
  It: TChatItem;
begin
  It := TChatItem.Create(ckTool, 'run_command', 'ls', FTheme);
  try
    AssertTrue('kind kept', It.Kind = ckTool);
    AssertEquals('label kept', 'run_command', It.Label_);
    AssertEquals('text kept', 'ls', It.Text);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestSetTextReplacesAndChangesHeight;
var
  It: TChatItem;
  Short, Long: Integer;
begin
  It := TChatItem.Create(ckAssistant, '', 'one line', FTheme);
  try
    Short := It.Measure(Avail(20, 0)).H;
    It.SetText('one line' + #10 + 'two lines' + #10 + 'three lines');
    Long := It.Measure(Avail(20, 0)).H;
    AssertEquals('text replaced', 'one line' + #10 + 'two lines' + #10 +
      'three lines', It.Text);
    AssertTrue('height grew with the text', Long > Short);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestAppendTextAccumulates;
var
  It: TChatItem;
begin
  It := TChatItem.Create(ckAssistant, '', 'Hello', FTheme);
  try
    It.AppendText(', ');
    It.AppendText('world');
    AssertEquals('appended', 'Hello, world', It.Text);
    It.AppendText('');
    AssertEquals('an empty append is a no-op', 'Hello, world', It.Text);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestSetTextFiresOnChange;
var
  It: TChatItem;
  Changes: Integer;
begin
  It := TChatItem.Create(ckAssistant, '', 'a', FTheme);
  try
    Changes := 0;
    It.OnChange := OnToggle;   { reuse the counter }
    It.SetText('b');
    AssertEquals('set fired', 1, FToggles);
    It.SetText('b');
    AssertEquals('an unchanged set is silent', 1, FToggles);
    It.AppendText('c');
    AssertEquals('append fired', 2, FToggles);
    AssertEquals('no stray counter', 0, Changes);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestUserBubbleDrawsRaisedChrome;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(24, 5);
  try
    It := TChatItem.Create(ckUser, '', 'hello there', FTheme);
    try
      It.Arrange(Rc(0, 0, 24, It.Measure(Avail(24, 0)).H));
      It.Render(S);
      AssertEquals('rounded top-left corner', '╭', S.CellAt(0, 0).Ch);
      AssertEquals('heavy bottom-left corner', '╰', S.CellAt(0, It.Bounds.H - 1).Ch);
      AssertEquals('heavy bottom edge', '═', S.CellAt(1, It.Bounds.H - 1).Ch);
      AssertEquals('raised background', FTheme.RaisedBg, S.CellAt(2, 1).Attr.Bg);
      AssertTrue('text rendered', Pos('hello', S.RowText(1, 0, 24)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestAssistantRendersPlainText;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(24, 3);
  try
    It := TChatItem.Create(ckAssistant, '', 'plain words', FTheme);
    try
      It.Arrange(Rc(0, 0, 24, It.Measure(Avail(24, 0)).H));
      It.Render(S);
      { Blank cells are the erased char (''), so assert the cells, not the row. }
      AssertEquals('column 0 is the inset gap', '', S.CellAt(0, 0).Ch);
      AssertEquals('text starts at column 1', 'p', S.CellAt(1, 0).Ch);
      AssertTrue('full text rendered', Pos('plain words', S.RowText(0, 0, 24)) > 0);
      AssertTrue('no bubble corner', S.CellAt(0, 0).Ch <> '╭');
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestAssistantRendersMarkdown;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(24, 5);
  try
    It := TChatItem.Create(ckAssistant, '', '**bold** and a list:' + #10 +
      '- one', FTheme);
    try
      It.Arrange(Rc(0, 0, 24, It.Measure(Avail(24, 0)).H));
      It.Render(S);
      { Column 1 is the assistant inset. }
      AssertTrue('the bold run is styled', sfBold in S.CellAt(1, 0).Attr.Style);
      AssertFalse('the plain run is not bold',
        sfBold in S.CellAt(6, 0).Attr.Style);
      { The paragraph is row 0, a blank row separates it, the list is row 2. }
      AssertTrue('the list bullet is drawn', S.CellAt(1, 2).Ch = '•');
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStreamedAssistantDoesNotSplitTheFirstToken;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 6);
  try
    { The live path creates the block empty, then appends each delta; the first
      delta must not be committed as its own block. }
    It := TChatItem.Create(ckAssistant, '', '', FTheme);
    try
      It.AppendText('I');
      It.AppendText('''ve read the docs');
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('the first token is not split onto its own line',
        Pos('I''ve read the docs', S.RowText(0, 0, 40)) > 0);
      { No paragraph break: the text is one wrapped run, so row 1 is blank. }
      AssertEquals('no spurious second block', '', S.CellAt(1, 1).Ch);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestFinalizeRendersTheLastStreamedBlock;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 6);
  try
    It := TChatItem.Create(ckAssistant, '', '', FTheme);
    try
      It.AppendText('see `code`');
      { While streaming the open tail is raw (unstyled); finalizing parses it. }
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('the tail is raw while streaming',
        Pos('`code`', S.RowText(0, 0, 40)) > 0);
      It.Finalize;
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertEquals('the backticks are parsed away', 0,
        Pos('`code`', S.RowText(0, 0, 40)));
      AssertTrue('the inline code text remains', Pos('code',
        S.RowText(0, 0, 40)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestSetTextAfterStreamResetsStreaming;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 6);
  try
    { A tool block streams live, then settles with its authoritative result via
      SetText; the result must render as one block, not append to the stream. }
    It := TChatItem.Create(ckAssistant, '', '', FTheme);
    try
      It.AppendText('partial');
      It.SetText('**done**');
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('the replaced text is drawn', Pos('done',
        S.RowText(0, 0, 40)) > 0);
      AssertTrue('the streamed text is gone', Pos('partial',
        S.RowText(0, 0, 40)) = 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStreamSurvivesAReleaseAndRebuild;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 6);
  try
    { A streamed block scrolled off-screen releases its view; a later chunk
      must resume the stream from the whole body, not split it. }
    It := TChatItem.Create(ckAssistant, '', '', FTheme);
    try
      It.AppendText('I');
      It.AppendText('''ve read the docs');
      It.Dematerialize;               { released off-screen }
      It.AppendText(' and more');
      It.Finalize;
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('the whole body is one block',
        Pos('I''ve read the docs and more', S.RowText(0, 0, 40)) > 0);
      AssertEquals('no spurious split', '', S.CellAt(1, 1).Ch);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestSetTextThenAppendRendersOneBlock;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 6);
  try
    { A body settled with SetText (a finished parser) that then keeps streaming
      must be re-parsed from the whole body, or the pre-settle text and the new
      chunk render as two blocks. }
    It := TChatItem.Create(ckAssistant, '', '', FTheme);
    try
      It.AppendText('one');
      It.SetText('one two');
      It.AppendText(' three');
      It.Finalize;
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('the combined body is one block',
        Pos('one two three', S.RowText(0, 0, 40)) > 0);
      AssertEquals('no spurious split', '', S.CellAt(1, 1).Ch);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestCollapsedThoughtDrawsADimmedRule;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  { A short thought is a box (not a collapsed rule): rounded top-left corner and
    the label in the title. }
  S := TSurfaceMemory.Create(30, 3);
  try
    It := TChatItem.Create(ckThought, 'Thought', 'body', FTheme);
    try
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 30, 3));
      It.Render(S);
      AssertEquals('rounded top-left', '╭', S.CellAt(0, 0).Ch);
      AssertTrue('label shown', Pos('Thought', S.RowText(0, 0, 30)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestFileRowResolvesToItsPath;
var
  It: TChatItem;
begin
  { The collapsed body is one row per file, so a click's row maps to a path. The
    host needs this to open the right file's diff without re-deriving the frame
    geometry - which is why the block records its body origin when it arranges. }
  It := TChatItem.Create(ckTurnChanges, 'turn changes',
    'M a.txt  +1 -0'#10'M b.txt  +2 -1', FTheme);
  try
    It.SetFilePaths(['a.txt', 'b.txt']);
    It.Materialize;
    It.Measure(Avail(40, 12));
    It.Arrange(Rc(0, 0, 40, 12));
    { A boxed block's body starts one row below the frame top. }
    AssertEquals('the first file row', 'a.txt', It.FilePathAtRow(1));
    AssertEquals('the second file row', 'b.txt', It.FilePathAtRow(2));
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestTheMoreFilesTailIsNotAFile;
var
  It: TChatItem;
begin
  { `· 3 more files` is a statement about the block, not a file. It resolves to
    '' rather than to the last real path: there is no single file behind it. }
  It := TChatItem.Create(ckTurnChanges, 'turn changes',
    'M a.txt  +1 -0'#10#$C2#$B7' 3 more files  +4 -2', FTheme);
  try
    It.SetFilePaths(['a.txt', '']);
    It.Materialize;
    It.Measure(Avail(40, 12));
    It.Arrange(Rc(0, 0, 40, 12));
    AssertEquals('the file row', 'a.txt', It.FilePathAtRow(1));
    AssertEquals('the tail is not a file', '', It.FilePathAtRow(2));
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestARowOutsideTheFilesSelectsNothing;
var
  It: TChatItem;
begin
  { A click above the body, below the last file, or on a block that never
    declared file paths must all resolve to '' - never to a guessed path. }
  It := TChatItem.Create(ckTurnChanges, 'turn changes', 'M a.txt  +1 -0', FTheme);
  try
    It.SetFilePaths(['a.txt']);
    It.Materialize;
    It.Measure(Avail(40, 12));
    It.Arrange(Rc(0, 0, 40, 12));
    AssertEquals('the frame row above the body', '', It.FilePathAtRow(0));
    AssertEquals('well past the last file', '', It.FilePathAtRow(9));
    It.SetFilePaths([]);
    AssertEquals('a block with no paths', '', It.FilePathAtRow(1));
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestClickingAFileRowRaisesThePath;
var
  Stack: TChatStack;
  S: TSurfaceMemory;
  Item: TChatItem;
begin
  { The whole chain, not just the block's arithmetic: the stack must attach the
    handler to blocks it creates, the block must resolve the row, and the host
    must receive the path. Testing FilePathAtRow alone would pass even if nothing
    were wired to it - which is exactly how the pane sat unopenable. }
  AnimationClock.Reset;
  S := TSurfaceMemory.Create(40, 12);
  Stack := TChatStack.Create(FTheme);
  try
    FClickedPath := '';
    Stack.OnFile := NoteFile;
    Item := Stack.Add(ckTurnChanges, 'turn changes',
      'M a.txt  +1 -0'#10'M b.txt  +2 -1');
    Item.SetFilePaths(['a.txt', 'b.txt']);
    Item.Materialize;
    Item.Measure(Avail(40, 12));
    Item.Arrange(Rc(0, 0, 40, 12));

    { Row 1 is the first file (a boxed block's body starts below the frame). }
    AssertTrue('the click is consumed', Item.HandleEvent(MouseEvent(2, 1)));
    AssertEquals('the host got the file the row names', 'a.txt', FClickedPath);

    FClickedPath := '';
    AssertTrue('second row', Item.HandleEvent(MouseEvent(2, 2)));
    AssertEquals('and the second file', 'b.txt', FClickedPath);

    { A click on the frame is NOT a file: the host must not be told one. }
    FClickedPath := '';
    Item.HandleEvent(MouseEvent(2, 0));
    AssertEquals('no path for a non-file row', '', FClickedPath);
  finally
    Stack.Free;
    S.Free;
  end;
end;

procedure TTuiChatTest.TestTurnDividerDrawsRuleAndRightAlignedStats;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(60, 1);
  try
    It := TChatItem.Create(ckTurn, '', '1.2k in 310 out 3.4s 2 req', FTheme);
    try
      It.Arrange(Rc(0, 0, 60, 1));
      It.Render(S);
      AssertEquals('rule starts at column 1', '─', S.CellAt(1, 0).Ch);
      AssertTrue('stats shown', Pos('1.2k in', S.RowText(0, 0, 60)) > 0);
      AssertEquals('one trailing rule at the right edge', '─',
        S.CellAt(59, 0).Ch);
      AssertTrue('dimmed', sfDim in S.CellAt(1, 0).Attr.Style);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestCollapsedToolDrawsAThinFullContrastRule;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  { A short tool is a box; the reason is the title and the border uses the tool
    colour (23), not the dimmed accent. }
  S := TSurfaceMemory.Create(60, 3);
  try
    It := TChatItem.Create(ckTool, 'looking for the build file', 'body', FTheme);
    try
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 60, 3));
      It.Render(S);
      AssertEquals('rounded top-left', '╭', S.CellAt(0, 0).Ch);
      AssertTrue('reason shown as the title',
        Pos('looking for the build file', S.RowText(0, 0, 60)) > 0);
      AssertEquals('tool border colour', 23, S.CellAt(0, 0).Attr.Fg);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestLongToolTitleIsTruncated;
var
  It: TChatItem;
  S: TSurfaceMemory;
  R: UnicodeString;
begin
  { A box needs a top and a bottom row: the title rides the top border, and the
    bottom border is drawn below it. }
  S := TSurfaceMemory.Create(30, 3);
  try
    It := TChatItem.Create(ckTool,
      'a reason that is far too long to fit in this narrow block', 'body',
      FTheme);
    try
      It.Arrange(Rc(0, 0, 30, 3));
      It.Render(S);
      R := S.RowText(0, 0, 30);
      AssertTrue('title ends with an ellipsis', Pos('…', R) > 0);
      { The chrome still fits: the title cannot push the corner off. }
      AssertEquals('rounded top-left', '╭', S.CellAt(0, 0).Ch);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestLiveThoughtShowsTheTail;
const
  Tokens: array[0..9] of string =
    ('aa', 'bb', 'cc', 'dd', 'ee', 'ff', 'gg', 'hh', 'ii', 'jj');
var
  It: TChatItem;
  S: TSurfaceMemory;
  I, H: Integer;
  Body: string;
  Full: UnicodeString;
  Sz: TSize;
begin
  Body := '';
  for I := 0 to 9 do
  begin
    if I > 0 then
      Body := Body + #10;
    Body := Body + Tokens[I];
  end;
  S := TSurfaceMemory.Create(40, 12);
  try
    It := TChatItem.Create(ckThought, 'Thinking...', Body, FTheme);
    try
      It.Live := True;
      Sz := Default(TSize);
      Sz.W := 40;
      H := It.Measure(Sz).H;
      It.Arrange(Rc(0, 0, 40, H));
      It.Render(S);
      Full := '';
      for I := 0 to H - 1 do
        Full := Full + S.RowText(I, 0, 40) + UnicodeString(#10);
      AssertTrue('live title', Pos('Thinking...', Full) > 0);
      AssertFalse('no ellipsis marker in the live tail',
        Pos(UnicodeString('…'), Full) > 0);
      AssertTrue('the tail is shown', Pos('jj', Full) > 0);
      AssertFalse('the head is dropped', Pos('aa', Full) > 0);

      { On completion the app renames it and collapses it. }
      It.Live := False;
      It.Label_ := 'Thought';
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 40, It.Measure(Avail(40, 0)).H));
      It.Render(S);
      AssertTrue('settled into a Thought box',
        Pos('Thought', S.RowText(0, 0, 40)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestExpandedThoughtDrawsABox;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(30, 4);
  try
    It := TChatItem.Create(ckThought, 'Thought', 'the body text', FTheme);
    try
      It.Expanded := True;
      It.Arrange(Rc(0, 0, 30, It.Measure(Avail(30, 0)).H));
      It.Render(S);
      AssertEquals('box top-left', '╭', S.CellAt(0, 0).Ch);
      AssertEquals('box bottom-left', '╰', S.CellAt(0, It.Bounds.H - 1).Ch);
      AssertTrue('label in the top border',
        Pos('Thought', S.RowText(0, 0, 30)) > 0);
      AssertTrue('body rendered', Pos('the body', S.RowText(1, 0, 30)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestThinkingIndicatorRenders;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(20, 1);
  try
    It := TChatItem.Create(ckThinking, '', '', FTheme);
    try
      It.Arrange(Rc(0, 0, 20, 1));
      It.Render(S);
      AssertTrue('thinking label', Pos('Thinking', S.RowText(0, 0, 20)) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestThinkingAnimates;
var
  It: TChatItem;
begin
  It := TChatItem.Create(ckThinking, '', '', FTheme);
  try
    AssertTrue('thinking animates', It.Animating);
    AssertFalse('same spark at the same time', It.Advance(0));
    AssertTrue('spark advanced', It.Advance(90));
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestActivityFrameAdvances;
var
  A, B, C: UnicodeString;
begin
  A := ActivityFrame(0);
  AssertEquals('same frame within the interval', A, ActivityFrame(89));
  B := ActivityFrame(90);
  AssertTrue('the frame advances across the interval', B <> A);
  C := ActivityFrame(90 * 10);
  AssertEquals('the frames cycle', A, C);
end;

procedure TTuiChatTest.TestLiveThoughtShrinksToItsContent;
var
  Short, Three, ThreeTrailing, Six, Ten: TChatItem;

  function H(AItem: TChatItem): Integer;
  begin
    Result := AItem.Measure(Avail(30, 40)).H;
  end;

begin
  { A live block shows at most six body rows and otherwise only what it has,
    so it grows with the stream instead of reserving blank rows. }
  Short := TChatItem.Create(ckThought, 'T', 'one', FTheme);
  Three := TChatItem.Create(ckThought, 'T', 'aaa'#10'bbb'#10'ccc', FTheme);
  ThreeTrailing := TChatItem.Create(ckThought, 'T', 'aaa'#10'bbb'#10'ccc'#10,
    FTheme);
  Six := TChatItem.Create(ckThought, 'T',
    '1'#10'2'#10'3'#10'4'#10'5'#10'6', FTheme);
  Ten := TChatItem.Create(ckThought, 'T',
    '1'#10'2'#10'3'#10'4'#10'5'#10'6'#10'7'#10'8'#10'9'#10'10', FTheme);
  try
    Short.Live := True;
    Three.Live := True;
    ThreeTrailing.Live := True;
    Six.Live := True;
    Ten.Live := True;
    AssertTrue('a one-line live block is not padded to six rows',
      H(Short) < H(Six));
    AssertEquals('the tail caps at six rows', H(Six), H(Ten));
    AssertEquals('a trailing blank row adds nothing', H(Three),
      H(ThreeTrailing));
  finally
    Short.Free;
    Three.Free;
    ThreeTrailing.Free;
    Six.Free;
    Ten.Free;
  end;
end;

procedure TTuiChatTest.TestLiveBoxDrawsTheSpinner;
var
  It: TChatItem;
  S: TSurfaceMemory;
  Row: UnicodeString;
begin
  S := TSurfaceMemory.Create(30, 3);
  try
    It := TChatItem.Create(ckTool, 'run_command', 'output', FTheme);
    try
      It.Live := True;
      It.Arrange(Rc(0, 0, 30, 3));
      It.Render(S);
      { The bottom border carries the spinner frame near the right corner. }
      Row := S.RowText(2, 0, 30);
      AssertTrue('a spinner frame rides the bottom border',
        (Pos(ActivityFrame(0), Row) > 0) or (Pos('⠋', Row) > 0) or
        (Pos('⠙', Row) > 0) or (Pos('⠹', Row) > 0) or (Pos('⠸', Row) > 0) or
        (Pos('⠼', Row) > 0) or (Pos('⠴', Row) > 0) or (Pos('⠦', Row) > 0) or
        (Pos('⠧', Row) > 0) or (Pos('⠇', Row) > 0) or (Pos('⠏', Row) > 0));
      AssertTrue('a live box animates', It.Animating);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestIdleBoxShowsTheCaret;
var
  It: TChatItem;
  S: TSurfaceMemory;
  Row: UnicodeString;
begin
  S := TSurfaceMemory.Create(30, 6);
  try
    It := TChatItem.Create(ckTool, 'run_command', StringOfChar('x', 400), FTheme);
    try
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 30, 6));
      It.Render(S);
      Row := S.RowText(5, 0, 30);
      AssertTrue('the caret rides the bottom border', Pos('▼', Row) > 0);
      AssertFalse('a settled box does not animate', It.Animating);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestThinkingRowDrawsTheSpinner;
var
  It: TChatItem;
  S: TSurfaceMemory;
  Row: UnicodeString;
begin
  S := TSurfaceMemory.Create(20, 1);
  try
    It := TChatItem.Create(ckThinking, '', '', FTheme);
    try
      It.Advance(0);
      It.Arrange(Rc(0, 0, 20, 1));
      It.Render(S);
      Row := S.RowText(0, 0, 20);
      AssertTrue('the thinking row shows the spinner frame',
        Pos(ActivityFrame(0), Row) > 0);
      AssertTrue('the label follows', Pos('Thinking', Row) > 0);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestClickTogglesAThoughtBlock;
var
  It: TChatItem;
begin
  It := TChatItem.Create(ckThought, 'Thought', 'body', FTheme);
  try
    It.Expanded := False;
    It.OnToggle := OnToggle;
    It.Arrange(Rc(0, 0, 30, 1));
    AssertTrue('click handled', It.HandleEvent(MouseEvent(3, 0)));
    AssertTrue('expanded', It.Expanded);
    AssertEquals('toggle fired', 1, FToggles);
    It.HandleEvent(MouseEvent(3, 0));
    AssertFalse('collapsed again', It.Expanded);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestClickOnAssistantIsIgnored;
var
  It: TChatItem;
begin
  It := TChatItem.Create(ckAssistant, '', 'text', FTheme);
  try
    It.Arrange(Rc(0, 0, 30, 1));
    AssertFalse('assistant blocks do not toggle',
      It.HandleEvent(MouseEvent(3, 0)));
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestStreamAddAccessAndClear;
var
  St: TChatStream;
begin
  St := TChatStream.Create(FTheme);
  try
    AssertEquals('empty', 0, St.Count);
    AssertTrue('no last block', St.Last = nil);
    St.Add(ckUser, '', 'hi');
    St.Add(ckAssistant, '', 'hello');
    AssertEquals('two blocks', 2, St.Count);
    AssertTrue('first is the user block', St.ItemAt(0).Kind = ckUser);
    AssertEquals('last text', 'hello', St.Last.Text);
    St.Clear;
    AssertEquals('cleared', 0, St.Count);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestStreamRemoveDropsOneBlock;
var
  St: TChatStream;
  Thinking: TChatItem;
begin
  St := TChatStream.Create(FTheme);
  try
    St.Add(ckUser, '', 'hi');
    Thinking := St.Add(ckThinking, '', '');
    St.Add(ckAssistant, '', 'hello');
    AssertEquals('three blocks', 3, St.Count);
    St.Remove(Thinking);
    AssertEquals('two left', 2, St.Count);
    AssertEquals('first kept', 'hi', St.ItemAt(0).Text);
    AssertEquals('last kept', 'hello', St.ItemAt(1).Text);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestStreamKeepsTheNewestBlockVisible;
var
  St: TChatStream;
  S: TSurfaceMemory;
  I: Integer;
  Seen: Boolean;
begin
  S := TSurfaceMemory.Create(30, 4);
  try
    St := TChatStream.Create(FTheme);
    try
      for I := 1 to 12 do
        St.Add(ckAssistant, '', 'line ' + IntToStr(I));
      St.Arrange(Rc(0, 0, 30, 4));
      S.Clear(DefaultAttr);
      St.Render(S);
      S.Flush;
      { The bottom pad leaves the newest block a row or two above the edge. }
      Seen := False;
      for I := 0 to 3 do
        if Pos('line 12', S.RowText(I, 0, 30)) > 0 then
          Seen := True;
      AssertTrue('newest block visible', Seen);
    finally
      St.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStreamReservesTheBottomInset;
var
  St: TChatStream;
  S: TSurfaceMemory;
  I: Integer;
begin
  S := TSurfaceMemory.Create(30, 6);
  try
    St := TChatStream.Create(FTheme);
    try
      St.BottomInset := 3;
      for I := 1 to 20 do
        St.Add(ckAssistant, '', 'line ' + IntToStr(I));
      St.Arrange(Rc(0, 0, 30, 6));
      S.Clear(DefaultAttr);
      St.Render(S);
      S.Flush;
      { Pad of two plus the inset of three: the last line sits five rows above
        the viewport bottom. }
      AssertTrue('last line five rows up',
        Pos('line 20', S.RowText(0, 0, 30)) > 0);
      AssertEquals('row below is blank', '', S.CellAt(0, 1).Ch);
      AssertEquals('and the row below that', '', S.CellAt(0, 2).Ch);
    finally
      St.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStackMaterializesOnlyTheWindow;
var
  Stack: TChatStack;
  S: TSurfaceMemory;
  Sz: TSize;
  I, Small, Large: Integer;
begin
  S := TSurfaceMemory.Create(30, 8);
  try
    Stack := TChatStack.Create(FTheme);
    try
      for I := 1 to 200 do
        Stack.Add(ckAssistant, '', 'line ' + IntToStr(I));
      Stack.Arrange(Rc(0, 0, 30, 8));
      S.Clear(DefaultAttr);
      Stack.Render(S);
      Small := Stack.MaterializedCount;
      AssertTrue('a window is materialized', Small > 0);
      AssertTrue('not every block', Small < 200);
      { The extent is still exact: every block's height is measured even though
        its rendered layout is released. }
      Sz := Default(TSize);
      Sz.W := 30;
      Sz.H := 8;
      AssertTrue('extent is the full column', Stack.Measure(Sz).H > 8);
      { More blocks do not mean more retained layouts. }
      for I := 201 to 600 do
        Stack.Add(ckAssistant, '', 'line ' + IntToStr(I));
      Stack.Arrange(Rc(0, 0, 30, 8));
      S.Clear(DefaultAttr);
      Stack.Render(S);
      Large := Stack.MaterializedCount;
      AssertEquals('retained layouts do not grow with the block count',
        Small, Large);
    finally
      Stack.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStackTracksAnimatingBlocks;
var
  Stack: TChatStack;
  S: TSurfaceMemory;
  Item: TChatItem;
begin
  AnimationClock.Reset;
  S := TSurfaceMemory.Create(30, 8);
  Stack := TChatStack.Create(FTheme);
  try
    AssertEquals('none', 0, Stack.AnimatingCount);
    AssertFalse('not animating', Stack.Animating);
    Stack.Add(ckAssistant, '', 'x');
    AssertEquals('an assistant block does not animate', 0,
      Stack.AnimatingCount);
    Item := Stack.Add(ckThinking, '', '');
    AssertEquals('one', 1, Stack.AnimatingCount);
    AssertTrue('animating', Stack.Animating);
    AssertEquals('registered at the sparkle rate', 90,
      AnimationClock.MinIntervalMs);
    Stack.Remove(Item);
    AssertEquals('none again', 0, Stack.AnimatingCount);
    AssertFalse('not animating', Stack.Animating);
    AssertEquals('cleared', 0, AnimationClock.MinIntervalMs);
    { A live thought/tool box animates too (its corner spinner), and settling
      it drops the registration. }
    Item := Stack.Add(ckTool, 'run_command', 'out');
    AssertEquals('a settled tool does not animate', 0, Stack.AnimatingCount);
    Item.Live := True;
    AssertEquals('a live tool animates', 1, Stack.AnimatingCount);
    AssertTrue('animating', Stack.Animating);
    Item.Live := False;
    AssertEquals('settled again', 0, Stack.AnimatingCount);
    AssertFalse('not animating', Stack.Animating);
  finally
    Stack.Free;
    S.Free;
    AnimationClock.Reset;
  end;
end;

procedure TTuiChatTest.TestStackLayoutDoesNotThrashAcrossMeasureAndArrange;
var
  Stack: TChatStack;
  S: TSurfaceMemory;
  Sz: TSize;
  Before, I, W: Integer;
begin
  S := TSurfaceMemory.Create(30, 8);
  try
    Stack := TChatStack.Create(FTheme);
    try
      for I := 1 to 50 do
        Stack.Add(ckAssistant, '', 'line ' + IntToStr(I));
      Sz := Default(TSize);
      Sz.W := 30;
      Sz.H := 8;
      { The scroll container arranges its child at the width the child reported,
        so measure and then arrange at the measured width. }
      W := Stack.Measure(Sz).W;
      Stack.Arrange(Rc(0, 0, W, 8));
      S.Clear(DefaultAttr);
      Stack.Render(S);
      Before := Stack.LayoutRuns;
      { Repeated measure/arrange cycles with no content change must not rebuild
        the layout: Measure and Arrange must agree on the item width, or the
        height memo misses and every block is re-measured (and re-parsed). }
      for I := 1 to 10 do
      begin
        W := Stack.Measure(Sz).W;
        Stack.Arrange(Rc(0, 0, W, 8));
        S.Clear(DefaultAttr);
        Stack.Render(S);
      end;
      AssertEquals('layout does not thrash', Before, Stack.LayoutRuns);
    finally
      Stack.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestStreamWidthFollowsTheViewport;
var
  St: TChatStream;
  Item: TChatItem;
  Wide, Narrow: Integer;
begin
  { A regression guard: the stream must reflow to the viewport width. The stack
    used to report its own arranged width, which the scroll container fed back as
    the child's width, so the content stayed at its first width forever. }
  St := TChatStream.Create(FTheme);
  try
    Item := St.Add(ckAssistant, '',
      'the quick brown fox jumps over the lazy dog and keeps running so it wraps');
    St.Arrange(Rc(0, 0, 60, 12));
    Wide := Item.Bounds.W;
    St.Arrange(Rc(0, 0, 30, 12));
    Narrow := Item.Bounds.W;
    AssertTrue('the block narrows with the viewport', Narrow < Wide);
    AssertEquals('the block tracks the narrow viewport', 28, Narrow);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestStreamOnChangeFiresWhenABlockGrows;
var
  St: TChatStream;
  Changes: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    Changes := 0;
    St.OnChange := OnToggle;   { reuse the counter }
    St.Add(ckAssistant, '', 'a');
    St.Last.AppendText('b');
    AssertEquals('stream surfaced the change', 1, FToggles);
    AssertEquals('no stray counter', 0, Changes);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestToggleKeepsTheBlockTopInPlace;
var
  St: TChatStream;
  It: TChatItem;
  TopBefore, TopAfter: Integer;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 2 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    { A body long enough to condense (past CondenseThreshold wrapped rows), so
      expanding actually changes the block's height. }
    It := St.Add(ckThought, 'Thought',
      'one' + #10 + 'two' + #10 + 'three' + #10 + 'four' + #10 + 'five' +
      #10 + 'six' + #10 + 'seven' + #10 + 'eight' + #10 + 'nine' + #10 +
      'ten' + #10 + 'eleven' + #10 + 'twelve');
    It.Expanded := False;
    { Following puts the newest block at the bottom of the viewport. }
    St.Arrange(Rc(0, 0, 30, 12));
    TopBefore := It.Bounds.Y;
    AssertTrue('the block is visible', TopBefore >= 0);
    AssertTrue('click expands it',
      It.HandleEvent(MouseEvent(It.Bounds.X + 1, TopBefore)));
    AssertTrue('expanded', It.Expanded);
    St.Arrange(Rc(0, 0, 30, 12));
    TopAfter := It.Bounds.Y;
    AssertEquals('the block top stayed on the same row', TopBefore, TopAfter);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestToggleThroughTheStreamKeepsTheBlockTop;
var
  St: TChatStream;
  It: TChatItem;
  TopBefore, TopAfter: Integer;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 2 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    { A body long enough to condense (past CondenseThreshold wrapped rows), so
      expanding actually changes the block's height. }
    It := St.Add(ckThought, 'Thought',
      'one' + #10 + 'two' + #10 + 'three' + #10 + 'four' + #10 + 'five' +
      #10 + 'six' + #10 + 'seven' + #10 + 'eight' + #10 + 'nine' + #10 +
      'ten' + #10 + 'eleven' + #10 + 'twelve');
    It.Expanded := False;
    St.Arrange(Rc(0, 0, 30, 12));
    TopBefore := It.Bounds.Y;
    { Through the stream, as the app delivers it: the click reaches the block and
      must not be mistaken for a scroll that resumes following. }
    AssertTrue('stream handled the click',
      St.HandleEvent(MouseEvent(It.Bounds.X + 1, TopBefore)));
    AssertTrue('expanded', It.Expanded);
    St.Arrange(Rc(0, 0, 30, 12));
    TopAfter := It.Bounds.Y;
    AssertEquals('the block top stayed on the same row', TopBefore, TopAfter);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestAmbientBlockRenders;
var
  It: TChatItem;
  S: ISurface;
begin
  It := TChatItem.Create(ckAmbient, 'research',
    '◀ research · completed ▶' + #10 + 'the child result', FTheme);
  try
    AssertTrue('kind', It.Kind = ckAmbient);
    { It measures as a body and renders without error. }
    AssertTrue('has height', It.Measure(Avail(40, 0)).H >= 1);
    S := TSurfaceMemory.Create(40, 6);
    It.Arrange(Rc(0, 0, 40, 4));
    It.Render(S);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestAmbientRendersMarkdownInABox;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 8);
  try
    It := TChatItem.Create(ckAmbient, 'checkpoint', '**bold** text', FTheme);
    try
      It.Arrange(Rc(0, 0, 40, 3));
      It.Render(S);
      { A bordered box with the label in the top border, and the markdown body
        inside it (the bold run is styled). }
      AssertEquals('rounded top-left', '╭', S.CellAt(0, 0).Ch);
      AssertTrue('label in the top border',
        Pos('checkpoint', S.RowText(0, 0, 40)) > 0);
      AssertTrue('bold run styled', sfBold in S.CellAt(2, 1).Attr.Style);
      { The document text sits on the box's raised background, not the chat
        panel's default. }
      AssertEquals('markdown on the box background', FTheme.RaisedBg,
        S.CellAt(2, 1).Attr.Bg);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestAmbientCaretRidesTheBottomBorder;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 8);
  try
    It := TChatItem.Create(ckAmbient, 'checkpoint', 'the document body', FTheme);
    try
      { Expanded: an up caret sits in the bottom border, one column left of the
        corner, with a blank cell on either side. }
      It.Expanded := True;
      It.Arrange(Rc(0, 0, 40, 3));
      It.Render(S);
      AssertEquals('up caret', '▲',
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Ch);
      AssertEquals('gap left of the caret', ' ',
        S.CellAt(It.Bounds.X + It.Bounds.W - 5, It.Bounds.H - 1).Ch);
      AssertEquals('gap right of the caret', ' ',
        S.CellAt(It.Bounds.X + It.Bounds.W - 3, It.Bounds.H - 1).Ch);
      AssertEquals('bottom-right corner', '╯',
        S.CellAt(It.Bounds.X + It.Bounds.W - 1, It.Bounds.H - 1).Ch);
      { The caret takes the ambient border's colour (violet, 135), on the box's
        raised background. }
      AssertEquals('caret uses the border colour', 135,
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Attr.Fg);
      AssertEquals('caret on the box background', FTheme.RaisedBg,
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Attr.Bg);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestCollapsedAmbientIsShorter;
var
  It: TChatItem;
  Full, Compact: Integer;
begin
  It := TChatItem.Create(ckAmbient, 'checkpoint',
    '- line one' + #10 + '- line two' + #10 + '- line three' + #10 +
    '- line four' + #10 + '- line five', FTheme);
  try
    It.Expanded := True;
    Full := It.Measure(Avail(40, 0)).H;
    It.Expanded := False;
    Compact := It.Measure(Avail(40, 0)).H;
    AssertTrue('a compact ambient is shorter', Compact < Full);
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestHandoffRendersAsACarriedContextBox;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  { A checkpoint handoff is its own kind, wired like the ambient box: a bordered
    markdown box with the label in the top border and a disclosure caret. A
    distinct handoff presentation forks from the ambient one in the chat item. }
  S := TSurfaceMemory.Create(40, 8);
  try
    It := TChatItem.Create(ckHandoff, 'checkpoint', '**bold** handoff', FTheme);
    try
      AssertTrue('kind', It.Kind = ckHandoff);
      It.Expanded := True;
      It.Arrange(Rc(0, 0, 40, 3));
      It.Render(S);
      AssertEquals('rounded top-left', '╭', S.CellAt(0, 0).Ch);
      AssertTrue('label in the top border',
        Pos('checkpoint', S.RowText(0, 0, 40)) > 0);
      AssertTrue('bold run styled', sfBold in S.CellAt(2, 1).Attr.Style);
      AssertEquals('markdown on the box background', FTheme.RaisedBg,
        S.CellAt(2, 1).Attr.Bg);
      { The caret rides the bottom border, as for an ambient box. }
      AssertEquals('up caret', '▲',
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Ch);
    finally
      It.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatTest.TestCollapsedToolCaretRidesTheBottomBorder;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  { A long tool body collapses, so the caret rides the bottom border: down
    while collapsed, up when expanded. }
  It := TChatItem.Create(ckTool, 'search', '', FTheme);
  try
    It.SetText('alpha bravo charlie delta echo foxtrot golf hotel india juliet ' +
      'kilo lima mike november oscar papa quebec romeo sierra tango uniform ' +
      'victor whiskey xray yankee zulu alpha bravo charlie delta echo foxtrot ' +
      'golf hotel india juliet kilo lima mike november oscar papa quebec romeo ' +
      'sierra tango uniform victor whiskey xray yankee zulu');
    It.Expanded := False;
    It.Arrange(Rc(0, 0, 30, 8));
    S := TSurfaceMemory.Create(30, 8);
    try
      It.Render(S);
      AssertEquals('down caret while collapsed', '▼',
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Ch);
      AssertEquals('gap right of the caret', ' ',
        S.CellAt(It.Bounds.X + It.Bounds.W - 3, It.Bounds.H - 1).Ch);
    finally
      S.Free;
    end;
    It.Expanded := True;
    It.Arrange(Rc(0, 0, 30, 20));
    S := TSurfaceMemory.Create(30, 20);
    try
      It.Render(S);
      AssertEquals('up caret when expanded', '▲',
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Ch);
      { The caret takes the tool border colour, on the sunken box background. }
      AssertEquals('caret uses the tool border colour', 23,
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Attr.Fg);
      AssertEquals('caret on the sunken background', FTheme.SunkenBg,
        S.CellAt(It.Bounds.X + It.Bounds.W - 4, It.Bounds.H - 1).Attr.Bg);
    finally
      S.Free;
    end;
  finally
    It.Free;
  end;
end;

procedure TTuiChatTest.TestANewBlockDoesNotYankAScrolledUpReader;
var
  St: TChatStream;
  E: TInputEvent;
  I, Up: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    AssertTrue('following at the bottom', St.Following);
    { Scroll up: no longer following. }
    E := Default(TInputEvent);
    E.Kind := ikKey;
    E.Key.Kind := kkUp;
    for I := 1 to 5 do
      St.HandleEvent(E);
    AssertFalse('no longer following', St.Following);
    Up := St.ScrollOffset;
    AssertTrue('scrolled up', Up > 0);
    { A new block arrives: a reader who scrolled up must not be yanked down. }
    St.Add(ckAssistant, '', 'line 21');
    St.Arrange(Rc(0, 0, 30, 6));
    AssertEquals('scroll position held', Up, St.ScrollOffset);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestAReaderAtTheBottomKeepsFollowing;
var
  St: TChatStream;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    { Following: new content stays pinned to the bottom (offset = max scroll). }
    St.Add(ckAssistant, '', 'line 21');
    St.Arrange(Rc(0, 0, 30, 6));
    AssertTrue('still following', St.Following);
    AssertEquals('pinned to the bottom', St.ContentHeight - 6, St.ScrollOffset);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestPreserveAnchorKeepsTheVisibleContent;
var
  St: TChatStream;
  E: TInputEvent;
  I, Before, After, Mid: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    { Scroll up to a middle position. }
    E := Default(TInputEvent);
    E.Kind := ikKey;
    E.Key.Kind := kkUp;
    for I := 1 to 4 do
      St.HandleEvent(E);
    Mid := St.ScrollOffset;
    Before := St.ContentHeight;
    { A prepend: hold the anchor, rebuild with older content above, re-arrange. }
    St.PreserveAnchor;
    St.Clear;
    for I := 1 to 5 do
      St.Add(ckAssistant, '', 'older ' + IntToStr(I));
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    After := St.ContentHeight;
    AssertTrue('the content grew', After > Before);
    { The offset shifted by exactly the growth above the anchor, so the visible
      content stays put. }
    AssertEquals('anchor held across the prepend', Mid + (After - Before),
      St.ScrollOffset);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestScrollToStopsFollowingAndMoves;
var
  St: TChatStream;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    AssertTrue('following at the bottom', St.Following);
    { An explicit jump is a navigation: stop following. }
    St.ScrollTo(0);
    AssertFalse('no longer following', St.Following);
    AssertEquals('scrolled to the top', 0, St.ScrollOffset);
    { New content must not yank it back. }
    St.Add(ckAssistant, '', 'line 21');
    St.Arrange(Rc(0, 0, 30, 6));
    AssertEquals('held at the top', 0, St.ScrollOffset);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestScrollNotifiesTheHost;
var
  St: TChatStream;
  E: TInputEvent;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    St.OnScroll := NoteScrolled;
    for I := 1 to 20 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    AssertEquals('no scroll yet', 0, FScrolled);
    E := Default(TInputEvent);
    E.Kind := ikKey;
    E.Key.Kind := kkUp;
    St.HandleEvent(E);
    AssertEquals('scrolling notified the host', 1, FScrolled);
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestOffsetOfReportsTheBlockTop;
var
  St: TChatStream;
  A, B: TChatItem;
begin
  St := TChatStream.Create(FTheme);
  try
    A := St.Add(ckAssistant, '', 'line one');
    B := St.Add(ckAssistant, '', 'line two');
    St.Arrange(Rc(0, 0, 30, 10));
    AssertEquals('first block at the top', 0, St.OffsetOf(A));
    { The second block sits below the first plus the one-row gap. }
    AssertEquals('second block one row + gap down', 2, St.OffsetOf(B));
  finally
    St.Free;
  end;
end;

procedure TTuiChatTest.TestStreamFiresNeedOlderAtTheTop;
var
  St: TChatStream;
  E: TInputEvent;
  I: Integer;
begin
  St := TChatStream.Create(FTheme);
  try
    St.OnNeedOlder := NoteNeedOlder;
    for I := 1 to 40 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    St.Arrange(Rc(0, 0, 30, 6));
    { At the top, a scroll-up asks the host for older history. }
    St.ScrollOffset := 0;
    E := Default(TInputEvent);
    E.Kind := ikKey;
    E.Key.Kind := kkUp;
    St.HandleEvent(E);
    AssertEquals('fired at the top', 1, FNeedOlder);
    { A scroll-down is not a request for older history. }
    E.Key.Kind := kkDown;
    St.HandleEvent(E);
    AssertEquals('not on a scroll-down', 1, FNeedOlder);
  finally
    St.Free;
  end;
end;

initialization
  RegisterTest(TTuiChatTest);
end.
