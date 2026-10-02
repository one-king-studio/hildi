unit test_tui_chatpanel;
{ fpcunit tests for hildegard.helper.tui.chatpanel: the composed chat column,
  the overlay compose, and the status line. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.theme,
  hildegard.helper.tui.chat, hildegard.helper.tui.chatpanel;

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
    procedure TestCtaRendersAboveTheCompose;
    procedure TestInactiveComposeIgnoresInput;
    procedure TestLastMessageKeepsTwoBlankRowsAboveTheCompose;
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

initialization
  RegisterTest(TTuiChatPanelTest);
end.
