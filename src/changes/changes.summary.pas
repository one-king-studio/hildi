unit changes.summary;
{ The turn summary: one turn's net changes, shaped for a block the operator reads.

  Two jobs, both pure:

  1. SummarizeTurn folds a turn's rows into a per-file list with counts. This is
     where the three states are kept apart - changed, unchanged, and uncountably
     captured - because confusing them is how a summary lies.

  2. SummaryLines renders that list as the text a collapsed block shows.

  Counting is from the stored PATCH, not from before/after text: the patch is
  what every record has when its sides were captured, and counting from it means
  the summary and the diff the operator clicks can never disagree.

  A net row whose patch is empty means the turn's two ends are identical - the
  file is UNCHANGED, and it is not listed. A row with no patch at all means the
  before-side was never captured - it IS listed, with unknown counts. Those are
  different facts and this unit never conflates them. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, changes.types;

type
  TFileChangeStat = record
    Path: string;
    Kind: TChangeKind;
    Added, Removed: Integer;
    { True when the record carried a patch, so Added/Removed mean something.
      False => the change was not captured; the UI renders '+? -?'. }
    CountsKnown: Boolean;
    { The patch was truncated at the cap, so the counts are a lower bound. }
    Capped: Boolean;
    { False => a watcher wrote it, or an external session did. Never silently
      attributed to this agent. }
    Attributed: Boolean;
  end;

  TFileChangeStatArray = array of TFileChangeStat;

  TTurnChangeSummary = record
    TurnId: Integer;
    Files: TFileChangeStatArray;
    { Totals over the files whose counts are known. Unknown files are counted
      separately, so a total is never quietly incomplete. }
    TotalAdded, TotalRemoved: Integer;
    UnknownCount: Integer;
  end;

{ Fold one turn's rows into a summary. Reads only net rows (IsNet), so a caller
  may pass ForTurn's full output without double-counting the per-call rows.
  A file whose net patch is empty is unchanged and is omitted. Never raises. }
function SummarizeTurn(const ARows: TChangeRecordArray): TTurnChangeSummary;

{ The collapsed block's lines: `M path  +30 -8` per file, ordered by path, at
  most AMaxFiles of them, then a `- N more files  +a -r` tail when any are
  hidden. An empty summary yields no lines, so the caller renders no block. }
function SummaryLines(const ASummary: TTurnChangeSummary;
  AMaxFiles: Integer): TStringArray;

implementation

{ Count the content lines of a unified diff. The `---`/`+++` header pair is not
  content; `@@` hunks are not content; a leading space is context. }
procedure CountPatch(const APatch: string; out AAdded, ARemoved: Integer);
var
  P, LineStart: Integer;
  Line: string;
begin
  AAdded := 0;
  ARemoved := 0;
  LineStart := 1;
  P := 1;
  while LineStart <= Length(APatch) do
  begin
    P := LineStart;
    while (P <= Length(APatch)) and (APatch[P] <> #10) do
      Inc(P);
    Line := Copy(APatch, LineStart, P - LineStart);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if (Line <> '') and (Line[1] = '+') and (Copy(Line, 1, 3) <> '+++') then
      Inc(AAdded)
    else if (Line <> '') and (Line[1] = '-') and (Copy(Line, 1, 3) <> '---') then
      Inc(ARemoved);
    LineStart := P + 1;
  end;
end;

function SummarizeTurn(const ARows: TChangeRecordArray): TTurnChangeSummary;
var
  I: Integer;
  R: TChangeRecord;
  Stat: TFileChangeStat;
begin
  Result := Default(TTurnChangeSummary);
  Result.Files := nil;
  Result.TotalAdded := 0;
  Result.TotalRemoved := 0;
  Result.UnknownCount := 0;
  for I := 0 to High(ARows) do
  begin
    R := ARows[I];
    { Only the folded per-path rows describe the turn. A per-call row describes
      one call, and summing both would count the net and its parts. }
    if not R.IsNet then
      Continue;
    Stat := Default(TFileChangeStat);
    Stat.Path := R.Path;
    Stat.Kind := R.Kind;
    Stat.Capped := R.Capped;
    Stat.Attributed := (R.SessionId <> '') and (R.ExternalSession = '');
    if R.Patch = '' then
    begin
      { No patch on a net row is one of two different facts, and conflating them
        is how a summary lies:

        - the two ends are IDENTICAL (both hashes present and equal): the file
          is unchanged, so it is not part of the summary;
        - a side was never captured (a hash missing): we cannot count it, so it
          IS listed with unknown counts rather than reported as clean. }
      if (R.BeforeHash <> '') and (R.AfterHash <> '') and
        (R.BeforeHash = R.AfterHash) then
        Continue;                 // unchanged
      Stat.CountsKnown := False;  // not captured: listed, uncounted
    end
    else
    begin
      Stat.CountsKnown := True;
      CountPatch(R.Patch, Stat.Added, Stat.Removed);
    end;
    if Stat.CountsKnown then
    begin
      Inc(Result.TotalAdded, Stat.Added);
      Inc(Result.TotalRemoved, Stat.Removed);
    end
    else
      Inc(Result.UnknownCount);
    SetLength(Result.Files, Length(Result.Files) + 1);
    Result.Files[High(Result.Files)] := Stat;
  end;
end;

function StatLine(const AStat: TFileChangeStat): string;
begin
  Result := ChangeKindCode(AStat.Kind) + ' ' + AStat.Path;
  if not AStat.CountsKnown then
    Result := Result + '  +? -?'
  else if AStat.Capped then
    Result := Result + Format('  +%d -%d (at least)', [AStat.Added, AStat.Removed])
  else
    Result := Result + Format('  +%d -%d', [AStat.Added, AStat.Removed]);
end;

function SummaryLines(const ASummary: TTurnChangeSummary;
  AMaxFiles: Integer): TStringArray;
var
  I, J, Shown, Hidden, HiddenAdd, HiddenRem: Integer;
  Sorted: TFileChangeStatArray;

  procedure Swap(A, B: Integer);
  var
    T: TFileChangeStat;
  begin
    T := Sorted[A];
    Sorted[A] := Sorted[B];
    Sorted[B] := T;
  end;

begin
  Result := nil;
  if Length(ASummary.Files) = 0 then
    Exit;
  { Ordered by path: the file the operator is looking for should be where they
    expect it, not in write order. }
  Sorted := Copy(ASummary.Files, 0, Length(ASummary.Files));
  { Insertion sort with an explicit index: FPC forbids assigning to a for-loop
    variable, and the inner walk moves backwards. Path counts per turn are small,
    so O(n^2) is not worth a smarter sort here. }
  for I := 1 to High(Sorted) do
  begin
    J := I;
    while (J > 0) and (Sorted[J].Path < Sorted[J - 1].Path) do
    begin
      Swap(J, J - 1);
      Dec(J);
    end;
  end;

  if AMaxFiles <= 0 then
    AMaxFiles := Length(Sorted);
  Shown := Length(Sorted);
  if Shown > AMaxFiles then
    Shown := AMaxFiles;

  SetLength(Result, Shown);
  for I := 0 to Shown - 1 do
    Result[I] := StatLine(Sorted[I]);

  Hidden := Length(Sorted) - Shown;
  if Hidden > 0 then
  begin
    HiddenAdd := 0;
    HiddenRem := 0;
    for I := Shown to High(Sorted) do
      if Sorted[I].CountsKnown then
      begin
        Inc(HiddenAdd, Sorted[I].Added);
        Inc(HiddenRem, Sorted[I].Removed);
      end;
    SetLength(Result, Shown + 1);
    Result[Shown] := Format('- %d more files  +%d -%d',
      [Hidden, HiddenAdd, HiddenRem]);
  end;
end;

end.
