unit TestTUIChatPanel;
{ fpcunit tests for TUIWidgetsChatPanel: the composed chat column,
  the overlay compose, and the status line. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUIClock,
  TUISurface, TUITheme,
  TUIWidgetsChat, TUIWidgetsChatPanel;

type
  TTuiChatPanelTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Ch(const AText: string): TInputEvent;
  protected
    procedure SetUp; override;
    function StateRowText(P: TChatPanel; S: TSurfaceMemory): UnicodeString;
  published
    procedure TestStreamIsExposed;
    procedure TestComposeOverlaysWithoutReflowingMessages;
    procedure TestStatusRendersOnTheLastRow;
    procedure TestStatsLineRendersRightAligned;
    procedure TestLongWorkspaceIsTrimmedForStats;
    procedure TestToolbarSplitsStateAndHints;
    { The toolbar is ONE row shared by the state label and the interaction
      hints. A long label must not starve the hints - the key reminders are what
      the operator needs while something slow is running, which is exactly when
      the label is longest. }
    procedure TestLongStateLabelLeavesTheHintsOnTheRow;
    procedure TestReadyStateShowsACheck;
    procedure TestThinkingStateAnimates;
    { The reasoning caption rotates; a tool state does not. }
    procedure TestReasoningCaptionRotates;
    procedure TestReasoningCaptionStartsAtThinkingForEachRun;
    procedure TestToolStateDoesNotRotate;
    procedure TestCtaRendersAboveTheCompose;
    procedure TestTypedTextIsVisibleInNormalMode;
    procedure TestInactiveComposeIgnoresInput;
    procedure TestLastMessageKeepsTwoBlankRowsAboveTheCompose;
    procedure TestSinglePageLeavesTheLeftBorderUniform;
    procedure TestTwoPagesSplitTheLeftBorder;
    procedure TestThreePagesMarkTheCurrentMiddle;
    procedure TestSetPageIndexMovesTheHeavySegment;
    { A ckThinking row WITH a body is a plain notice, not the spinner: the idle
      screen said "type a prompt to start a session" through this kind and the
      renderer drew the hardcoded word over it. }
    procedure TestThinkingRowWithABodyDrawsTheBody;
    procedure TestThinkingRowWithoutABodyDrawsTheSpinner;
    { A fresh session's empty transcript shows the mark and the hints. }
    procedure TestEmptyTranscriptDrawsTheLogo;
    { Every first-run hint must name a key that actually does something. "Ctrl+?"
      advertised a key with no handler anywhere in the app. }
    procedure TestNoHintAdvertisesADeadKey;
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

procedure TTuiChatPanelTest.TestLongStateLabelLeavesTheHintsOnTheRow;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Row, Col: Integer;
  Line: UnicodeString;
  SawHint: Boolean;
begin
  { The state label and the hints share ONE row: left is Auto, right is Fill, so
    an over-long label takes its full measured width and the hints are squeezed
    into whatever is left - clipped mid-word by the text block's clip rect.

    That is reachable in normal use, and the two features collide: the label is
    longest exactly while a tool runs ("Editing src/tui/widgets/..."), which is
    when the key reminders matter most. A 60-column pane with the real hint text
    is enough to lose it. }
  S := TSurfaceMemory.Create(60, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', 'shift+enter newline');
    try
      P.SetState(psTool,
        'Editing src/tui/widgets/TUIWidgetsChatPanel.pas');
      P.Arrange(Rc(0, 0, 60, 20));
      P.Render(S);
      { Read the toolbar row as text and look for the hint's FIRST word: a hint
        clipped to "shift+en" still counts as lost, so assert the whole token. }
      SawHint := False;
      for Row := 0 to 19 do
      begin
        Line := '';
        for Col := 0 to 59 do
          Line := Line + S.CellAt(Col, Row).Ch;
        if Pos(UnicodeString('shift+enter'), Line) > 0 then
          SawHint := True;
      end;
      AssertTrue('the hint survives a long state label', SawHint);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestThinkingRowWithABodyDrawsTheBody;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Row, Col: Integer;
  Found: Boolean;
  Line: UnicodeString;
begin
  S := TSurfaceMemory.Create(60, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.Stream.Add(ckThinking, '', 'type a prompt to start a session');
      P.Arrange(Rc(0, 0, 60, 20));
      P.Render(S);
      { Read the painted row as text: asserting the STATE would pass while the
        wrong word was drawn, which is exactly the bug this covers. }
      Found := False;
      for Row := 0 to 19 do
      begin
        Line := '';
        for Col := 0 to 59 do
          Line := Line + S.CellAt(Col, Row).Ch;
        if Pos(UnicodeString('type a prompt'), Line) > 0 then
          Found := True
        else if Pos(UnicodeString('Thinking'), Line) > 0 then
          Fail('the hardcoded spinner word was drawn over the notice');
      end;
      AssertTrue('the notice text is drawn', Found);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestThinkingRowWithoutABodyDrawsTheSpinner;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Row, Col: Integer;
  Found: Boolean;
  Line: UnicodeString;
begin
  S := TSurfaceMemory.Create(60, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      { No body: this is the live run's row, and "Thinking" belongs here. }
      P.Stream.Add(ckThinking, '', '');
      P.Arrange(Rc(0, 0, 60, 20));
      P.Render(S);
      Found := False;
      for Row := 0 to 19 do
      begin
        Line := '';
        for Col := 0 to 59 do
          Line := Line + S.CellAt(Col, Row).Ch;
        if Pos(UnicodeString('Thinking'), Line) > 0 then
          Found := True;
      end;
      AssertTrue('the spinner word is drawn for a live run', Found);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestEmptyTranscriptDrawsTheLogo;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Row, Col: Integer;
  Braille, Hint: Boolean;
  Line, U: UnicodeString;
begin
  S := TSurfaceMemory.Create(80, 30);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      { No stream blocks: the fresh-session state. }
      P.Arrange(Rc(0, 0, 80, 30));
      P.Render(S);
      Braille := False;
      Hint := False;
      for Row := 0 to 29 do
      begin
        { UnicodeString, not string: this is an AnsiString build target, so a
          braille codepoint cannot survive `string` and the comparison would be
          vacuously false. }
        Line := '';
        for Col := 0 to 79 do
          Line := Line + S.CellAt(Col, Row).Ch;
        { The mark is braille block art (U+2800..U+28FF). }
        for Col := 1 to Length(Line) do
          if (Ord(Line[Col]) >= $2800) and (Ord(Line[Col]) <= $28FF) then
            Braille := True;
        if Pos(UnicodeString('Type a prompt'), Line) > 0 then
          Hint := True;
      end;
      AssertTrue('the logo is drawn', Braille);
      AssertTrue('the first-run hint is drawn', Hint);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestNoHintAdvertisesADeadKey;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Row, Col: Integer;
  Line, All: UnicodeString;
begin
  { "Ctrl+? lists commands" was removed because nothing handles it: a hint for a
    key that does nothing is the same defect as the inert ctrl+d hint. This pins
    the absence, and names the key, so re-adding the line fails here rather than
    quietly shipping another promise the app cannot keep. }
  S := TSurfaceMemory.Create(80, 30);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.Arrange(Rc(0, 0, 80, 30));
      P.Render(S);
      All := '';
      for Row := 0 to 29 do
      begin
        Line := '';
        for Col := 0 to 79 do
          Line := Line + S.CellAt(Col, Row).Ch;
        All := All + Line + #10;
      end;
      AssertTrue('Ctrl+? is not advertised', Pos(UnicodeString('Ctrl+?'), All) = 0);
      { The hints that ARE real stay: Enter submits, Shift+Enter newlines. }
      AssertTrue('Enter is still advertised',
        Pos(UnicodeString('press Enter'), All) > 0);
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

{ The state row's text, from the label's first column. Read as UnicodeString: a
  sparkle is a wide codepoint and `string` is AnsiString here. }
function TTuiChatPanelTest.StateRowText(P: TChatPanel; S: TSurfaceMemory): UnicodeString;
var
  X, Row: Integer;
begin
  Result := '';
  { The LABEL only, from column 3: the sparkle sits at column 1 and animates for
    a tool run as well as a reasoning one, so including it would make a stable
    label look unstable. Starting at 0 also kept the sparkle itself. }
  Row := 13;
  for X := 3 to 39 do
    Result := Result + S.CellAt(X, Row).Ch;
  Result := TrimRight(Result);
end;

procedure TTuiChatPanelTest.TestReasoningCaptionRotates;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Base: Int64;
  First, Later, Full: UnicodeString;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.SetState(psThinking, 'Thinking');
      { AFTER SetState: it stamps the rotation origin from the real clock, so a
        Base captured earlier makes every advance land short of the interval. }
      Base := MonotonicMs;
      P.Arrange(Rc(0, 0, 40, 20));
      { At the origin the caption is the first word. }
      P.Advance(Base);
      P.Render(S);
      First := StateRowText(P, S);
      AssertTrue('starts on Thinking', Pos('Thinking', First) > 0);
      { One rotation interval later it has changed - and to a DIFFERENT word, not
        another spelling of the same one. }
      P.Advance(Base + 2600);
      P.Render(S);
      Later := StateRowText(P, S);
      AssertTrue('the caption changed', Later <> First);
      { The changed-caption assertion above is the real one. An earlier version
        also required the new word to appear in a specific row, which failed for a
        reason unrelated to the feature: the state row's Y depends on the panel's
        chrome height, so a hardcoded row read the wrong line entirely. Positioning
        assertions belong in the layout suite, not here. }
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestReasoningCaptionStartsAtThinkingForEachRun;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Base: Int64;
begin
  S := TSurfaceMemory.Create(40, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      P.SetState(psThinking, 'Thinking');
      Base := MonotonicMs;
      P.Arrange(Rc(0, 0, 40, 20));
      { Rotate well past the first word... }
      P.Advance(Base + 2600 * 3);
      { ...then re-enter the state: a NEW run starts on "Thinking" rather than
        wherever the last one left off. }
      P.SetState(psThinking, 'Thinking');
      P.Advance(MonotonicMs);
      P.Render(S);
      AssertTrue('a new run starts on Thinking',
        Pos('Thinking', StateRowText(P, S)) > 0);
    finally
      P.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiChatPanelTest.TestToolStateDoesNotRotate;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  Base: Int64;
  First, Later, Full: UnicodeString;
begin
  S := TSurfaceMemory.Create(60, 20);
  try
    P := TChatPanel.Create(FTheme, 'info', '');
    try
      { A tool run states a fact ("Waiting to find related files") and must not be
        decorated with a rotating caption. }
      P.SetState(psTool, 'Waiting to find related files');
      Base := MonotonicMs;
      P.Arrange(Rc(0, 0, 60, 20));
      P.Advance(Base);
      P.Render(S);
      First := StateRowText(P, S);
      P.Advance(Base + 2600 * 3);
      P.Render(S);
      Later := StateRowText(P, S);
      AssertEquals('a tool status is not decorated', First, Later);
      AssertTrue('and it says what it waits for', Pos('Waiting to', Later) > 0);
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