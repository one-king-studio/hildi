unit TUIWidgetsText;
{ Styled text for the TUI toolkit: a leaf widget holding spans of text that are
  measured and rendered in display columns.

  Wrapping and width are grapheme-cluster and East Asian width aware, reusing
  the RTL's graphemebreakproperty and eastasianwidth units (the same ones FPC's
  video unit uses). A wide cluster occupies two columns; a combining mark stays
  part of its base cluster and adds no width. }

{$mode delphi}{$H+}

interface

uses
  TUIBase, TUIGrapheme,
  TUIWidget, TUISurface;

type
  TSpan = record
    Text: UnicodeString;
    Attr: TAttr;
  end;

  TSpanArray = array of TSpan;

  TWrapMode = (wmNone, wmChar, wmWord);
  TTextAlign = (taLeft, taCenter, taRight);

  { A styled cluster and the wrapped lines a text block lays out. Exposed so the
    block can cache its layout between measures and renders. }
  TStyledCluster = record
    Ch: UnicodeString;
    Attr: TAttr;
  end;
  TStyledClusters = array of TStyledCluster;
  TStyledLines = array of TStyledClusters;
  { The wrapped lines of a text block, as Unicode strings. AnsiString would be
    lossy here: the toolkit works in UnicodeString, and the conversion would
    corrupt non-ASCII under an ASCII-only widestring manager. }
  TWrappedRows = array of UnicodeString;

  { A leaf that holds styled text, measured and wrapped in display columns. The
    cluster build and the wrap are cached and only redone when the spans or the
    wrap width change, so a large block is not re-wrapped on every frame. }
  TTextBlock = class(TWidget)
  private
    FSpans: array of TSpan;
    FWrap: TWrapMode;
    FAlign: TTextAlign;
    FWrapWidth: Integer;
    FHangIndent: Integer;
    FCacheClusters: TStyledClusters;
    FCacheLines: TStyledLines;
    FCacheWidth: Integer;
    FClustersValid: Boolean;
    FLinesValid: Boolean;
    FLayoutBuilds: Integer;
    function CachedClusters: TStyledClusters;
    function CachedLines(AWidth: Integer): TStyledLines;
    procedure SetHangIndent(AValue: Integer);
  public
    constructor Create(const ASpans: array of TSpan;
      AWrap: TWrapMode = wmNone);
    procedure SetText(const AText: string; const AAttr: TAttr);
    procedure SetSpans(const ASpans: array of TSpan);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    { The number of lines the block wraps to at AWidth, without disturbing the
      cached layout. Used by callers that search over widths. }
    function LineCountAt(AWidth: Integer): Integer;
    { The wrapped lines at AWidth, as plain strings, without disturbing the
      cached layout. Used to build a condensed view (first + ellipsis + tail)
      and a live tail. }
    function WrappedRows(AWidth: Integer): TWrappedRows;
    property Align: TTextAlign read FAlign write FAlign;
    { When > 0 and wrapping is on, Measure wraps at this many columns instead of
      max-content (the longest word). Callers in a fixed-size viewport set it so
      the block fills the width and reports the correct wrapped height. }
    property WrapWidth: Integer read FWrapWidth write FWrapWidth;
    { When > 0, every wrapped line after the first is inset by this many columns
      and wraps that much earlier, so text hangs under a leading marker (a list
      bullet, a quote bar) instead of under the marker itself. }
    property HangIndent: Integer read FHangIndent write SetHangIndent;
    { Diagnostic: how many times the block has built clusters or wrapped. A
      steady-state measure/render must not increase it. }
    property LayoutBuilds: Integer read FLayoutBuilds;
  end;

{ Split a hint line into two-tone spans. Input is one or more "key action"
  segments separated by " · "; output is, per segment, the KEY in AKeyAttr and
  the ACTION in AActionAttr, with the separators in AKeyAttr.

  The key is CHROME - the operator learns it once - so it is passed a dim
  attribute and lowercased here, so no caller can introduce a second house style
  by writing "Ctrl+D". The action is a phrase, not a key, so its case is left
  alone.

  A segment with no space (a lone "/checkpoint to continue" nudge) is drawn
  all-action: there is no binding to dim, and guessing one would mis-colour half
  a sentence.

  A plain function in the text unit rather than a method on either caller,
  because BOTH the chat toolbar and the subagent list show key hints - and two
  copies of this walk would drift. }
function HintSpans(const AText: UnicodeString; const AKeyAttr,
  AActionAttr: TAttr): TSpanArray;

{ Paint spans left-to-right at (X, Y), returning the width drawn. The shared
  renderer for two-tone hint text: the palette's hint row and the skill dialog's
  action row both need it, and a second copy of this walk would drift. }
