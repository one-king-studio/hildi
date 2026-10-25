unit test_dashboard_panel;
{ fpcunit tests for the Board Dashboard panel: the quit key and the poll clock.

  The quit test exists because of a real bug: the panel set its own
  QuitRequested, but the host binary checked a DIFFERENT flag that nothing ever
  assigned, so `q` never exited. Nothing caught it, because the panel was
  correct in isolation and the host was broken in isolation - only the seam was
  wrong. This pins the seam from the panel's side: a quit key MUST raise the
  flag the host is expected to read. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  tui.base, tui.input, tui.theme,
  hildegard.helper.dashboard.panel;

type
  TDashboardPanelTest = class(TTestCase)
  private
    FPanel: TDashboard;
    function CharEvent(const ACh: UnicodeString): TInputEvent;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestQRequestsQuit;
    procedure TestCtrlCRequestsQuit;
    procedure TestEscapeRequestsQuit;
    { The poll runs at most once per interval: a busy frame loop must not turn
      into a busy store loop. }
    procedure TestPollIsThrottledToItsInterval;
    { A poll reporting no change must not force a repaint. }
    procedure TestPollWithNoChangeDoesNotRepaint;
  end;

implementation

var
  { What the stub refresh does on each call. }
  PollCalls: Integer;
  PollResult: Boolean;

function StubRefresh: Boolean;
begin
  Inc(PollCalls);
  Result := PollResult;
end;

function TDashboardPanelTest.CharEvent(const ACh: UnicodeString): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := ACh;
  Result.Key.Mods := [];
end;

procedure TDashboardPanelTest.SetUp;
begin
  QuitRequested := False;
  PollCalls := 0;
  PollResult := False;
  FPanel := TDashboard.Create(DarkTheme);
end;

procedure TDashboardPanelTest.TearDown;
begin
  FPanel.Free;
  QuitRequested := False;
end;

procedure TDashboardPanelTest.TestQRequestsQuit;
begin
  AssertFalse('not quitting before the key', QuitRequested);
  FPanel.HandleEvent(CharEvent('q'));
  AssertTrue('q raises the flag the host reads', QuitRequested);
end;

procedure TDashboardPanelTest.TestCtrlCRequestsQuit;
var
  E: TInputEvent;
begin
  E := CharEvent('c');
  E.Key.Mods := [moCtrl];
  FPanel.HandleEvent(E);
  AssertTrue('ctrl-c raises the flag', QuitRequested);
end;

procedure TDashboardPanelTest.TestEscapeRequestsQuit;
var
  E: TInputEvent;
begin
  E := Default(TInputEvent);
  E.Kind := ikKey;
  E.Key.Kind := kkEscape;
  FPanel.HandleEvent(E);
  AssertTrue('escape raises the flag', QuitRequested);
end;

procedure TDashboardPanelTest.TestPollIsThrottledToItsInterval;
begin
  FPanel.SetPoll(1000, @StubRefresh);

  { The first tick polls immediately, so the opening frame is current. }
  FPanel.Advance(0);
  AssertEquals('polls on the first tick', 1, PollCalls);

  { Many ticks inside the interval must not poll again. }
  FPanel.Advance(100);
  FPanel.Advance(200);
  FPanel.Advance(500);
  FPanel.Advance(999);
  AssertEquals('no poll inside the interval', 1, PollCalls);

  { Crossing it polls exactly once more. }
  FPanel.Advance(1000);
  AssertEquals('polls when the interval elapses', 2, PollCalls);
end;

procedure TDashboardPanelTest.TestPollWithNoChangeDoesNotRepaint;
var
  Changed: Boolean;
begin
  FPanel.SetPoll(10, @StubRefresh);
  PollResult := False;

  FPanel.Advance(0);           { poll 1 - consumed here }
  { Advance reports whether a REPAINT is owed. With the spinner index unchanged
    and the poll reporting no change, none is. The spinner advances every
    120ms, so use a tick inside that window. }
  Changed := FPanel.Advance(5);
  AssertFalse('no change and no spinner step means no repaint', Changed);
end;

initialization
  RegisterTest(TDashboardPanelTest);
end.
