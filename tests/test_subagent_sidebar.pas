unit test_subagent_sidebar;
{ fpcunit tests for the subagent roster model (hildi.harness.subagent):
  applying status updates, terminal-entry persistence, prune, and find. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.harness.subagent;

type
  TSubagentRosterTest = class(TTestCase)
  published
    procedure TestApplyMapsStatuses;
    procedure TestApplyUpdatesInPlace;
    procedure TestTerminalEntriesPersist;
    procedure TestRosterFind;
    procedure TestPruneDropsOldTerminalOnly;
  end;

implementation

procedure TSubagentRosterTest.TestApplyMapsStatuses;
var
  R: TSubagentRoster;
begin
  R := TSubagentRoster.Create;
  try
    R.Apply('a', 'alpha', 'spawned', 1000);
    R.Apply('b', 'beta', 'running', 1000);
    R.Apply('c', 'gamma', 'completed', 1000);
    R.Apply('d', 'delta', 'aborted', 1000);
    R.Apply('e', 'epsilon', 'gone', 1000);
    AssertEquals('five entries', 5, R.Count);
    AssertEquals('a spawned', Ord(ssSpawned), Ord(R.Entries[0].Status));
    AssertEquals('b running', Ord(ssRunning), Ord(R.Entries[1].Status));
    AssertEquals('c completed', Ord(ssCompleted), Ord(R.Entries[2].Status));
    AssertEquals('d aborted', Ord(ssAborted), Ord(R.Entries[3].Status));
    AssertEquals('e gone', Ord(ssGone), Ord(R.Entries[4].Status));
    AssertEquals('label kept', 'alpha', R.Entries[0].LabelText);
  finally
    R.Free;
  end;
end;

procedure TSubagentRosterTest.TestApplyUpdatesInPlace;
var
  R: TSubagentRoster;
begin
  R := TSubagentRoster.Create;
  try
    R.Apply('a', 'alpha', 'spawned', 1000);
    R.Apply('a', 'alpha', 'running', 2000);
    R.Apply('a', 'alpha', 'completed', 3000);
    AssertEquals('one entry (updated, not duplicated)', 1, R.Count);
    AssertEquals('status updated', Ord(ssCompleted), Ord(R.Entries[0].Status));
    AssertEquals('time updated', 3000, R.Entries[0].UpdatedMs);
  finally
    R.Free;
  end;
end;

procedure TSubagentRosterTest.TestTerminalEntriesPersist;
var
  R: TSubagentRoster;
begin
  { A terminal entry stays visible until pruned, so a result is not lost from
    view. }
  R := TSubagentRoster.Create;
  try
    R.Apply('a', 'alpha', 'completed', 1000);
    AssertEquals('still present', 1, R.Count);
    AssertEquals('findable', 0, R.Find('a'));
  finally
    R.Free;
  end;
end;

procedure TSubagentRosterTest.TestRosterFind;
var
  R: TSubagentRoster;
begin
  R := TSubagentRoster.Create;
  try
    R.Apply('a', 'alpha', 'running', 1000);
    R.Apply('b', 'beta', 'running', 1000);
    AssertEquals('found a', 0, R.Find('a'));
    AssertEquals('found b', 1, R.Find('b'));
    AssertEquals('absent', -1, R.Find('zzz'));
  finally
    R.Free;
  end;
end;

procedure TSubagentRosterTest.TestPruneDropsOldTerminalOnly;
var
  R: TSubagentRoster;
begin
  R := TSubagentRoster.Create;
  try
    R.Apply('done-old', 'old', 'completed', 1000);   // terminal, old
    R.Apply('done-new', 'new', 'completed', 9000);   // terminal, recent
    R.Apply('live', 'live', 'running', 1000);        // non-terminal, old
    { Prune with now=10000, grace=2000: drop terminals older than 8000. }
    R.Prune(10000, 2000);
    AssertEquals('old terminal dropped', -1, R.Find('done-old'));
    AssertTrue('recent terminal kept', R.Find('done-new') >= 0);
    AssertTrue('live entry never pruned', R.Find('live') >= 0);
    AssertEquals('two remain', 2, R.Count);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TSubagentRosterTest);
end.
