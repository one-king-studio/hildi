unit hildegard.helper.harness.stats;
{ Renders a turn's collected metrics as one compact line for the status bar.

  Pure: it reads no clock and no store, and the status bar is set from the same
  persisted turn record whether the turn just streamed or was resumed, so the
  live and resumed views are identical by construction. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.session;

{ A turn's metrics as `1.2k in · 310 out · 120 think · 92% cached · 3.4s ·
  2 req`; reasoning and cache fields are omitted when they do not apply, and a
  zero turn (no turns yet) formats as the empty string. }
function FormatTurnStats(const ATurn: TTurnRecord): string;

{ A duration as `250ms`, `3.4s`, `2m05s`, or `1h30m`; integer arithmetic so the
  decimal point is always '.'. }
function FormatDurationMs(AMs: Int64): string;

{ A thought block's title: `Thought` when the duration is unknown, else
  `Thought for <duration>`. }
function FormatThoughtLabel(ADurationMs: Int64): string;

{ The final context, a ten-cell shades bar, and its percentage of the limit:
  `121k [▓░░░░░░░░░] 12%`. With no limit (<= 0), just `121k`. }
function FormatContextUsage(ATokens, ALimit: Integer): string;

{ The session's consumption for the status bar: `<in> in · <out> out ·
  <cached>% cached · <time> · <req> req`; the empty string for a session with no
  requests. `in`/`out` are the billed sums over every request. }
function FormatSessionStats(const ATurn: TTurnRecord): string;

implementation

const
  { The context bar: ten shade cells with a consistent background. A full cell
    is a tenth (10%); the partial cell reads half when the remainder is at least
    5%, else it stays background. Stored as UTF-8 bytes, like `·`. }
  ContextBarCells = 10;
  ShadeEmpty = '░';
  ShadeHalf = '▒';
  ShadeFull = '▓';

function Rep(const AText: string; ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + AText;
end;

{ A ten-cell shades bar for APercent (clamped to 0..100): `▓` per full tenth,
  `▒` for a remainder of 5% or more, `░` for the background. }
function ContextBar(APercent: Integer): string;
var
  Full, Rem: Integer;
begin
  if APercent < 0 then
    APercent := 0
  else if APercent > 100 then
    APercent := 100;
  Full := APercent div 10;
  Rem := APercent mod 10;
  Result := '[' + Rep(ShadeFull, Full);
  if Full < ContextBarCells then
  begin
    if Rem >= 5 then
      Result := Result + ShadeHalf
    else
      Result := Result + ShadeEmpty;
    Result := Result + Rep(ShadeEmpty, ContextBarCells - Full - 1);
  end;
  Result := Result + ']';
end;

{ Integer arithmetic only, so the decimal point is always '.' regardless of the
  process locale. }
function OneDecimal(AValue, ADiv: Int64): string;
begin
  Result := IntToStr(AValue div ADiv) + '.' +
    IntToStr((AValue mod ADiv) * 10 div ADiv);
end;

function FormatTokens(AN: Integer): string;
begin
  if AN < 1000 then
    Result := IntToStr(AN)
  else if AN < 1000000 then
    Result := OneDecimal(AN, 1000) + 'k'
  else
    Result := OneDecimal(AN, 1000000) + 'M';
end;

function FormatDurationMs(AMs: Int64): string;
begin
  if AMs < 1000 then
    Result := IntToStr(AMs) + 'ms'
  else if AMs < 60000 then
    Result := OneDecimal(AMs, 1000) + 's'
  else if AMs < 3600000 then
    Result := IntToStr(AMs div 60000) + 'm' +
      Format('%.2d', [(AMs mod 60000) div 1000]) + 's'
  else
    Result := IntToStr(AMs div 3600000) + 'h' +
      Format('%.2d', [(AMs mod 3600000) div 60000]) + 'm';
end;

function FormatThoughtLabel(ADurationMs: Int64): string;
begin
  if ADurationMs <= 0 then
    Result := 'Thought'
  else
    Result := 'Thought for ' + FormatDurationMs(ADurationMs);
end;

function FormatContextUsage(ATokens, ALimit: Integer): string;
var
  Pct: Integer;
begin
  Result := FormatTokens(ATokens);
  if ALimit <= 0 then
    Exit;
  Pct := Round(ATokens * 100 / ALimit);
  Result := Result + ' ' + ContextBar(Pct) + ' ' + IntToStr(Pct) + '%';
end;

function FormatSessionStats(const ATurn: TTurnRecord): string;
begin
  Result := '';
  if ATurn.Id = 0 then
    Exit;
  Result := FormatTokens(ATurn.Usage.PromptTokens) + ' in · ' +
    FormatTokens(ATurn.Usage.CompletionTokens) + ' out';
  if ATurn.Usage.PromptTokens > 0 then
    Result := Result + ' · ' + IntToStr(
      Round(ATurn.Usage.CachedTokens * 100 / ATurn.Usage.PromptTokens)) +
      '% cached';
  Result := Result + ' · ' + FormatDurationMs(ATurn.DurationMs) + ' · ' +
    IntToStr(ATurn.RequestCount) + ' req';
end;

function FormatTurnStats(const ATurn: TTurnRecord): string;
begin
  Result := '';
  if ATurn.Id = 0 then
    Exit;

  Result := FormatTokens(ATurn.Usage.PromptTokens) + ' in · ' +
    FormatTokens(ATurn.Usage.CompletionTokens) + ' out';
  if ATurn.Usage.ReasoningTokens > 0 then
    Result := Result + ' · ' + FormatTokens(ATurn.Usage.ReasoningTokens) +
      ' think';
  if ATurn.Usage.PromptTokens > 0 then
    Result := Result + ' · ' + IntToStr(
      Round(ATurn.Usage.CachedTokens * 100 / ATurn.Usage.PromptTokens)) +
      '% cached';
  Result := Result + ' · ' + FormatDurationMs(ATurn.DurationMs) + ' · ' +
    IntToStr(ATurn.RequestCount) + ' req';
end;

end.
