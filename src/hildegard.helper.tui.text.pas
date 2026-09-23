unit hildegard.helper.tui.text;
{ Styled text for the TUI toolkit: a leaf widget holding spans of text that are
  measured and rendered in display columns.

  Wrapping and width are grapheme-cluster and East Asian width aware, reusing
  the RTL's graphemebreakproperty and eastasianwidth units (the same ones FPC's
  video unit uses). A wide cluster occupies two columns; a combining mark stays
  part of its base cluster and adds no width. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.widget,
  hildegard.helper.tui.surface;

type
  TSpan = record
    Text: UnicodeString;
    Attr: TAttr;
  end;

  TWrapMode = (wmNone, wmChar, wmWord);
  TTextAlign = (taLeft, taCenter, taRight);

  { A leaf that holds styled text, measured and wrapped in display columns. }
  TTextBlock = class(TWidget)
  private
    FSpans: array of TSpan;
    FWrap: TWrapMode;
    FAlign: TTextAlign;
    FWrapWidth: Integer;
  public
    constructor Create(const ASpans: array of TSpan;
      AWrap: TWrapMode = wmWord);
    procedure SetText(const AText: string; const AAttr: TAttr);
    procedure SetSpans(const ASpans: array of TSpan);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    property Align: TTextAlign read FAlign write FAlign;
    { When > 0 and wrapping is on, Measure wraps at this many columns instead of
      max-content (the longest word). Callers in a fixed-size viewport set it so
      the block fills the width and reports the correct wrapped height. }
    property WrapWidth: Integer read FWrapWidth write FWrapWidth;
  end;

implementation

uses
  graphemebreakproperty, eastasianwidth;

type
  TStyledCluster = record
    Ch: UnicodeString;
    Attr: TAttr;
  end;
  TClusterArray = array of TStyledCluster;
  TLineArray = array of TClusterArray;

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

function LineWidth(const ALine: TClusterArray): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ALine) do
    Inc(Result, ClusterWidth(ALine[I].Ch));
end;

function LongestWordWidth(const AClusters: TClusterArray): Integer;
var
  I, W: Integer;
