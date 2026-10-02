unit test_harness_stats;
{ fpcunit tests for hildegard.helper.harness.stats: the one-line turn summary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.session, hildegard.helper.harness.stats;

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
  Result.DurationMs := ADurationMs;
  Result.RequestCount := ARequests;
end;

procedure THarnessStatsTest.TestFormatTurnStatsFull;
begin
  AssertEquals('full summary',
    '1.2k in · 310 out · 120 think · 92% cached · 3.4s · 2 req',
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
  AssertTrue('1.0k', Pos('1.0k out', S) > 0);
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

initialization
  RegisterTest(THarnessStatsTest);
end.
