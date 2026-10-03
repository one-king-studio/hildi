unit hildegard.helper.tui.compact;
{ Compact long text for display: trim blank lines from the edges, then, when
  more than MaxLines remain, keep the first HeadLines and the last TailLines
  around a single '...' line. Pure; no widgets, no terminal. }

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

function DefaultCompactOptions: TCompactOptions;

{ Trim leading and trailing blank lines (whitespace-only counts as blank).
  If more than MaxLines remain, return HeadLines, a '...' line, then TailLines.
  Interior blank lines are preserved. }
function CompactLines(const AText: UnicodeString;
  const AOptions: TCompactOptions): UnicodeString;

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

function CompactLines(const AText: UnicodeString;
  const AOptions: TCompactOptions): UnicodeString;
var
  Lines: array of UnicodeString;
  I, First, Last, Count: Integer;
  Buf: UnicodeString;

  procedure AddLine(const S: UnicodeString);
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := S;
  end;

  function Joined(AFrom, ATo: Integer): UnicodeString;
  var
    J: Integer;
  begin
    Result := '';
    for J := AFrom to ATo do
    begin
      if J > AFrom then
        Result := Result + #10;
      Result := Result + Lines[J];
    end;
  end;

  function Elided: UnicodeString;
  var
    Head, Tail: UnicodeString;
  begin
    Head := '';
    Tail := '';
    if AOptions.HeadLines > 0 then
      Head := Joined(First, First + AOptions.HeadLines - 1) + #10;
    if AOptions.TailLines > 0 then
      Tail := #10 + Joined(Last - AOptions.TailLines + 1, Last);
    Result := Head + '...' + Tail;
  end;

begin
  { Split on LF, tolerating CRLF. }
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

  { Trim blank edges. }
  First := 0;
  Last := High(Lines);
  while (First <= Last) and IsBlank(Lines[First]) do
    Inc(First);
  while (Last >= First) and IsBlank(Lines[Last]) do
    Dec(Last);
  if First > Last then
    Exit('');

  Count := Last - First + 1;
  if Count <= AOptions.MaxLines then
    Exit(Joined(First, Last));

  Result := Elided;
end;

end.
