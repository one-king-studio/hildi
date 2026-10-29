unit TUICompact;
{ Compact long text for display: trim blank lines from the edges, then elide.
  CompactLines keeps the head and the tail around a '...' line; TailLines keeps
  only the tail (for a live, growing stream). Pure; no widgets, no terminal. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils;

type
  TCompactOptions = record
    MaxLines: Integer;    // at or below this, the text is unchanged (default 10)
    HeadLines: Integer;   // kept from the top when eliding (default 2)
    TailLines: Integer;   // kept from the bottom when eliding (default 3)
  end;

  TUnicodeLines = array of UnicodeString;

function DefaultCompactOptions: TCompactOptions;

{ Trim leading and trailing blank lines (whitespace-only counts as blank).
  If more than MaxLines remain, return HeadLines, a '...' line, then TailLines.
  Interior blank lines are preserved. }
function CompactLines(const AText: UnicodeString;
  const AOptions: TCompactOptions): UnicodeString;

{ Trim blank edges, then keep the last AMaxLines. When the text has more lines
  than the window, a '...' line is prepended to signal what is above. }
function TailLines(const AText: UnicodeString; AMaxLines: Integer): UnicodeString;

implementation

function DefaultCompactOptions: TCompactOptions;
begin
  Result := Default(TCompactOptions);
  Result.MaxLines := 10;
  Result.HeadLines := 2;
  Result.TailLines := 3;
end;

function IsBlank(const S: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if not (S[I] in [' ', #9, #13]) then
      Exit(False);
  Result := True;
end;

{ Split on LF, tolerating CRLF. }
function SplitLines(const AText: UnicodeString): TUnicodeLines;
var
  I: Integer;
  Buf: UnicodeString;

  procedure AddLine(const S: UnicodeString);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  Result := nil;
  Buf := '';
  for I := 1 to Length(AText) do
    if AText[I] = #10 then
    begin
      AddLine(Buf);
      Buf := '';
    end
    else if AText[I] <> #13 then
      Buf := Buf + AText[I];
  AddLine(Buf);
end;

{ Trim blank lines from both ends in place. False when nothing is left. }
function TrimBlankEdges(var ALines: TUnicodeLines): Boolean;
var
  First, Last, I: Integer;
  Kept: TUnicodeLines;
begin
  First := 0;
  Last := High(ALines);
  while (First <= Last) and IsBlank(ALines[First]) do
    Inc(First);
  while (Last >= First) and IsBlank(ALines[Last]) do
    Dec(Last);
  if First > Last then
    Exit(False);
  SetLength(Kept, Last - First + 1);
  for I := First to Last do
    Kept[I - First] := ALines[I];
  ALines := Kept;
  Result := True;
end;

function Joined(const ALines: TUnicodeLines; AFrom, ATo: Integer): UnicodeString;
var
  J: Integer;
begin
  Result := '';
  for J := AFrom to ATo do
  begin
    if J > AFrom then
      Result := Result + #10;
    Result := Result + ALines[J];
  end;
end;

function CompactLines(const AText: UnicodeString;
  const AOptions: TCompactOptions): UnicodeString;
var
  Lines: TUnicodeLines;
  Head, Tail: UnicodeString;
begin
  Lines := SplitLines(AText);
  if not TrimBlankEdges(Lines) then
    Exit('');
  if Length(Lines) <= AOptions.MaxLines then
    Exit(Joined(Lines, 0, High(Lines)));

  Head := '';
  Tail := '';
  if AOptions.HeadLines > 0 then
    Head := Joined(Lines, 0, AOptions.HeadLines - 1) + #10;
  if AOptions.TailLines > 0 then
    Tail := #10 + Joined(Lines, Length(Lines) - AOptions.TailLines,
      High(Lines));
  Result := Head + '...' + Tail;
end;

function TailLines(const AText: UnicodeString; AMaxLines: Integer): UnicodeString;
var
  Lines: TUnicodeLines;
begin
  Lines := SplitLines(AText);
  if not TrimBlankEdges(Lines) then
    Exit('');
  if AMaxLines < 1 then
    AMaxLines := 1;
  if Length(Lines) <= AMaxLines then
    Exit(Joined(Lines, 0, High(Lines)));
  Result := '...' + #10 + Joined(Lines, Length(Lines) - AMaxLines,
    High(Lines));
end;

end.
