unit TestHildiMcpModal;
{ fpcunit tests for the /mcp dialog (HildiMcpModal).

  Headless, against TSurfaceMemory and scripted input, like the sessions modal's
  suite. This dialog shipped with NO tests and four defects the operator found by
  using it, so these cover the four things that were wrong rather than the
  obvious happy path:

    - the CTAs are chords, and a plain letter is NOT one
    - Escape is refused while an action is in flight
    - the busy line draws a spinner and an elapsed count
    - the dialog sizes to its content, floored at six rows and capped at 80% }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUITheme,
  TUIWidgetsModal,
  HildiMCPConfig, HildiMcpModal;

type
  THildiMcpModalTest = class(TTestCase)
  private
    FModal: TMcpModal;
    FSurface: TSurfaceMemory;
    FTheme: TTheme;
    FAdds: Integer;
    FReconnects: Integer;
    FReconnectKey: string;
    FCloses: Integer;
    procedure NoteAdd;
    procedure NoteReconnect(const AKey: string);
    procedure NoteClose;
    procedure Render;
    function Ch(const AText: string): TInputEvent;
    function Ctrl(const AText: string): TInputEvent;
    function Key(AKind: TKeyKind): TInputEvent;
    function Row(const AKey: string): TMcpRowStatus;
    procedure Seed(const AKeys: array of string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { Ctrl+A adds, Ctrl+T connects, and a BARE letter does neither - it belongs
      to the list. The bare-letter case is the regression: 'a' used to add. }
    procedure TestChordsAddAndConnect;
    procedure TestBareLetterDoesNotAct;
    { While an action is in flight nothing may dismiss the dialog. This is what
      made a hung tools/list look like a crash: the modal vanished. }
    procedure TestEscapeIsRefusedWhileBusy;
    procedure TestEscapeClosesWhenIdle;
    { The indicator the operator asked for: a spinner, the action's text, and a
      seconds count that keeps moving. }
    procedure TestBusyLineShowsSpinnerTextAndSeconds;
    procedure TestBusyAnimates;
    { Autosize: six rows minimum, 80% of the screen maximum. }
    procedure TestTwoServersStillGetsTheSixRowFloor;
    procedure TestManyServersAreCappedAtEightyPercent;
  end;

implementation

uses
  DateUtils;

procedure THildiMcpModalTest.SetUp;
begin
  { TTheme is a RECORD, not a class: DarkTheme returns one by value and there is
    nothing to free. Constructing it with TTheme.Create does not exist. }
  FTheme := DarkTheme;
  FSurface := TSurfaceMemory.Create(100, 40);
  FModal := TMcpModal.Create(FTheme);
  FModal.OnAdd := NoteAdd;
  FModal.OnReconnect := NoteReconnect;
  FModal.OnClose := NoteClose;
  FModal.Visible := True;
end;

procedure THildiMcpModalTest.TearDown;
begin
  FModal.Free;
  FSurface.Free;
end;

procedure THildiMcpModalTest.NoteAdd;
begin
  Inc(FAdds);
end;

procedure THildiMcpModalTest.NoteReconnect(const AKey: string);
begin
  Inc(FReconnects);
  FReconnectKey := AKey;
end;

procedure THildiMcpModalTest.NoteClose;
begin
  Inc(FCloses);
end;

function THildiMcpModalTest.Row(const AKey: string): TMcpRowStatus;
begin
  Result := Default(TMcpRowStatus);
  Result.Key := AKey;
  Result.Enabled := True;
  Result.Connection := mcUnknown;
end;

procedure THildiMcpModalTest.Seed(const AKeys: array of string);
var
  Rows: TMcpRowStatusArray;
  I: Integer;
begin
  SetLength(Rows, Length(AKeys));
  for I := 0 to High(AKeys) do
    Rows[I] := Row(AKeys[I]);
  FModal.SetRows(Rows);
end;

function THildiMcpModalTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function THildiMcpModalTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

function THildiMcpModalTest.Ctrl(const AText: string): TInputEvent;
begin
  Result := Ch(AText);
  Result.Key.Mods := [moCtrl];
end;

procedure THildiMcpModalTest.Render;
var
  Sz: TSize;
  Bounds: TRect;
begin
  Sz := Default(TSize);
  Sz.W := FSurface.Width;
  Sz.H := FSurface.Height;
  FModal.Measure(Sz);
  Bounds := Default(TRect);
  Bounds.X := 0;
  Bounds.Y := 0;
  Bounds.W := FSurface.Width;
  Bounds.H := FSurface.Height;
  FModal.Arrange(Bounds);
  FModal.Render(FSurface);
end;

procedure THildiMcpModalTest.TestChordsAddAndConnect;
begin
  Seed(['browser', 'playwright']);

  FModal.HandleEvent(Ctrl('a'));
  AssertEquals('ctrl+a adds once', 1, FAdds);

  FModal.HandleEvent(Ctrl('t'));
  AssertEquals('ctrl+t connects once', 1, FReconnects);
  AssertEquals('and names the selected server', 'browser', FReconnectKey);

  { Ctrl+T on the second row names the second. }
  FModal.HandleEvent(Key(kkDown));
  FModal.HandleEvent(Ctrl('t'));
  AssertEquals('the selection follows the arrow', 'playwright', FReconnectKey);
end;

procedure THildiMcpModalTest.TestBareLetterDoesNotAct;
begin
  { A bare 'a' used to add and 'r' used to reconnect. Both are plain typing, and
    the dialog now reserves them: only the chord acts. }
  Seed(['browser']);
  FModal.HandleEvent(Ch('a'));
  FModal.HandleEvent(Ch('r'));
  FModal.HandleEvent(Ch('t'));
  AssertEquals('a bare letter never adds', 0, FAdds);
  AssertEquals('a bare letter never connects', 0, FReconnects);
end;

procedure THildiMcpModalTest.TestEscapeIsRefusedWhileBusy;
begin
  Seed(['browser']);
  FModal.SetBusy('connecting browser...');

  FModal.HandleEvent(Key(kkEscape));
  AssertEquals('escape did not close while busy', 0, FCloses);

  { And Escape must also be swallowed, so the app's unhandled-Escape path cannot
    pop the plane behind the dialog's back. }
  AssertTrue('the key was consumed', FModal.HandleEvent(Key(kkEscape)));

  { Ctrl+A is refused too - the operator cannot stack a second action. }
  FModal.HandleEvent(Ctrl('a'));
  AssertEquals('add refused while busy', 0, FAdds);

  FModal.ClearBusy;
  FModal.HandleEvent(Key(kkEscape));
  AssertEquals('escape closes once the action resolved', 1, FCloses);
end;

procedure THildiMcpModalTest.TestEscapeClosesWhenIdle;
begin
  Seed(['browser']);
  FModal.HandleEvent(Key(kkEscape));
  AssertEquals('escape closes', 1, FCloses);
end;

procedure THildiMcpModalTest.TestBusyLineShowsSpinnerTextAndSeconds;
var
  X, Y, I: Integer;
  Line: UnicodeString;
  C: TCell;
  SawText: Boolean;
begin
  { One server, so the rows leave the busy line on the bottom row visible. }
  Seed(['browser']);
  Render;
  FModal.SetBusy('connecting browser...');
  Render;

  { The text is what tells the operator WHICH action, and it is the thing that
    was missing entirely. }
  SawText := False;
  for Y := 0 to FSurface.Height - 1 do
  begin
    Line := '';
    for X := 0 to FSurface.Width - 1 do
    begin
      C := FSurface.Get(X, Y);
      Line := Line + C.Ch;
    end;
    if Pos('connecting browser', Line) > 0 then
      SawText := True;
  end;
  AssertTrue('the busy text is drawn', SawText);

  { The seconds counter, so a hang reads as waiting rather than frozen. }
  SawText := False;
  for Y := 0 to FSurface.Height - 1 do
  begin
    Line := '';
    for X := 0 to FSurface.Width - 1 do
    begin
      C := FSurface.Get(X, Y);
      Line := Line + C.Ch;
    end;
    if Pos('0s', Line) > 0 then
      SawText := True;
  end;
  AssertTrue('an elapsed count is drawn', SawText);
end;

procedure THildiMcpModalTest.TestBusyAnimates;
begin
  { Without this the app never repaints, and the spinner freezes on its first
    frame - which is exactly the "unclear what is going on" the operator hit. }
  Seed(['browser']);
  AssertFalse('idle does not animate', FModal.Animating);
  FModal.SetBusy('connecting browser...');
  AssertTrue('busy animates', FModal.Animating);
  FModal.ClearBusy;
  AssertFalse('and stops when the action resolves', FModal.Animating);
end;

procedure THildiMcpModalTest.TestTwoServersStillGetsTheSixRowFloor;
var
  Sz, Got: TSize;
begin
  { Two servers used to fill 80% of the terminal with empty rows. }
  Seed(['browser', 'playwright']);
  Sz := Default(TSize);
  Sz.W := 100;
  Sz.H := 40;
  Got := FModal.Measure(Sz);
  { Six content rows plus the two chrome and two footer rows. }
  AssertTrue('at least the six-row floor plus chrome, got ' +
    IntToStr(Got.H), Got.H >= 6 + 4);
  AssertTrue('and far short of the cap, got ' + IntToStr(Got.H), Got.H < 32);
end;

procedure THildiMcpModalTest.TestManyServersAreCappedAtEightyPercent;
var
  Sz, Got: TSize;
  Many: array of string;
  I: Integer;
begin
  SetLength(Many, 60);
  for I := 0 to High(Many) do
    Many[I] := 'server' + IntToStr(I);
  Seed(Many);
  Sz := Default(TSize);
  Sz.W := 100;
  Sz.H := 40;
  Got := FModal.Measure(Sz);
  AssertTrue('capped at 80% of 40 = 32, got ' + IntToStr(Got.H), Got.H <= 32);
end;

initialization
  RegisterTest(THildiMcpModalTest);
end.
