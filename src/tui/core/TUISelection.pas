unit TUISelection;
{ Character-granular text selection: the pure arithmetic.

  Everything here is in DISPLAY CELLS, never string indices. A column is a
  terminal column, so an East Asian wide character occupies two and a combining
  mark occupies none - the same rule the renderer follows. Mixing the two
  (`Length` where `StringWidth` belongs) is the bug this unit exists to prevent.

  A row is a DISPLAY row within the widget's own content, not a document line
  and not a surface Y. Because wrapping is the widget's business, a caller also
  says which rows ended by WRAPPING rather than by a line break: that is the
  only way a copy can avoid inventing a newline inside a soft-wrapped paragraph.

  No widget, no surface, no terminal. This is the part of selection that has to
  be right before any of it is worth looking at. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils,
  TUIGrapheme;

type
  { A position inside a text-drawing widget. }
  TTextPos = record
    Row: Integer;
    Col: Integer;
  end;

  { An ordered range: Start is inclusive, End is exclusive, both in cells. }
  TTextSpan = record
    Start: TTextPos;
    Stop: TTextPos;
  end;

  { Anchor is where the drag began, Caret the moving end. The pair is kept
    unnormalised so a drag can reverse direction without losing its origin. }
  TSelection = record
    Active: Boolean;
    Anchor: TTextPos;
    Caret: TTextPos;
    { Set when the content changed underneath the selection. The owner clears
      the selection rather than trying to re-map it. }
    Stale: Boolean;
  end;

  TBoolArray = array of Boolean;

{ The anchor/caret pair as an ordered, half-open span. An inactive selection
  yields an empty span at the origin. }
function SelectionSpan(const ASel: TSelection): TTextSpan;

{ True when the span covers no cells at all. }
function SelectionIsEmpty(const ASpan: TTextSpan): Boolean;

{ True when the selection can be copied: active, not stale, not empty. }
function SelectionIsUsable(const ASel: TSelection): Boolean;

{ Clamp a position into the content: row into [0, ARowCount-1], column into
  [0, ARowWidth]. Dragging past an edge must never produce a negative or
  out-of-range position. }
function ClampPos(const APos: TTextPos; ARowWidth, ARowCount: Integer): TTextPos;

{ The selected text.

  ALines are the rows exactly as drawn. AWraps, when given, says which rows ended
  by wrapping; a wrapped row is joined to the next with nothing, a hard break
  with LineEnding. Pass nil to treat every row as a hard break.

  Cell boundaries snap OUTWARD to cluster edges: a span starting inside a wide
  character takes the whole character, because half a character cannot be
  copied. }
function SelectionText(const ASpan: TTextSpan;
  const ALines: TStringArray; const AWraps: TBoolArray): string;

implementation

function SelectionSpan(const ASel: TSelection): TTextSpan;
begin
  Result := Default(TTextSpan);
  if not ASel.Active then
    Exit;
  if (ASel.Caret.Row < ASel.Anchor.Row) or
     ((ASel.Caret.Row = ASel.Anchor.Row) and (ASel.Caret.Col < ASel.Anchor.Col)) then
  begin
    Result.Start := ASel.Caret;
    Result.Stop := ASel.Anchor;
  end
  else
  begin
    Result.Start := ASel.Anchor;
    Result.Stop := ASel.Caret;
  end;
end;

function SelectionIsEmpty(const ASpan: TTextSpan): Boolean;
begin
  Result := (ASpan.Start.Row = ASpan.Stop.Row) and
    (ASpan.Start.Col = ASpan.Stop.Col);
end;

function SelectionIsUsable(const ASel: TSelection): Boolean;
begin
  Result := ASel.Active and (not ASel.Stale) and
    (not SelectionIsEmpty(SelectionSpan(ASel)));
end;

function ClampPos(const APos: TTextPos; ARowWidth, ARowCount: Integer): TTextPos;
begin
  Result := APos;
  if Result.Row < 0 then
    Result.Row := 0;
  if ARowCount > 0 then
  begin
    if Result.Row > ARowCount - 1 then
      Result.Row := ARowCount - 1;
  end
  else
    Result.Row := 0;
  if Result.Col < 0 then
    Result.Col := 0;
  if Result.Col > ARowWidth then
    Result.Col := ARowWidth;
end;

{ Concatenate the clusters of ALine that overlap the cell range [AStartCol,
  AEndCol). A cluster is taken WHOLE: overlapping either edge includes it. }
function ExtractCells(const ALine: UnicodeString;
  AStartCol, AEndCol: Integer): UnicodeString;
var
  Cl: TClusterArray;
  I, Cell, W: Integer;
begin
  Result := '';
  if AEndCol <= AStartCol then
    Exit;
  Cl := Clusters(ALine);
  Cell := 0;
  for I := 0 to High(Cl) do
  begin
    W := ClusterWidth(Cl[I]);
    if W = 0 then
    begin
      { A zero-width cluster belongs to whatever cell we are standing on, so it
        travels if that cell is inside the range. }
      if (Cell >= AStartCol) and (Cell <= AEndCol) then
        Result := Result + Cl[I];
    end
    else if (Cell < AEndCol) and (Cell + W > AStartCol) then
      Result := Result + Cl[I];
    Inc(Cell, W);
  end;
end;

function RowWrapped(const AWraps: TBoolArray; ARow: Integer): Boolean;
begin
  Result := (AWraps <> nil) and (ARow >= 0) and (ARow <= High(AWraps)) and
    AWraps[ARow];
end;

function SelectionText(const ASpan: TTextSpan;
  const ALines: TStringArray; const AWraps: TBoolArray): string;
var
  Row, StartCol, EndCol, W: Integer;
  First: Boolean;
  U: UnicodeString;
begin
  U := '';
  if SelectionIsEmpty(ASpan) then
  begin
    Result := '';
    Exit;
  end;
  First := True;
  for Row := ASpan.Start.Row to ASpan.Stop.Row do
  begin
    if (Row < 0) or (Row > High(ALines)) then
      Continue;
    W := StringWidth(UnicodeString(ALines[Row]));
    if Row = ASpan.Start.Row then
      StartCol := ASpan.Start.Col
    else
      StartCol := 0;
    if Row = ASpan.Stop.Row then
      EndCol := ASpan.Stop.Col
    else
      EndCol := W;
    if EndCol > W then
      EndCol := W;
    if StartCol < 0 then
      StartCol := 0;

    if not First then
      { Join on the PREVIOUS row's wrap: a row that ended by wrapping continues
        the same sentence, so no newline belongs there. }
      if not RowWrapped(AWraps, Row - 1) then
        U := U + UnicodeString(LineEnding);

    U := U + ExtractCells(UnicodeString(ALines[Row]), StartCol, EndCol);
    First := False;
  end;
  { One explicit conversion at the boundary. Building in Unicode and encoding
    once is clearer than converting at every concatenation, and it keeps the
    compiler's implicit-conversion warnings - which this project treats as
    errors - from firing on every line. }
  Result := UTF8Encode(U);
end;

end.
