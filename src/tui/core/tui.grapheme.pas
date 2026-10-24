unit tui.grapheme;
{ Grapheme-cluster and display-width helpers shared by the TUI text widgets.

  Reuses the RTL's graphemebreakproperty and eastasianwidth units (the same
  ones FPC's video unit uses). A wide cluster occupies two columns; a combining
  mark stays part of its base cluster and adds no width. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils;

type
  TClusterArray = array of UnicodeString;
  TClusterOffsetArray = array of Integer;

{ Split AText into extended grapheme clusters, in order. }
function Clusters(const AText: UnicodeString): TClusterArray;

{ The display width of one cluster: 2 for East Asian wide/fullwidth, 0 for an
  empty cluster, otherwise 1. A combining mark belongs to its base cluster and
  is not passed here on its own. }
function ClusterWidth(const ACluster: UnicodeString): Integer;

{ The display width of AText, summed over its clusters. }
function StringWidth(const AText: UnicodeString): Integer;

{ The 1-based code-unit offset of each cluster's first character, so a caller
  can slice AText by cluster index. Length matches Clusters(AText). }
function ClusterStarts(const AText: UnicodeString): TClusterOffsetArray;

implementation

uses
  graphemebreakproperty, eastasianwidth;

function FirstCodePoint(const ACluster: UnicodeString): UCS4Char;
var
  C1, C2: UCS4Char;
begin
  Result := 0;
  if Length(ACluster) = 0 then
    Exit;
  C1 := UCS4Char(ACluster[1]);
  if (C1 >= $D800) and (C1 <= $DBFF) and (Length(ACluster) >= 2) then
  begin
    C2 := UCS4Char(ACluster[2]);
    if (C2 >= $DC00) and (C2 <= $DFFF) then
      Result := $10000 + ((C1 - $D800) shl 10) or (C2 - $DC00)
    else
      Result := C1;
  end
  else
    Result := C1;
end;

function ClusterWidth(const ACluster: UnicodeString): Integer;
begin
  if Length(ACluster) = 0 then
    Exit(0);
  case GetEastAsianWidth(FirstCodePoint(ACluster)) of
    eawW, eawF:
      Result := 2;
  else
    Result := 1;
  end;
end;

function Clusters(const AText: UnicodeString): TClusterArray;
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
  N: Integer;
begin
  Result := nil;
  N := 0;
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(AText);
  try
    while E.MoveNext do
    begin
      SetLength(Result, N + 1);
      Result[N] := E.Current;
      Inc(N);
    end;
  finally
    E.Free;
  end;
end;

function StringWidth(const AText: UnicodeString): Integer;
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
begin
  Result := 0;
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(AText);
  try
    while E.MoveNext do
      Inc(Result, ClusterWidth(E.Current));
  finally
    E.Free;
  end;
end;

function ClusterStarts(const AText: UnicodeString): TClusterOffsetArray;
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
  N, Offset: Integer;
begin
  Result := nil;
  N := 0;
  Offset := 1;
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(AText);
  try
    while E.MoveNext do
    begin
      SetLength(Result, N + 1);
      Result[N] := Offset;
      Inc(N);
      Inc(Offset, Length(E.Current));
    end;
  finally
    E.Free;
  end;
end;

end.
