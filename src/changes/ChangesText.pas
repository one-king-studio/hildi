unit ChangesText;
{ The diff engine: generate a bounded unified diff, and apply one.

  Generation is the genuinely new work here - HildiPatch only ever
  applied. Application is the same algorithm the harness already trusts, moved in
  so there is one implementation rather than two.

  Both sides of a diff are plain text. A caller that cannot read a file as text
  (binary, oversized) does not call this at all; it records hashes and sizes,
  which is what TChangeRecord.Capped and the sizes are for. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TStringArrayLite = array of string;

{ Split into lines, dropping a trailing newline. CR is stripped, so a CRLF file
  and an LF file with the same text compare equal. }
function SplitTextLines(const AText: string): TStringArrayLite;

{ Join back, with a trailing newline when there is any content. }
function JoinTextLines(const ALines: TStringArrayLite): string;

{ A unified diff (3 lines of context) from ABefore to AAfter.

  Returns '' when the texts are equal. ACapBytes bounds the body: a diff that
  would exceed it is truncated at a hunk boundary and ACapped is set, so a caller
  can record "a change happened, the diff was cut" rather than failing. }
function DiffText(const ABefore, AAfter: string; ACapBytes: Integer;
  out ACapped: Boolean): string;

{ Apply a unified diff to AText. The hunks must match the text; a mismatch is an
  error naming the line, because a silent mis-apply is data loss. }
function ApplyUnifiedDiff(const AText, ADiff: string;
  out AResult, AError: string): Boolean;

{ True when two texts are byte-identical. }
function TextEqual(const A, B: string): Boolean;

{ The reverse of a unified diff: swapping - and + turns "apply this change" into
  "undo this change".

  Needed because the log stores only the FORWARD patch. Reverting a recorded
  change therefore means inverting its patch and applying that - which works
  exactly when the file still holds the after-text the record was anchored to.
  A diff that cannot be inverted returns False rather than a guess: a wrong
  revert is data loss, and the caller must be able to refuse. }
function InvertPatch(const ADiff: string; out AInverted, AError: string): Boolean;

implementation

const
  ContextLines = 3;
  LF = #10;

function SplitTextLines(const AText: string): TStringArrayLite;
var
  P, Start, N: Integer;
  Line: string;
begin
  Result := nil;
  N := 0;
  P := 1;
  while P <= Length(AText) + 1 do
  begin
    Start := P;
    while (P <= Length(AText)) and (AText[P] <> LF) do
      Inc(P);
    Line := Copy(AText, Start, P - Start);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    Inc(P);
    SetLength(Result, N + 1);
    Result[N] := Line;
    Inc(N);
  end;
  { A trailing newline produces one empty final element; drop it. }
  if (N > 0) and (Result[N - 1] = '') then
    SetLength(Result, N - 1);
end;

function JoinTextLines(const ALines: TStringArrayLite): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ALines) do
  begin
    if I > 0 then
      Result := Result + LF;
    Result := Result + ALines[I];
  end;
  if Length(ALines) > 0 then
    Result := Result + LF;
end;

function TextEqual(const A, B: string): Boolean;
begin
  Result := A = B;
end;

type
  { One edit of the common subsequence walk. }
  TEditKind = (ekSame, ekDel, ekAdd);

  TEdit = record
    Kind: TEditKind;
    Text: string;
  end;

  TEditArray = array of TEdit;

{ A longest-common-subsequence table plus a walk back to a script of edits.

  ponytail: an O(n*m) LCS, which is fine for source files (a few thousand lines)
  and is the same shape as the applier's assumptions. Ceiling: a very large file
  is quadratic in time and memory. Upgrade path: Myers' O(ND) or a histogram
  diff, if a real corpus ever shows it. }
function BuildEdits(const A, B: TStringArrayLite): TEditArray;
var
  N, M, I, J: Integer;
  Table: array of array of Integer;

  procedure Push(AKind: TEditKind; const AText: string);
  var
    K: Integer;
  begin
    K := Length(Result);
    SetLength(Result, K + 1);
    Result[K].Kind := AKind;
    Result[K].Text := AText;
  end;