begin
  Result := 0;
  W := 0;
  for I := 0 to High(AClusters) do
    if AClusters[I].Ch = ' ' then
    begin
      if W > Result then
        Result := W;
      W := 0;
    end
    else if (AClusters[I].Ch = #10) or (AClusters[I].Ch = #13) then
    begin
      if W > Result then
        Result := W;
      W := 0;
    end
    else
      Inc(W, ClusterWidth(AClusters[I].Ch));
  if W > Result then
    Result := W;
end;

function BuildClusters(const ASpans: array of TSpan): TClusterArray;
var
  I, N: Integer;
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
  C: TStyledCluster;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(ASpans) do
  begin
    E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(
      ASpans[I].Text);
    try
      while E.MoveNext do
      begin
        C := Default(TStyledCluster);
        C.Ch := E.Current;
        C.Attr := ASpans[I].Attr;
        SetLength(Result, N + 1);
        Result[N] := C;
        Inc(N);
      end;
    finally
      E.Free;
    end;
  end;
end;

function WrapClusters(const AClusters: TClusterArray; AWidth: Integer;
  AMode: TWrapMode): TLineArray;
var
  I, J, K, N, W, CurW, BS: Integer;
  Cur, Line, Rem: TClusterArray;
  Cluster: TStyledCluster;
begin
  Result := nil;
  Cur := nil;
  CurW := 0;
  for I := 0 to High(AClusters) do
  begin
    Cluster := AClusters[I];
    if (Cluster.Ch = #10) or (Cluster.Ch = #13) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Cur;
      Cur := nil;
      CurW := 0;
      Continue;
    end;
    W := ClusterWidth(Cluster.Ch);
    if (AMode <> wmNone) and (AWidth > 0) and (Length(Cur) > 0) and
      (CurW + W > AWidth) then
    begin
      BS := -1;
      if AMode = wmWord then
        for K := High(Cur) downto 0 do
          if Cur[K].Ch = ' ' then
          begin
            BS := K;
            Break;
          end;
      if BS > 0 then
      begin
        SetLength(Line, BS);
        for J := 0 to BS - 1 do
          Line[J] := Cur[J];
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Line;
        N := 0;
        SetLength(Rem, Length(Cur) - BS);
        for J := BS to High(Cur) do
        begin
          Rem[N] := Cur[J];
          Inc(N);
        end;
        K := 0;
        while (K < Length(Rem)) and (Rem[K].Ch = ' ') do
          Inc(K);
        if K > 0 then
        begin
          SetLength(Line, Length(Rem) - K);
          for J := K to High(Rem) do
            Line[J - K] := Rem[J];
          Cur := Line;
        end
        else
          Cur := Rem;
        CurW := LineWidth(Cur);
      end
      else
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Cur;
        Cur := nil;
        CurW := 0;
      end;
    end;
    SetLength(Cur, Length(Cur) + 1);
    Cur[High(Cur)] := Cluster;
    Inc(CurW, W);
  end;
  if Length(Cur) > 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Cur;
  end;
end;

constructor TTextBlock.Create(const ASpans: array of TSpan; AWrap: TWrapMode);
begin
  inherited Create;
  FWrap := AWrap;
  FAlign := taLeft;
  FWrapWidth := 0;
  SetSpans(ASpans);
end;

procedure TTextBlock.SetSpans(const ASpans: array of TSpan);
var
  I: Integer;
begin
  SetLength(FSpans, Length(ASpans));
  for I := 0 to High(ASpans) do
    FSpans[I] := ASpans[I];
end;

procedure TTextBlock.SetText(const AText: string; const AAttr: TAttr);
var
  One: TSpan;
begin
  One := Default(TSpan);
  One.Text := UnicodeString(AText);
  One.Attr := AAttr;
  SetLength(FSpans, 1);
  FSpans[0] := One;
end;

function TTextBlock.Measure(const AAvail: TSize): TSize;
var
  Clusters: TClusterArray;
  Lines: TLineArray;
  I, LW: Integer;
begin
  Result := Default(TSize);
  Clusters := BuildClusters(FSpans);
  if FWrap = wmNone then
  begin
    Lines := WrapClusters(Clusters, 0, wmNone);
    for I := 0 to High(Lines) do
    begin
      LW := LineWidth(Lines[I]);
      if LW > Result.W then
        Result.W := LW;
    end;
    Result.H := Length(Lines);
  end
  else if FWrapWidth > 0 then
  begin
    Result.W := FWrapWidth;
    Lines := WrapClusters(Clusters, FWrapWidth, FWrap);
    Result.H := Length(Lines);
  end
  else
  begin
    Result.W := LongestWordWidth(Clusters);
    Lines := WrapClusters(Clusters, Result.W, FWrap);
    Result.H := Length(Lines);
  end;
end;

procedure TTextBlock.Render(const S: ISurface);
var
  Clusters: TClusterArray;
  Lines: TLineArray;
  Row, I, X, LW, Offset, CW: Integer;
  Cell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Clusters := BuildClusters(FSpans);
  Lines := WrapClusters(Clusters, FBounds.W, FWrap);
  S.PushClip(FBounds);
  for Row := 0 to High(Lines) do
  begin
    if Row >= FBounds.H then
      Break;
    LW := LineWidth(Lines[Row]);
    case FAlign of
      taCenter:
        Offset := (FBounds.W - LW) div 2;
      taRight:
        Offset := FBounds.W - LW;
    else
      Offset := 0;
    end;
    if Offset < 0 then
      Offset := 0;
    X := FBounds.X + Offset;
    for I := 0 to High(Lines[Row]) do
    begin
      CW := ClusterWidth(Lines[Row][I].Ch);
      if X + CW > FBounds.X + FBounds.W then
        Break;
      Cell := Default(TCell);
      Cell.Ch := Lines[Row][I].Ch;
      Cell.Attr := Lines[Row][I].Attr;
      S.Put(X, FBounds.Y + Row, Cell);
      Inc(X, CW);
    end;
  end;
  S.PopClip;
end;

end.
