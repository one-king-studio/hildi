unit hildegard.helper.fuzzy;
{ Case-insensitive fuzzy (subsequence) matching for typeahead filters.

  A needle matches a haystack when every needle character appears in the
  haystack in order, not necessarily adjacent: "drn" matches "drain". Each match
  is scored so a caller can rank results: the score rewards a match at the start
  of a word and runs of consecutive characters, so for "drn" the haystack "drain
  the queue" outranks "a dry run". Pure and dependency-free (no TUI, no store);
  used by the command palette and the /sessions modal filter. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { The result of a fuzzy match. Positions are 1-based indices into the haystack
    (for highlighting the matched characters); empty when nothing matched. }
  TFuzzyMatch = record
    Matched: Boolean;
    Score: Integer;
    Positions: TArray<Integer>;
  end;

{ Match ANeedle against AHaystack, case-insensitively. An empty needle matches
  everything with score 0. Never raises. }
function FuzzyMatch(const ANeedle, AHaystack: string): TFuzzyMatch;

{ Convenience: does ANeedle match AHaystack? }
function FuzzyMatches(const ANeedle, AHaystack: string): Boolean;

{ The indices of the haystacks that match ANeedle, best score first; ties keep
  source order (a stable ranking). Empty needle returns every index in order. }
function FuzzyRank(const ANeedle: string; const AHaystacks: TStringArray):
  TArray<Integer>;

const
  { Scoring weights. A match is worth the base plus bonuses; a skipped character
    after matching has begun subtracts a small penalty, so tighter matches rank
    higher. }
  FuzzyMatchBase = 10;
  FuzzyConsecutiveBonus = 15;
  FuzzyBoundaryBonus = 20;
  FuzzyStartBonus = 10;
  FuzzyGapPenalty = 1;

implementation

{ True when AHaystack[APos] begins a word: the first character, or the one after
  a separator. }
function IsBoundary(const AHaystack: string; APos: Integer): Boolean;
begin
  if APos <= 1 then
    Exit(True);
  Result := AHaystack[APos - 1] in [' ', '-', '_', '/', '.', ':', ',', '('];
end;

function FuzzyMatch(const ANeedle, AHaystack: string): TFuzzyMatch;
var
  Needle, Hay: string;
  I, J, N, H, PrevMatch: Integer;
begin
  Result := Default(TFuzzyMatch);
  Result.Matched := False;
  Result.Score := 0;
  Result.Positions := nil;
  if ANeedle = '' then
  begin
    Result.Matched := True;
    Exit;
  end;
  { Greedy left-to-right: take the first occurrence of each needle character.
    A ponytail: this can pick a lower-scoring alignment than an optimal one, but
    it is linear in practice and the ranking is only a nicety for a filter. }
  Needle := LowerCase(ANeedle);
  Hay := LowerCase(AHaystack);
  N := Length(Needle);
  H := Length(Hay);
  I := 1;
  J := 1;
  PrevMatch := 0;
  while (I <= N) and (J <= H) do
  begin
    if Needle[I] = Hay[J] then
    begin
      SetLength(Result.Positions, Length(Result.Positions) + 1);
      Result.Positions[High(Result.Positions)] := J;
      Inc(Result.Score, FuzzyMatchBase);
      if PrevMatch = J - 1 then
        Inc(Result.Score, FuzzyConsecutiveBonus);
      if IsBoundary(AHaystack, J) then
        Inc(Result.Score, FuzzyBoundaryBonus);
      if J = 1 then
        Inc(Result.Score, FuzzyStartBonus);
      PrevMatch := J;
      Inc(I);
    end
    else if PrevMatch > 0 then
      { A skipped character after the match began: a small penalty. }
      Dec(Result.Score, FuzzyGapPenalty);
    Inc(J);
  end;
  Result.Matched := I > N;
  if not Result.Matched then
  begin
    Result.Score := 0;
    Result.Positions := nil;
  end;
end;

function FuzzyMatches(const ANeedle, AHaystack: string): Boolean;
begin
  Result := FuzzyMatch(ANeedle, AHaystack).Matched;
end;

function FuzzyRank(const ANeedle: string; const AHaystacks: TStringArray):
  TArray<Integer>;
var
  I, J, N: Integer;
  Scores: TArray<Integer>;
begin
  Result := nil;
  N := 0;
  SetLength(Scores, 0);
  for I := 0 to High(AHaystacks) do
  begin
    if ANeedle = '' then
    begin
      SetLength(Result, N + 1);
      Result[N] := I;
      Inc(N);
      Continue;
    end;
    if FuzzyMatch(ANeedle, AHaystacks[I]).Matched then
    begin
      SetLength(Result, N + 1);
      Result[N] := I;
      SetLength(Scores, N + 1);
      Scores[N] := FuzzyMatch(ANeedle, AHaystacks[I]).Score;
      Inc(N);
    end;
  end;
  { Stable insertion sort by score, descending (lists are small). Skipped for an
    empty needle: the order is already source order and Scores is not filled. }
  if ANeedle = '' then
    Exit;
  for I := 1 to N - 1 do
  begin
    J := I;
    while (J > 0) and (Scores[J] > Scores[J - 1]) do
    begin
      { Swap the score and the index. }
      N := Scores[J]; Scores[J] := Scores[J - 1]; Scores[J - 1] := N;
      N := Result[J]; Result[J] := Result[J - 1]; Result[J - 1] := N;
      Dec(J);
    end;
  end;
end;

end.