begin
  Result := nil;
  N := Length(A);
  M := Length(B);
  SetLength(Table, N + 1, M + 1);
  for I := 0 to N do
    for J := 0 to M do
      Table[I][J] := 0;
  { Table[i][j] = LCS length of A[i..], B[j..]. }
  for I := N - 1 downto 0 do
    for J := M - 1 downto 0 do
      if A[I] = B[J] then
        Table[I][J] := Table[I + 1][J + 1] + 1
      else if Table[I + 1][J] >= Table[I][J + 1] then
        Table[I][J] := Table[I + 1][J]
      else
        Table[I][J] := Table[I][J + 1];
  I := 0;
  J := 0;
  while (I < N) or (J < M) do
  begin
    if (I < N) and (J < M) and (A[I] = B[J]) then
    begin
      Push(ekSame, A[I]);
      Inc(I);
      Inc(J);
    end
    else if (J < M) and ((I >= N) or (Table[I][J + 1] >= Table[I + 1][J])) then
    begin
      Push(ekAdd, B[J]);
      Inc(J);
    end
    else
    begin
      Push(ekDel, A[I]);
      Inc(I);
    end;
  end;
end;

{ Group the edit script into hunks with ContextLines of context. }
function DiffText(const ABefore, AAfter: string; ACapBytes: Integer;
  out ACapped: Boolean): string;
var
  A, B: TStringArrayLite;
  Edits: TEditArray;
  I, K: Integer;
  Out2: string;
  Body: string;
  OldLine, NewLine: Integer;
  HunkStart, HunkEnd: Integer;
  OldCount, NewCount: Integer;
  First: Boolean;

  function CapReached: Boolean;
  begin
    Result := (ACapBytes > 0) and (Length(Out2) + Length(Body) > ACapBytes);
  end;

begin
  Result := '';
  ACapped := False;
  if ABefore = AAfter then
    Exit;
  A := SplitTextLines(ABefore);
  B := SplitTextLines(AAfter);
  Edits := BuildEdits(A, B);
  if Length(Edits) = 0 then
    Exit;

  Out2 := '--- before' + LF + '+++ after' + LF;
  I := 0;
  OldLine := 1;
  NewLine := 1;
  First := True;
  while I <= High(Edits) do
  begin
    { Skip over unchanged runs that are longer than the context on both sides. }
    if Edits[I].Kind = ekSame then
    begin
      Inc(OldLine);
      Inc(NewLine);
      Inc(I);
      Continue;
    end;
    { Start a hunk: back up ContextLines for context. }
    HunkStart := I - ContextLines;
    if HunkStart < 0 then
      HunkStart := 0;
    { Rewind the line counters to the hunk start. }
    OldLine := 1;
    NewLine := 1;
    for K := 0 to HunkStart - 1 do
      if Edits[K].Kind = ekAdd then
        Inc(NewLine)
      else
      begin
        Inc(OldLine);
        if Edits[K].Kind = ekSame then
          Inc(NewLine);
      end;
    { Extend to the end of the changed region plus trailing context. }
    HunkEnd := I;
    while HunkEnd <= High(Edits) do
    begin
      if Edits[HunkEnd].Kind <> ekSame then
        Inc(HunkEnd)
      else
      begin
        { Stop once there are more than 2*Context same lines ahead. }
        K := HunkEnd;
        while (K <= High(Edits)) and (Edits[K].Kind = ekSame) and
          (K - HunkEnd < 2 * ContextLines) do
          Inc(K);
        if (K - HunkEnd >= 2 * ContextLines) or (K > High(Edits)) then
          Break;
        Inc(HunkEnd);
      end;
    end;
    if HunkEnd > High(Edits) + 1 then
      HunkEnd := High(Edits) + 1;

    OldCount := 0;
    NewCount := 0;
    Body := '';
    for K := HunkStart to HunkEnd - 1 do
    begin
      case Edits[K].Kind of
        ekSame:
          begin
            Body := Body + ' ' + Edits[K].Text + LF;
            Inc(OldCount);
            Inc(NewCount);
          end;
        ekDel:
          begin
            Body := Body + '-' + Edits[K].Text + LF;
            Inc(OldCount);
          end;
        ekAdd:
          begin
            Body := Body + '+' + Edits[K].Text + LF;
            Inc(NewCount);
          end;
      end;
    end;
    if CapReached then
    begin
      ACapped := True;
      Break;
    end;
    if First then
      First := False;
    Out2 := Out2 + Format('@@ -%d,%d +%d,%d @@', [OldLine, OldCount,
      NewLine, NewCount]) + LF + Body;
    OldLine := OldLine + OldCount;
    NewLine := NewLine + NewCount;
    I := HunkEnd;
  end;
  if not First then
    Result := Out2;
