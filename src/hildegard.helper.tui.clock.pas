unit hildegard.helper.tui.clock;
{ The TUI frame clock: one monotonic millisecond source for the whole app.

  Widgets never read the clock themselves; TTuiApp reads it and passes the time
  to TWidget.Advance. GetTickCount64 is monotonic on this platform (it is backed
  by clock_gettime(CLOCK_MONOTONIC) on Unix), so animations never see a wall-
  clock jump. }

{$mode delphi}{$H+}

interface

const
  { Default frame cadence: 100 Hz. A ceiling while something animates, not a
    forced refresh - the app blocks on input when nothing is animating. }
  DefaultTickMs = 10;

{ Monotonic milliseconds since an unspecified epoch. Never wall-clock. }
function MonotonicMs: Int64;

implementation

uses
  SysUtils;

function MonotonicMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

end.
