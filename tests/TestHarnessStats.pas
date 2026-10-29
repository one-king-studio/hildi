unit TestHarnessStats;
{ fpcunit tests for HildiHarnessStats: the one-line turn summary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiSession, HildiHarnessStats;

type
  THarnessStatsTest = class(TTestCase)
  private
    function Turn(APrompt, ACompletion, AReasoning, ACached: Integer;
      ADurationMs: Int64; ARequests: Integer): TTurnRecord;
  published
    procedure TestFormatTurnStatsFull;
    procedure TestFormatTurnStatsOmitsCacheWhenNoPromptTokens;
    procedure TestFormatTurnStatsAbbreviatesTokens;
    procedure TestFormatTurnStatsDuration;
    procedure TestFormatTurnStatsZeroTurnIsEmpty;
    procedure TestFormatThoughtLabel;
    procedure TestFormatDurationMs;
    procedure TestFormatContextUsage;
    procedure TestFormatContextUsageNoLimit;
    procedure TestFormatSessionStats;
    procedure TestFormatSessionStatsEmpty;
    procedure TestCheckpointNudgeNeeded;
    procedure TestFormatTokensScalesPastMillions;
  end;

implementation

function THarnessStatsTest.Turn(APrompt, ACompletion, AReasoning,
  ACached: Integer; ADurationMs: Int64; ARequests: Integer): TTurnRecord;
begin
  Result := Default(TTurnRecord);
  Result.Id := 1;
  Result.Usage.PromptTokens := APrompt;
  Result.Usage.CompletionTokens := ACompletion;
  Result.Usage.ReasoningTokens := AReasoning;
  Result.Usage.CachedTokens := ACached;
  Result.Usage.TotalTokens := APrompt + ACompletion;
  Result.ContextTokens := APrompt;
  Result.DurationMs := ADurationMs;
  Result.RequestCount := ARequests;
end;

procedure THarnessStatsTest.TestFormatTurnStatsFull;
begin
  AssertEquals('full summary',
    '1k in · 310 out · 120 think · 92% cached · 3.4s · 2 req',
    FormatTurnStats(Turn(1200, 310, 120, 1100, 3400, 2)));
end;

procedure THarnessStatsTest.TestFormatTurnStatsOmitsCacheWhenNoPromptTokens;
begin
  AssertEquals('no cache without prompt tokens',
    '0 in · 0 out · 0ms · 0 req', FormatTurnStats(Turn(0, 0, 0, 0, 0, 0)));
end;

procedure THarnessStatsTest.TestFormatTurnStatsAbbreviatesTokens;
var
  S: string;
begin
  S := FormatTurnStats(Turn(999, 1000, 0, 0, 1000, 1));
  AssertTrue('999 plain', Pos('999 in', S) > 0);
  AssertTrue('1k (round-numbered)', Pos('1k out', S) > 0);
  S := FormatTurnStats(Turn(3400000, 0, 0, 0, 1000, 1));
  AssertTrue('3.4M', Pos('3.4M in', S) > 0);
end;

procedure THarnessStatsTest.TestFormatTurnStatsDuration;
begin
  AssertTrue('ms', Pos(' · 250ms · ',
    FormatTurnStats(Turn(1, 1, 0, 0, 250, 1))) > 0);
  AssertTrue('seconds', Pos(' · 3.4s · ',
    FormatTurnStats(Turn(1, 1, 0, 0, 3400, 1))) > 0);
  AssertTrue('minutes', Pos(' · 2m05s · ',
    FormatTurnStats(Turn(1, 1, 0, 0, 125000, 1))) > 0);
end;

procedure THarnessStatsTest.TestFormatTurnStatsZeroTurnIsEmpty;
begin
  AssertEquals('no turn, no stats', '', FormatTurnStats(Default(TTurnRecord)));
end;

procedure THarnessStatsTest.TestFormatThoughtLabel;
begin
  AssertEquals('no duration', 'Thought', FormatThoughtLabel(0));
  AssertEquals('seconds', 'Thought for 2.3s', FormatThoughtLabel(2300));
  AssertEquals('milliseconds', 'Thought for 250ms', FormatThoughtLabel(250));
end;

procedure THarnessStatsTest.TestFormatContextUsage;
begin
  AssertEquals('half', '500k [▓▓▓▓▓░░░░░] 50%',
    FormatContextUsage(500000, 1000000));
  { 12%: one full tenth, the 2% remainder stays background. }
  AssertEquals('small', '121k [▓░░░░░░░░░] 12%',
    FormatContextUsage(121000, 1000000));
  { 15%: one full tenth plus a half-cell remainder. }
  AssertEquals('remainder', '150k [▓▒░░░░░░░░] 15%',
    FormatContextUsage(150000, 1000000));
end;

procedure THarnessStatsTest.TestFormatContextUsageNoLimit;
begin
  AssertEquals('no limit, no bar', '121k',
    FormatContextUsage(121000, 0));
end;

procedure THarnessStatsTest.TestFormatSessionStats;
begin
  AssertEquals('consumption line',
    '1k in · 310 out · 92% cached · 3.4s · 2 req',
    FormatSessionStats(Turn(1200, 310, 120, 1100, 3400, 2)));
end;

procedure THarnessStatsTest.TestFormatSessionStatsEmpty;
begin
  AssertEquals('no requests, no line', '',
    FormatSessionStats(Default(TTurnRecord)));
end;

procedure THarnessStatsTest.TestFormatDurationMs;
begin
  AssertEquals('ms', '250ms', FormatDurationMs(250));
  AssertEquals('seconds', '3.4s', FormatDurationMs(3400));
  AssertEquals('minutes', '2m05s', FormatDurationMs(125000));
  AssertEquals('hours', '1h30m', FormatDurationMs(5400000));
end;

procedure THarnessStatsTest.TestCheckpointNudgeNeeded;
begin
  AssertFalse('below the threshold', CheckpointNudgeNeeded(79, 100));
  AssertTrue('at the threshold', CheckpointNudgeNeeded(80, 100));
  AssertTrue('above the threshold', CheckpointNudgeNeeded(95, 100));
  AssertFalse('no limit disables it', CheckpointNudgeNeeded(100, 0));
end;

procedure THarnessStatsTest.TestFormatTokensScalesPastMillions;
begin
  { Round-numbered: raw under a thousand, an integer k count, then one decimal
    from M up. A long session's aggregates cross 1e9 (observed at 2.15B total
    tokens), so the scale must not stop at millions. }
  AssertEquals('under a thousand is raw', '999', FormatTokens(999));
  AssertEquals('integer k', '1k', FormatTokens(1000));
  AssertEquals('integer k rounds', '138k', FormatTokens(137800));
  AssertEquals('999,999 rolls up to a million', '1.0M',
    FormatTokens(999999));
  AssertEquals('one decimal from M', '2.7M', FormatTokens(2713000));
  AssertEquals('three-digit M', '980.0M', FormatTokens(980000000));
  AssertEquals('the crashing session', '2.1B', FormatTokens(2149321552));
  AssertEquals('hundreds of billions', '420.0B', FormatTokens(420000000000));
  AssertEquals('one trillion', '1.0T', FormatTokens(1000000000000));
  AssertEquals('past a trillion', '7.5T', FormatTokens(7500000000000));
end;

initialization
  RegisterTest(THarnessStatsTest);
end.