end;

{ Parse "@@ -a,b +c,d @@". Missing counts default to 1. }
function ParseHunkHeader(const ALine: string; out AOldStart, AOldCount,
  ANewStart, ANewCount: Integer): Boolean;
var
  P: Integer;

  function ReadInt: Integer;
  var
    Start: Integer;
  begin
    Start := P;
    while (P <= Length(ALine)) and (ALine[P] in ['0'..'9']) do
      Inc(P);
    if P = Start then
      Result := -1
    else
      Result := StrToIntDef(Copy(ALine, Start, P - Start), -1);
  end;

begin
  Result := False;
  if Copy(ALine, 1, 3) <> '@@ ' then
    Exit;
  P := 4;
  if (P > Length(ALine)) or (ALine[P] <> '-') then
    Exit;
  Inc(P);
  AOldStart := ReadInt;
  AOldCount := 1;
  if (P <= Length(ALine)) and (ALine[P] = ',') then
  begin
    Inc(P);
    AOldCount := ReadInt;
  end;
  if (P > Length(ALine)) or (ALine[P] <> ' ') then
    Exit;
  Inc(P);
  if (P > Length(ALine)) or (ALine[P] <> '+') then
    Exit;
  Inc(P);
  ANewStart := ReadInt;
  ANewCount := 1;
  if (P <= Length(ALine)) and (ALine[P] = ',') then
  begin
    Inc(P);
    ANewCount := ReadInt;
  end;
  Result := (AOldStart > 0) and (AOldCount >= 0) and (ANewStart > 0) and
    (ANewCount >= 0) and (Pos('@@', Copy(ALine, P, MaxInt)) > 0);
end;

function ApplyUnifiedDiff(const AText, ADiff: string;
  out AResult, AError: string): Boolean;
var
  Lines, Src: TStringArrayLite;
  I, SrcPos: Integer;
  OldStart, OldCount, NewStart, NewCount: Integer;
  Hunk: TStringArrayLite;
  N: Integer;
  OutLines: TStringArrayLite;
  OutN: Integer;

  procedure Emit(const ALine: string);
  begin
    SetLength(OutLines, OutN + 1);
    OutLines[OutN] := ALine;
    Inc(OutN);
  end;

