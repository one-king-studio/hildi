unit hildegard.helper.shell.textlines;
{ Line splitting for the builtin text commands, in one place so the platform
  policy is decided once.

  Unix keeps a trailing CR (byte-faithful: grep there matches the CR too);
  Windows strips it, or every line of a CRLF file carries a stray CR into
  matching, output and `wc -l` arithmetic. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

function SplitLinesEx(const S: string; AStripCR: Boolean): TStringArray;
function SplitLines(const S: string): TStringArray;
function LinesOf(const S: string): TStringArray;

implementation

function SplitLinesEx(const S: string; AStripCR: Boolean): TStringArray;
var
  I, N, K, Len: Integer;
begin
  Result := nil;
  K := 0;
  I := 1;
  while I <= Length(S) do
  begin
    N := I;
    while (N <= Length(S)) and (S[N] <> #10) do
      Inc(N);
    Len := N - I;
    if AStripCR and (Len > 0) and (S[N - 1] = #13) then
      Dec(Len);
    SetLength(Result, K + 1);
    Result[K] := Copy(S, I, Len);
    Inc(K);
    I := N + 1;
  end;
end;

function SplitLines(const S: string): TStringArray;
begin
  {$ifdef windows}
  Result := SplitLinesEx(S, True);
  {$else}
  Result := SplitLinesEx(S, False);
  {$endif}
end;

function LinesOf(const S: string): TStringArray;
begin
  Result := SplitLines(S);
end;

end.
