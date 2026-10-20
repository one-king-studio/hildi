unit hildegard.helper.utf8;
{ Byte-wise cuts that never split a UTF-8 sequence.

  The harness caps output in *bytes* (a stream, a tool result, a live block),
  but cutting at an arbitrary byte leaves a truncated sequence, and any decoder
  then shows it as U+FFFD - the replacement character, which reads as a boxed
  question mark in a terminal. Cut on a boundary instead and the only artifact
  is a clean end. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

{ The longest prefix of AText that is at most AMaxBytes long and ends on a
  complete UTF-8 sequence. A negative bound yields ''. }
function Utf8Prefix(const AText: string; AMaxBytes: Integer): string;

{ AText without its first ASkipBytes bytes, moved forward to the next sequence
  start so the result begins on a whole character. }
function Utf8From(const AText: string; ASkipBytes: Integer): string;

implementation

{ A continuation byte is 10xxxxxx. }
function IsContinuation(ACh: Char): Boolean;
begin
  Result := (Ord(ACh) and $C0) = $80;
end;

function Utf8Prefix(const AText: string; AMaxBytes: Integer): string;
var
  N: Integer;
begin
  if AMaxBytes <= 0 then
    Exit('');
  if Length(AText) <= AMaxBytes then
    Exit(AText);
  N := AMaxBytes;
  { Back up over a partial sequence: the byte at N ends a character only when
    it is not a continuation, or when the sequence starting before it fits. }
  while (N > 0) and IsContinuation(AText[N + 1]) do
    Dec(N);
  Result := Copy(AText, 1, N);
end;

function Utf8From(const AText: string; ASkipBytes: Integer): string;
var
  N: Integer;
begin
  if ASkipBytes <= 0 then
    Exit(AText);
  if ASkipBytes >= Length(AText) then
    Exit('');
  N := ASkipBytes + 1;
  while (N <= Length(AText)) and IsContinuation(AText[N]) do
    Inc(N);
  Result := Copy(AText, N, MaxInt);
end;

end.