begin
  Result := False;
  AResult := '';
  AError := '';
  if ADiff = '' then
  begin
    AResult := AText;
    Exit(True);
  end;
  Lines := SplitTextLines(ADiff);
  Src := SplitTextLines(AText);
  OutLines := nil;
  OutN := 0;
  SrcPos := 0;           // 0-based index into Src
  I := 0;
  { Skip the ---/+++ header. }
  while (I <= High(Lines)) and (Copy(Lines[I], 1, 3) <> '@@ ') do
    Inc(I);
  while I <= High(Lines) do
  begin
    if Copy(Lines[I], 1, 3) <> '@@ ' then
    begin
      AError := 'expected a hunk header at: ' + Lines[I];
      Exit;
    end;
    if not ParseHunkHeader(Lines[I], OldStart, OldCount, NewStart, NewCount) then
    begin
      AError := 'malformed hunk header: ' + Lines[I];
      Exit;
    end;
    { Copy unchanged lines up to the hunk's start. }
    while SrcPos < OldStart - 1 do
    begin
      if SrcPos > High(Src) then
      begin
        AError := Format('hunk starts at line %d, past the end of the file',
          [OldStart]);
        Exit;
      end;
      Emit(Src[SrcPos]);
      Inc(SrcPos);
    end;
    Inc(I);
    { Collect the hunk body. }
    Hunk := nil;
    N := 0;
    while (I <= High(Lines)) and (Lines[I] <> '') and
      (Copy(Lines[I], 1, 3) <> '@@ ') do
    begin
      SetLength(Hunk, N + 1);
      Hunk[N] := Lines[I];
      Inc(N);
      Inc(I);
    end;
    { Apply it. }
    for N := 0 to High(Hunk) do
    begin
      if Hunk[N] = '' then
        Continue;
      case Hunk[N][1] of
        ' ':
          begin
            if (SrcPos > High(Src)) or
              (Src[SrcPos] <> Copy(Hunk[N], 2, MaxInt)) then
            begin
              AError := Format(
                'context mismatch at line %d: expected %s',
                [SrcPos + 1, QuotedStr(Copy(Hunk[N], 2, MaxInt))]);
              Exit;
            end;
            Emit(Src[SrcPos]);
            Inc(SrcPos);
          end;
        '-':
          begin
            if (SrcPos > High(Src)) or
              (Src[SrcPos] <> Copy(Hunk[N], 2, MaxInt)) then
            begin
              AError := Format('removal mismatch at line %d: expected %s',
                [SrcPos + 1, QuotedStr(Copy(Hunk[N], 2, MaxInt))]);
              Exit;
            end;
            Inc(SrcPos);
          end;
        '+':
          Emit(Copy(Hunk[N], 2, MaxInt));
      else
        AError := 'unexpected hunk line: ' + Hunk[N];
        Exit;
      end;
    end;
  end;
  { The tail after the last hunk. }
  while SrcPos <= High(Src) do
  begin
    Emit(Src[SrcPos]);
    Inc(SrcPos);
  end;
  AResult := JoinTextLines(OutLines);
  Result := True;
end;

{ Rewrite a hunk header's line numbers the other way round: `@@ -a,b +c,d @@`
  becomes `@@ -c,d +a,b @@`. Inverting a patch without this would apply the
  reverse change at the wrong line. }
function SwapHunkHeader(var ALine: string; out AError: string): Boolean;
var
  OldStart, OldCount, NewStart, NewCount: Integer;
  P: Integer;
begin
  Result := False;
  AError := '';
  if not ParseHunkHeader(ALine, OldStart, OldCount, NewStart, NewCount) then
  begin
    AError := 'malformed hunk header: ' + ALine;
    Exit;
  end;
  { Keep any trailing text after the closing @@. }
  P := Length(ALine);
  while (P > 1) and (ALine[P] = '@') do
    Dec(P);
  ALine := Format('@@ -%d,%d +%d,%d @@', [NewStart, NewCount, OldStart,
    OldCount]) + Copy(ALine, P + 1, MaxInt);
  Result := True;
end;

function InvertPatch(const ADiff: string; out AInverted, AError: string): Boolean;
var
  Lines, Out2: TStringArrayLite;
  I, N: Integer;
  Line: string;
  Header: Boolean;
begin
  Result := False;
  AInverted := '';
  AError := '';
  if ADiff = '' then
  begin
    { An empty patch reverses to an empty patch: the change was "nothing", and
      undoing nothing is a no-op rather than an error. }
    Exit(True);
  end;
  Lines := SplitTextLines(ADiff);
  Out2 := nil;
  N := 0;
  Header := True;
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    { The ---/+++ pair comes first, before any hunk. Swap the two labels; their
      paths are informational here and the caller supplies the real one. }
    if Header and (Copy(Line, 1, 4) = '--- ') then
    begin
      SetLength(Out2, N + 1);
      Out2[N] := '--- ' + 'b';
      Inc(N);
      Continue;
    end;
    if Header and (Copy(Line, 1, 4) = '+++ ') then
    begin
      SetLength(Out2, N + 1);
      Out2[N] := '+++ ' + 'a';
      Inc(N);
      Continue;
    end;
    if Copy(Line, 1, 3) = '@@ ' then
    begin
      { A hunk header's line numbers must swap too, or the inverse would apply
        at the wrong place. Parse, swap, re-render. }
      Header := False;
      if not SwapHunkHeader(Line, AError) then
        Exit;
      SetLength(Out2, N + 1);
      Out2[N] := Line;
      Inc(N);
      Continue;
    end;
    if Line = '' then
    begin
      SetLength(Out2, N + 1);
      Out2[N] := '';
      Inc(N);
      Continue;
    end;
    { A body line: - becomes +, + becomes -, context is unchanged. }
    case Line[1] of
      '-':
        Line := '+' + Copy(Line, 2, MaxInt);
      '+':
        Line := '-' + Copy(Line, 2, MaxInt);
      ' ':
        ;   { context is direction-free }
    else
      AError := 'unexpected hunk line: ' + Line;
      Exit;
    end;
    SetLength(Out2, N + 1);
    Out2[N] := Line;
    Inc(N);
  end;
  AInverted := JoinTextLines(Out2);
  Result := True;
end;

end.