function PaintSpans(const S: ISurface; AX, AY: Integer;
  const ASpans: TSpanArray): Integer;

{ The display width of a span array, so a caller can right-align before painting. }
function SpansWidth(const ASpans: TSpanArray): Integer;

implementation

{ Split "key action · key action" into two-tone spans. See the interface comment
  for the rules; the walk is deliberately linear over the string - no backtracking,
  no nested scan - because hint text is supplied by the app, and a pathological
  separator must not be able to make the toolbar quadratic. }
function HintSpans(const AText: UnicodeString; const AKeyAttr,
  AActionAttr: TAttr): TSpanArray;
var
  { Built at RUN TIME, not declared as a typed constant. FPC does not apply the
    source codepage to a constant initialiser, so the UTF-8 bytes of a separator
    become two Latin-1 wide characters and it never matches. }
  Sep: UnicodeString;
  Rest, Seg, Key, Action, Split: UnicodeString;
  P, Sp, N: Integer;

  procedure Add(const AText: UnicodeString; const AAttr: TAttr);
  begin
    if AText = '' then
      Exit;
    SetLength(Result, N + 1);
    Result[N].Text := AText;
    Result[N].Attr := AAttr;
    Inc(N);
  end;

  { Collapse a run of spaces to one, so a group gap is not carried into the drawn
    text. }
  function Collapse(const AText: UnicodeString): UnicodeString;
  var
    K: Integer;
    Prev: Boolean;
  begin
    Result := '';
    Prev := False;
    for K := 1 to Length(AText) do
      if AText[K] = ' ' then
      begin
        if not Prev then
          Result := Result + ' ';
        Prev := True;
      end
      else
      begin
        Result := Result + AText[K];
        Prev := False;
      end;
  end;

  { The next group boundary, or 0. TWO OR MORE SPACES separate groups - the
    approval dialog's house style, which the operator asked every CTA to adopt -
    and the middle dot is still accepted so existing call sites keep working. }
  function NextSep(const AText: UnicodeString): Integer;
  var
    K: Integer;
  begin
    Result := Pos(Sep, AText);
    for K := 1 to Length(AText) - 1 do
      if (AText[K] = ' ') and (AText[K + 1] = ' ') then
        if (Result = 0) or (K < Result) then
          Exit(K);
  end;

begin
  Result := nil;
  N := 0;
  Sep := ' ' + UnicodeString(WideChar($00B7)) + ' ';
  Rest := AText;
  while Rest <> '' do
  begin
    P := NextSep(Rest);
    { What separated the groups, so it can be re-emitted: a splitter that drops
      characters would silently corrupt every hint on screen. }
    Split := '';
    if P > 0 then
    begin
      Seg := Copy(Rest, 1, P - 1);
      if Copy(Rest, P, Length(Sep)) = Sep then
      begin
        Split := Sep;
        Rest := Copy(Rest, P + Length(Sep), MaxInt);
      end
      else
      begin
        { A run of spaces separates the groups; ONE space is re-emitted, so the
          drawn hint has a normal gap rather than a hole. }
        Split := ' ';
        while (P <= Length(Rest)) and (Rest[P] = ' ') do
          Inc(P);
        Rest := Copy(Rest, P, MaxInt);
      end;
    end
    else
    begin
      Seg := Rest;
      Rest := '';
    end;
    if Seg = '' then
      Continue;

    Sp := Pos(UnicodeString(' '), Seg);
    if Sp > 1 then
    begin
      { The KEY is chrome: lowercased whatever the caller wrote, so there is one
        house style. The ACTION keeps its case - it is a phrase, not a key. }
      Key := LowerCase(Copy(Seg, 1, Sp - 1));
      Action := Collapse(Copy(Seg, Sp, MaxInt));
      Add(Key, AKeyAttr);
      Add(Action, AActionAttr);
    end
    else
      Add(Collapse(Seg), AActionAttr);

    { Re-emit the separator so joining the spans reproduces the input. }
    if (Rest <> '') and (Split <> '') then
      Add(Split, AKeyAttr);
  end;
end;

function PaintSpans(const S: ISurface; AX, AY: Integer;
  const ASpans: TSpanArray): Integer;
var
  I, X: Integer;
begin
  { Paint left to right, advancing by DISPLAY WIDTH rather than string length: a
    wide glyph occupies two columns, so a length step would overlap the next
    span. This is the shared renderer for the palette hint row and the skill
    dialog's action row. }
  X := AX;
  for I := 0 to High(ASpans) do
  begin
    if ASpans[I].Text = '' then
      Continue;
    PutText(S, X, AY, ASpans[I].Text, ASpans[I].Attr);
    X := X + StringWidth(ASpans[I].Text);
  end;
  Result := X - AX;
end;

function SpansWidth(const ASpans: TSpanArray): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ASpans) do
    Result := Result + StringWidth(ASpans[I].Text);
