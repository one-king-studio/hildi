unit hildi.utf8;
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

{ Split AText at the last COMPLETE character boundary: AComplete is everything
  that ends on a whole character, ACarry the trailing bytes of a sequence that is
  not finished yet (or '' when AText ends cleanly).

  For a stream consumer: raw byte windows can split a multi-byte character, and
  forwarding the fragment renders it as U+FFFD. Hold ACarry, prepend it to the
  next chunk, and flush it when the stream ends. }
procedure Utf8SplitAtBoundary(const AText: string;
  out AComplete, ACarry: string);

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

procedure Utf8SplitAtBoundary(const AText: string;
  out AComplete, ACarry: string);
var
  I, Need: Integer;
  B: Byte;
begin
  AComplete := AText;
  ACarry := '';
  if AText = '' then
    Exit;
  { Walk back from the end over continuation bytes to the start of the last
    sequence, then ask how long that sequence should be. }
  I := Length(AText);
  while (I > 0) and IsContinuation(AText[I]) do
    Dec(I);
  if I = 0 then
    { Nothing but continuations: the whole string is a fragment. }
  begin
    AComplete := '';
    ACarry := AText;
    Exit;
  end;
  B := Ord(AText[I]);
  if B >= $F0 then
    Need := 4
  else if B >= $E0 then
    Need := 3
  else if B >= $C0 then
    Need := 2
  else
    Need := 1;
  if (Length(AText) - I + 1) < Need then
  begin
    AComplete := Copy(AText, 1, I - 1);
    ACarry := Copy(AText, I, MaxInt);
  end;
end;

end.
