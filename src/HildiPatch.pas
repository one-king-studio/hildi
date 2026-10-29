unit HildiPatch;
{ A unified-diff applier, pure and dependency-free (we do not assume `patch` or
  `git` is installed). It parses `diff -u` / `git diff` output and applies each
  hunk against a file the host supplies via callbacks, so the parser is testable
  without a filesystem.

  Tolerant, not fatal: a hunk that does not apply is counted rejected and the
  rest are attempted. The file's before/after are read/written through the
  injected callbacks (ARead/AWrite), so the unit holds no I/O of its own. See
  docs/features/File_Tools/File_Tools_v2.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { Read the current text of the file named in a hunk header (path already
    stripped of the leading components). Returns False + AError when it cannot
    be read. }
  TPatchRead = function(const APath: string; out AText: string;
    out AError: string): Boolean of object;
  { Write AText to the file named in a hunk header. }
  TPatchWrite = function(const APath: string; const AText: string;
    out AError: string): Boolean of object;

  TPatchResult = record
    Applied: Integer;
    Rejected: Integer;
    RejectedAt: string;    // the first rejected hunk's header, '' if none
    Files: Integer;
  end;

{ Apply a unified diff. AStrip is the number of leading path components to strip
  (the `-p` argument; default 1, matching `patch -p1`). ADryRun computes the
  result without calling AWrite. Never raises on a bad hunk. }
function ApplyUnifiedPatch(const APatch: string; AStrip: Integer;
  ADryRun: Boolean; const ARead: TPatchRead; const AWrite: TPatchWrite;
  out AResult: TPatchResult; out AError: string): Boolean;

implementation

type
  TStringArrayLocal = array of string;

function SplitLines(const S: string): TStringArrayLocal;
var
  P, Start, N: Integer;
  Line: string;
begin
  Result := nil;
  N := 0;
  P := 1;
  while P <= Length(S) + 1 do
  begin
    Start := P;
    while (P <= Length(S)) and (S[P] <> #10) do
      Inc(P);
    Line := Copy(S, Start, P - Start);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    Inc(P);
    SetLength(Result, N + 1);
    Result[N] := Line;
    Inc(N);
  end;
  { A trailing empty line from a final newline is dropped. }
  if (N > 0) and (Result[N - 1] = '') then
    SetLength(Result, N - 1);
end;

function JoinLines(const A: TStringArrayLocal): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + A[I];
  end;
  if Length(A) > 0 then
    Result := Result + #10;
end;

{ Strip AStrip leading path components from a diff path, and a leading a/ or b/
  is one of them. }
function StripPath(const APath: string; AStrip: Integer): string;
var
  P, I, Count: Integer;
begin
  Result := APath;
  Count := AStrip;
  P := 1;
  while (Count > 0) and (P <= Length(Result)) do
  begin
    { Skip to the next '/'. }
    while (P <= Length(Result)) and (Result[P] <> '/') do
      Inc(P);
    if P > Length(Result) then
      Break;
    Inc(P);
    Dec(Count);
  end;
  if (Count = 0) and (P <= Length(Result)) then
    Result := Copy(Result, P, MaxInt);
  { Drop a trailing tab (some diffs add one). }
  I := Pos(#9, Result);
  if I > 0 then
    Result := Copy(Result, 1, I - 1);
end;

{ Parse the "@@ -a,b +c,d @@" header into the old start/count and new start. }
function ParseHunkHeader(const ALine: string; out AOldStart, AOldCount: Integer;
  out ANewStart: Integer): Boolean;
var
  P: Integer;
  function ReadInt(out AValue: Integer): Boolean;
  var
    S: string;
  begin
    S := '';
    while (P <= Length(ALine)) and (ALine[P] in ['0'..'9']) do
    begin
      S := S + ALine[P];
      Inc(P);
    end;
    Result := S <> '';
    AValue := StrToIntDef(S, 0);
  end;
begin
  Result := False;
  AOldStart := 0; AOldCount := 1; ANewStart := 0;
  if Copy(ALine, 1, 3) <> '@@ ' then
    Exit;
  P := 4;
  if (P > Length(ALine)) or (ALine[P] <> '-') then
    Exit;
  Inc(P);
  if not ReadInt(AOldStart) then
    Exit;
  AOldCount := 1;
  if (P <= Length(ALine)) and (ALine[P] = ',') then
  begin
    Inc(P);
    ReadInt(AOldCount);
  end;
  while (P <= Length(ALine)) and (ALine[P] = ' ') do
    Inc(P);
  if (P > Length(ALine)) or (ALine[P] <> '+') then
    Exit;
  Inc(P);
  if not ReadInt(ANewStart) then
    Exit;
  Result := True;
end;

{ Apply one hunk to the lines of AFile. Returns True when it applied. }
function ApplyHunk(var AFile: TStringArrayLocal; AOldStart, AOldCount: Integer;
  const AHunk: TStringArrayLocal): Boolean;
var
  I, Pos_, NewLen, InsertAt: Integer;
  Body, Tail, Out_: TStringArrayLocal;
  OldLines, NewLines, N, K: Integer;

  function BodyKind(const L: string): Char;
  begin
    if L = '' then
      Result := ' '
    else
      Result := L[1];
  end;

begin
  { Build the old/new sequences from the hunk body. }
  OldLines := 0;
  NewLines := 0;
  Body := nil;
  for I := 0 to High(AHunk) do
    if (AHunk[I] <> '') and (AHunk[I][1] = '\') then
      Continue   { "\ No newline at end of file" }
    else
    begin
      SetLength(Body, Length(Body) + 1);
      Body[High(Body)] := AHunk[I];
      case BodyKind(AHunk[I]) of
        ' ': begin Inc(OldLines); Inc(NewLines); end;
        '-': Inc(OldLines);
        '+': Inc(NewLines);
      end;
    end;
  if (AOldCount > 0) and (OldLines <> AOldCount) then
    Exit(False);
  { The hunk's 1-based old start; a count of 0 means insert at that line. }
  if AOldCount = 0 then
    InsertAt := AOldStart        { insert after line AOldStart }
  else
    InsertAt := AOldStart - 1;   { 0-based index of the first old line }
  if InsertAt < 0 then
    InsertAt := 0;
  { Verify the context/removed lines match. }
  Pos_ := InsertAt;
  for I := 0 to High(Body) do
    case BodyKind(Body[I]) of
      ' ':
        begin
          if (Pos_ > High(AFile)) or (AFile[Pos_] <> Copy(Body[I], 2, MaxInt)) then
            Exit(False);
          Inc(Pos_);
        end;
      '-':
        begin
          if (Pos_ > High(AFile)) or (AFile[Pos_] <> Copy(Body[I], 2, MaxInt)) then
            Exit(False);
          Inc(Pos_);
        end;
    end;
  { Build the replacement block (context + added lines), then splice. }
  NewLen := 0;
  for I := 0 to High(Body) do
    if BodyKind(Body[I]) <> '-' then
      Inc(NewLen);
  { Rebuild AFile: [0..InsertAt) + NewBlock + [InsertAt+OldLines..end). }
  Tail := nil;
  N := 0;
  for K := InsertAt + OldLines to High(AFile) do
  begin
    SetLength(Tail, N + 1);
    Tail[N] := AFile[K];
    Inc(N);
  end;
  Out_ := nil;
  N := 0;
  for K := 0 to InsertAt - 1 do
  begin
    SetLength(Out_, N + 1);
    Out_[N] := AFile[K];
    Inc(N);
  end;
  for K := 0 to High(Body) do
    if BodyKind(Body[K]) <> '-' then
    begin
      SetLength(Out_, N + 1);
      if Body[K] = '' then
        Out_[N] := ''
      else
        Out_[N] := Copy(Body[K], 2, MaxInt);
      Inc(N);
    end;
  for K := 0 to High(Tail) do
  begin
    SetLength(Out_, N + 1);
    Out_[N] := Tail[K];
    Inc(N);
  end;
  AFile := Out_;
  Result := True;
end;

function ApplyUnifiedPatch(const APatch: string; AStrip: Integer;
  ADryRun: Boolean; const ARead: TPatchRead; const AWrite: TPatchWrite;
  out AResult: TPatchResult; out AError: string): Boolean;
var
  Lines: TStringArrayLocal;
  I, J: Integer;
  CurPath, Text, Err, NewText: string;
  CurLines: TStringArrayLocal;
  Hunk: TStringArrayLocal;
  InHunk: Boolean;
  OldStart, OldCount, NewStart: Integer;
  AnyFile: Boolean;

  procedure FlushHunk;
  var
    Applied: Boolean;
  begin
    if Length(Hunk) = 0 then
      Exit;
    if ApplyHunk(CurLines, OldStart, OldCount, Hunk) then
      Inc(AResult.Applied)
    else
    begin
      Inc(AResult.Rejected);
      if AResult.RejectedAt = '' then
        AResult.RejectedAt := 'hunk at -' + IntToStr(OldStart);
    end;
    Hunk := nil;
  end;

  function WriteCurrent: Boolean;
  begin
    Result := True;
    NewText := JoinLines(CurLines);
    if ADryRun then
      Exit;
    if not AWrite(CurPath, NewText, Err) then
    begin
      AError := 'could not write ' + CurPath + ': ' + Err;
      Result := False;
    end;
  end;

begin
  AResult := Default(TPatchResult);
  AError := '';
  if AStrip < 0 then
    AStrip := 1;
  Lines := SplitLines(APatch);
  CurPath := '';
  CurLines := nil;
  Hunk := nil;
  InHunk := False;
  AnyFile := False;
  try
    for I := 0 to High(Lines) do
    begin
      if Copy(Lines[I], 1, 4) = '+++ ' then
      begin
        { A new file section: flush the previous one. }
        FlushHunk;
        if AnyFile then
          if not WriteCurrent then
            Exit(False);
        CurPath := StripPath(Trim(Copy(Lines[I], 5, MaxInt)), AStrip);
        if CurPath = '/dev/null' then
          CurPath := '';
        CurLines := nil;
        if CurPath <> '' then
        begin
          if not ARead(CurPath, Text, Err) then
          begin
            AError := 'could not read ' + CurPath + ': ' + Err;
            Exit(False);
          end;
          CurLines := SplitLines(Text);
        end;
        AnyFile := True;
        Inc(AResult.Files);
      end
      else if Copy(Lines[I], 1, 3) = '@@ ' then
      begin
        FlushHunk;
        InHunk := ParseHunkHeader(Lines[I], OldStart, OldCount, NewStart);
      end
      else if InHunk and (CurPath <> '') then
      begin
        { A hunk body line starts with ' ', '+', '-', or '\'. }
        if (Lines[I] <> '') and (Lines[I][1] in [' ', '+', '-', '\']) then
        begin
          SetLength(Hunk, Length(Hunk) + 1);
          Hunk[High(Hunk)] := Lines[I];
        end
        else
          InHunk := False;
      end;
    end;
    FlushHunk;
    if AnyFile then
      if not WriteCurrent then
        Exit(False);
    Result := True;
  finally
    { nothing owned }
  end;
end;

end.
