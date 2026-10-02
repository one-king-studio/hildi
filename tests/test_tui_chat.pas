unit test_tui_chat;
{ fpcunit tests for hildegard.helper.tui.chat: the mutable message blocks and
  the scrolling stream. Rendering is asserted through TSurfaceMemory. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.theme,
  hildegard.helper.tui.chat;

type
  TTuiChatTest = class(TTestCase)
  private
    FTheme: TTheme;
    FToggles: Integer;
    procedure OnToggle(Sender: TObject);
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
    procedure TestCollapsedThoughtDrawsADimmedRule;
    procedure TestCollapsedToolDrawsAThinFullContrastRule;
    procedure TestExpandedThoughtDrawsABox;
    procedure TestThinkingIndicatorRenders;
    procedure TestThinkingAnimates;
    { Interaction. }
    procedure TestClickTogglesAThoughtBlock;
    procedure TestClickOnAssistantIsIgnored;
    { Stream. }
    procedure TestStreamAddAccessAndClear;
    procedure TestStreamRemoveDropsOneBlock;
    procedure TestStreamKeepsTheNewestBlockVisible;
    procedure TestStreamReservesTheBottomInset;
    procedure TestStreamOnChangeFiresWhenABlockGrows;
    procedure TestToggleKeepsTheBlockTopInPlace;
    procedure TestToggleThroughTheStreamKeepsTheBlockTop;
  end;

implementation

procedure TTuiChatTest.SetUp;
begin
  FTheme := DarkTheme;
  FToggles := 0;
end;

procedure TTuiChatTest.OnToggle(Sender: TObject);
begin
  Inc(FToggles);
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

procedure TTuiChatTest.TestCollapsedThoughtDrawsADimmedRule;
var
  It: TChatItem;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(30, 1);
  try
    It := TChatItem.Create(ckThought, 'Thought', 'body', FTheme);
    try
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 30, 1));
      It.Render(S);
      AssertEquals('rule starts at column 1', '─', S.CellAt(1, 0).Ch);
      AssertTrue('label shown', Pos('Thought', S.RowText(0, 0, 30)) > 0);
      AssertTrue('collapse marker shown', Pos('▼', S.RowText(0, 0, 30)) > 0);
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
  S := TSurfaceMemory.Create(30, 1);
  try
    It := TChatItem.Create(ckTool, 'looking for the build file', 'body', FTheme);
    try
      It.Expanded := False;
      It.Arrange(Rc(0, 0, 30, 1));
      It.Render(S);
      AssertEquals('thin rule at column 1', '─', S.CellAt(1, 0).Ch);
      AssertTrue('reason shown as the title',
        Pos('looking for the build file', S.RowText(0, 0, 30)) > 0);
      AssertTrue('full contrast, not dimmed',
        not (sfDim in S.CellAt(1, 0).Attr.Style));
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
      AssertEquals('box top-left', '┌', S.CellAt(0, 0).Ch);
      AssertEquals('box bottom-left', '└', S.CellAt(0, It.Bounds.H - 1).Ch);
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
    for I := 1 to 4 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    It := St.Add(ckThought, 'Thought', 'one' + #10 + 'two' + #10 + 'three');
    It.Expanded := False;
    { Following puts the newest block at the bottom of the viewport. }
    St.Arrange(Rc(0, 0, 30, 6));
    TopBefore := It.Bounds.Y;
    AssertTrue('the block is visible', TopBefore >= 0);
    AssertTrue('click expands it',
      It.HandleEvent(MouseEvent(It.Bounds.X + 1, TopBefore)));
    AssertTrue('expanded', It.Expanded);
    St.Arrange(Rc(0, 0, 30, 6));
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
    for I := 1 to 4 do
      St.Add(ckAssistant, '', 'line ' + IntToStr(I));
    It := St.Add(ckThought, 'Thought', 'one' + #10 + 'two' + #10 + 'three');
    It.Expanded := False;
    St.Arrange(Rc(0, 0, 30, 6));
    TopBefore := It.Bounds.Y;
    { Through the stream, as the app delivers it: the click reaches the block and
      must not be mistaken for a scroll that resumes following. }
    AssertTrue('stream handled the click',
      St.HandleEvent(MouseEvent(It.Bounds.X + 1, TopBefore)));
    AssertTrue('expanded', It.Expanded);
    St.Arrange(Rc(0, 0, 30, 6));
    TopAfter := It.Bounds.Y;
    AssertEquals('the block top stayed on the same row', TopBefore, TopAfter);
  finally
    St.Free;
  end;
end;

initialization
  RegisterTest(TTuiChatTest);
end.