end;

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
  C: TUIGrapheme.TClusterArray;
  Sc: TStyledCluster;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(ASpans) do
  begin
    C := TUIGrapheme.Clusters(ASpans[I].Text);
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

function WrapClusters(const AClusters: TStyledClusters; AWidth, AIndent: Integer;
  AMode: TWrapMode): TStyledLines;
var
  I, J, K, N, W, CurW, BS, EffW: Integer;
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
    { Lines after the first are inset by the hanging indent, so they wrap that
      much earlier (never below one column). }
    EffW := AWidth;
    if (AIndent > 0) and (Length(Result) > 0) then
      Dec(EffW, AIndent);
    if EffW < 1 then
      EffW := 1;
    if (AMode <> wmNone) and (AWidth > 0) and (Length(Cur) > 0) and
      (CurW + W > EffW) then
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
  FClustersValid := False;
  FLinesValid := False;
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
  FClustersValid := False;
  FLinesValid := False;
end;

function TTextBlock.CachedClusters: TStyledClusters;
begin
  if not FClustersValid then
  begin
    FCacheClusters := BuildClusters(FSpans);
    FClustersValid := True;
    FLinesValid := False;
    Inc(FLayoutBuilds);
  end;
  Result := FCacheClusters;
end;

function TTextBlock.CachedLines(AWidth: Integer): TStyledLines;
begin
  if FLinesValid and (FCacheWidth = AWidth) then
    Exit(FCacheLines);
  FCacheLines := WrapClusters(CachedClusters, AWidth, FHangIndent, FWrap);
  FCacheWidth := AWidth;
  FLinesValid := True;
  Inc(FLayoutBuilds);
  Result := FCacheLines;
end;

procedure TTextBlock.SetHangIndent(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  if AValue = FHangIndent then
    Exit;
  FHangIndent := AValue;
  FLinesValid := False;
end;

function TTextBlock.Measure(const AAvail: TSize): TSize;
var
  Lines: TStyledLines;
  I, LW: Integer;
begin
  Result := Default(TSize);
  if FWrap = wmNone then
  begin
    Lines := CachedLines(0);
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
    Result.H := Length(CachedLines(FWrapWidth));
  end
  else
  begin
    Result.W := LongestWordWidth(CachedClusters);
    Result.H := Length(CachedLines(Result.W));
  end;
end;

function TTextBlock.LineCountAt(AWidth: Integer): Integer;
begin
  if AWidth < 1 then
    AWidth := 1;
  Result := Length(WrapClusters(CachedClusters, AWidth, FHangIndent, FWrap));
end;

function TTextBlock.WrappedRows(AWidth: Integer): TWrappedRows;
var
  Lines: TStyledLines;
  I, J: Integer;
  S: UnicodeString;
begin
  Result := nil;
  if AWidth < 1 then
    AWidth := 1;
  Lines := WrapClusters(CachedClusters, AWidth, FHangIndent, FWrap);
  SetLength(Result, Length(Lines));
  for I := 0 to High(Lines) do
  begin
    S := '';
    for J := 0 to High(Lines[I]) do
      S := S + Lines[I][J].Ch;
    Result[I] := S;
  end;
end;

procedure TTextBlock.Render(const S: ISurface);
var
  Lines: TStyledLines;
  Row, I, X, LW, Offset, CW, Base, AvailW: Integer;
  Clip: TRect;
  FirstRow, LastRow: Integer;
  Cell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Lines := CachedLines(FBounds.W);
  S.PushClip(FBounds);
  { Only draw the rows the clip can show: a tall block that is scrolled mostly
    off-screen would otherwise walk every row. }
  Clip := S.ClipRect;
  FirstRow := Clip.Y - FBounds.Y;
  if FirstRow < 0 then
    FirstRow := 0;
  LastRow := Clip.Y + Clip.H - 1 - FBounds.Y;
  if LastRow > FBounds.H - 1 then
    LastRow := FBounds.H - 1;
  if LastRow > High(Lines) then
    LastRow := High(Lines);
  for Row := FirstRow to LastRow do
  begin
    LW := LineWidth(Lines[Row]);
    { The hanging indent insets every row after the first, so wrapped text
      aligns under the marker's text rather than under the marker. }
    if Row > 0 then
    begin
      Base := FHangIndent;
      AvailW := FBounds.W - FHangIndent;
    end
    else
    begin
      Base := 0;
      AvailW := FBounds.W;
    end;
    case FAlign of
      taCenter:
        Offset := Base + (AvailW - LW) div 2;
      taRight:
        Offset := Base + AvailW - LW;
    else
      Offset := Base;
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
