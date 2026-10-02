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
  hildegard.helper.tui.base, hildegard.helper.tui.grapheme,
  hildegard.helper.tui.widget, hildegard.helper.tui.surface;

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
      AWrap: TWrapMode = wmNone);
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

type
  TStyledCluster = record
    Ch: UnicodeString;
    Attr: TAttr;
  end;
  TStyledClusters = array of TStyledCluster;
  TStyledLines = array of TStyledClusters;

function LineWidth(const ALine: TStyledClusters): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ALine) do
    Inc(Result, ClusterWidth(ALine[I].Ch));
end;

function LongestWordWidth(const AClusters: TStyledClusters): Integer;
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

function BuildClusters(const ASpans: array of TSpan): TStyledClusters;
var
  I, J, N: Integer;
  { The grapheme helper's plain cluster array (styled clusters are local). }
  C: hildegard.helper.tui.grapheme.TClusterArray;
  Sc: TStyledCluster;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(ASpans) do
  begin
    C := hildegard.helper.tui.grapheme.Clusters(ASpans[I].Text);
    for J := 0 to High(C) do
    begin
      Sc := Default(TStyledCluster);
      Sc.Ch := C[J];
      Sc.Attr := ASpans[I].Attr;
      SetLength(Result, N + 1);
      Result[N] := Sc;
      Inc(N);
    end;
  end;
end;

function WrapClusters(const AClusters: TStyledClusters; AWidth: Integer;
  AMode: TWrapMode): TStyledLines;
var
  I, J, K, N, W, CurW, BS: Integer;
  Cur, Line, Rem: TStyledClusters;
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
  Clusters: TStyledClusters;
  Lines: TStyledLines;
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
  Clusters: TStyledClusters;
  Lines: TStyledLines;
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
