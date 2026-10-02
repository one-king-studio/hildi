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

implementation

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

function FormatDuration(AMs: Int64): string;
begin
  if AMs < 1000 then
    Result := IntToStr(AMs) + 'ms'
  else if AMs < 60000 then
    Result := OneDecimal(AMs, 1000) + 's'
  else
    Result := IntToStr(AMs div 60000) + 'm' +
      Format('%.2d', [(AMs mod 60000) div 1000]) + 's';
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
  Result := Result + ' · ' + FormatDuration(ATurn.DurationMs) + ' · ' +
    IntToStr(ATurn.RequestCount) + ' req';
end;

end.
