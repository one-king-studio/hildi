unit test_tui_chatpanel;
{ fpcunit tests for tui.widgets.chatpanel: the composed chat column,
  the overlay compose, and the status line. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  tui.base, tui.input,
  tui.surface, tui.theme,
  tui.widgets.chat, tui.widgets.chatpanel;

type
  TTuiChatPanelTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Ch(const AText: string): TInputEvent;
  protected
    procedure SetUp; override;
  published
    procedure TestStreamIsExposed;
    procedure TestComposeOverlaysWithoutReflowingMessages;
    procedure TestStatusRendersOnTheLastRow;
    procedure TestStatsLineRendersRightAligned;
    procedure TestLongWorkspaceIsTrimmedForStats;
    procedure TestToolbarSplitsStateAndHints;
    procedure TestReadyStateShowsACheck;
    procedure TestThinkingStateAnimates;
    procedure TestCtaRendersAboveTheCompose;
    procedure TestTypedTextIsVisibleInNormalMode;
    procedure TestInactiveComposeIgnoresInput;
    procedure TestLastMessageKeepsTwoBlankRowsAboveTheCompose;
    procedure TestSinglePageLeavesTheLeftBorderUniform;
    procedure TestTwoPagesSplitTheLeftBorder;
    procedure TestThreePagesMarkTheCurrentMiddle;
    procedure TestSetPageIndexMovesTheHeavySegment;
  end;

implementation

procedure TTuiChatPanelTest.SetUp;
begin
  FTheme := DarkTheme;
end;

function TTuiChatPanelTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiChatPanelTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

procedure TTuiChatPanelTest.TestStreamIsExposed;
var
  P: TChatPanel;
begin
  P := TChatPanel.Create(FTheme, 'info', 'cta');
  try
    AssertEquals('no blocks yet', 0, P.Stream.Count);
    P.Stream.Add(ckUser, '', 'hello');
    AssertEquals('block added', 1, P.Stream.Count);
    AssertEquals('text', 'hello', P.Stream.Last.Text);
  finally
    P.Free;
  end;
end;

procedure TTuiChatPanelTest.TestComposeOverlaysWithoutReflowingMessages;
var
  P: TChatPanel;
  BeforeH, AfterH: Integer;
begin
  P := TChatPanel.Create(FTheme, 'info', 'cta');
  try
    P.Arrange(Rc(0, 0, 40, 20));
    BeforeH := P.Stream.Bounds.H;
    { Growing the input must not change the messages viewport. }
    P.Compose.Edit.InsertText(
      'a long line of text that will wrap onto more than one row in the box');
    P.Arrange(Rc(0, 0, 40, 20));
    AfterH := P.Stream.Bounds.H;
    AssertEquals('messages viewport unchanged', BeforeH, AfterH);
  finally
    P.Free;
  end;
end;

procedure TTuiChatPanelTest.TestStatusRendersOnTheLastRow;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      P.SetStatus('ready');
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertTrue('status on the last row',
        Pos('ready', S.RowText(19, 0, 40)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestTypedTextIsVisibleInNormalMode;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Y: Integer;
  Found: Boolean;
begin
  { Regression: the actions bar must not paint over the compose in normal mode —
    a typed prompt has to be on screen. }
  P := TChatPanel.Create(FTheme, 'info', 'cta');
  S := TSurfaceMemory.Create(40, 20);
  try
    P.Arrange(Rc(0, 0, 40, 20));
    P.Compose.Edit.InsertText('hello world');
    P.Render(S);
    Found := False;
    for Y := 0 to 19 do
      if Pos('hello world', S.RowText(Y, 0, 40)) > 0 then
        Found := True;
    AssertTrue('the typed prompt is visible', Found);
  finally
    S.Free;
    P.Free;
  end;
end;

procedure TTuiChatPanelTest.TestCtaRendersAboveTheCompose;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'press enter');
    try
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      { The compose is 5 rows at the bottom of the 19-row message area, so the
        CTA sits directly above it. }
      AssertTrue('cta rendered', Pos('press enter', S.RowText(13, 0, 40)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestStatsLineRendersRightAligned;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      P.SetStatus('/tmp/project');
      P.SetStats('1.2k in');
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertTrue('workspace on the left',
        Pos('/tmp/project', S.RowText(19, 0, 20)) > 0);
      AssertTrue('stats on the right',
        Pos('1.2k in', S.RowText(19, 28, 12)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestInactiveComposeIgnoresInput;
var
  P: TChatPanel;
begin
  P := TChatPanel.Create(FTheme, 'info', 'cta');
  try
    P.Arrange(Rc(0, 0, 40, 20));
    P.SetComposeActive(False);
    P.HandleEvent(Ch('x'));
    AssertEquals('typing ignored while inactive', '', string(P.Compose.Text));
    P.SetComposeActive(True);
    P.HandleEvent(Ch('y'));
    AssertEquals('typing accepted when active', 'y', string(P.Compose.Text));
  finally
    P.Free;
  end;
end;

procedure TTuiChatPanelTest.TestLongWorkspaceIsTrimmedForStats;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      P.SetStatus('/Users/very/long/workspace/path/that/overflows');
      P.SetStats('1.2k in');
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertTrue('stats intact', Pos('1.2k in', S.RowText(19, 28, 12)) > 0);
      AssertTrue('workspace trimmed before the stats',
        Pos('overflows', S.RowText(19, 0, 40)) = 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestLastMessageKeepsTwoBlankRowsAboveTheCompose;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  I, CtaRow: Integer;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'press enter');
    try
      for I := 1 to 20 do
        P.Stream.Add(ckAssistant, '', 'line ' + IntToStr(I));
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      CtaRow := -1;
      for I := 0 to 19 do
        if Pos('press enter', S.RowText(I, 0, 40)) > 0 then
          CtaRow := I;
      AssertTrue('cta row found', CtaRow > 2);
      { Column 0 is the messages panel border; look inside it. }
      AssertEquals('row just above the cta is blank', '',
        S.CellAt(2, CtaRow - 1).Ch);
      AssertEquals('and the row above that', '', S.CellAt(2, CtaRow - 2).Ch);
      AssertTrue('the last message sits above the pad',
        Pos('line 20', S.RowText(CtaRow - 3, 0, 40)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestToolbarSplitsStateAndHints;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(60, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'hints here');
    try
      P.SetState(psReady, 'ready');
      P.Arrange(Rc(0, 0, 60, 20));
      P.Render(S);
      { The toolbar is on the row above the compose; the state is left, the
        hints right. }
      AssertTrue('state on the left',
        Pos('ready', S.RowText(13, 0, 20)) > 0);
      AssertTrue('hints on the right',
        Pos('hints here', S.RowText(13, 48, 12)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestReadyStateShowsACheck;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.SetState(psReady, 'ready');
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertTrue('green check glyph (U+2713)',
        Ord(S.CellAt(2, 13).Ch[1]) = $2713);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestThinkingStateAnimates;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  First: Integer;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.SetState(psThinking, 'thinking');
      AssertTrue('animating while thinking', P.Animating);
      P.Arrange(Rc(0, 0, 40, 20));
      P.Advance(0);
      P.Render(S);
      First := Ord(S.CellAt(2, 13).Ch[1]);
      AssertTrue('a sparkle, not a space', First <> Ord(' '));
      P.Advance(90);
      P.Render(S);
      AssertTrue('the sparkle advanced',
        Ord(S.CellAt(2, 13).Ch[1]) <> First);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestSinglePageLeavesTheLeftBorderUniform;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      P.SetPage(1, 0);
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      { A single page: the left border stays the thin light vertical. }
      AssertEquals('thin left border', #$2502, S.CellAt(0, 5).Ch);
      AssertEquals('thin at the bottom too', #$2502, S.CellAt(0, 17).Ch);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestTwoPagesSplitTheLeftBorder;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      { Two pages, the current one (page 2) heavy: thin top half, heavy bottom. }
      P.SetPage(2, 1);
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertEquals('thin in the first half', #$2502, S.CellAt(0, 5).Ch);
      AssertEquals('heavy in the current half', #$2503, S.CellAt(0, 12).Ch);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestThreePagesMarkTheCurrentMiddle;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      { Three pages, the current one (page 2) the middle third: thin, heavy,
        thin. }
      P.SetPage(3, 1);
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertEquals('thin in the first third', #$2502, S.CellAt(0, 2).Ch);
      AssertEquals('heavy in the middle third', #$2503, S.CellAt(0, 9).Ch);
      AssertEquals('thin in the last third', #$2502, S.CellAt(0, 16).Ch);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestSetPageIndexMovesTheHeavySegment;
var
  P: TChatPanel;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'cta');
    try
      P.SetPage(2, 1);           { current = page 2 (bottom half heavy) }
      P.SetPageIndex(0);         { the view scrolled up into page 1 }
      P.Arrange(Rc(0, 0, 40, 20));
      P.Render(S);
      AssertEquals('first half now heavy', #$2503, S.CellAt(0, 5).Ch);
      AssertEquals('second half thin', #$2502, S.CellAt(0, 12).Ch);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TTuiChatPanelTest);
end.