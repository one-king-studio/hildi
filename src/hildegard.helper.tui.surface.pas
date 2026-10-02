unit hildegard.helper.tui.surface;
{ The rendering-target seam for the TUI toolkit.

  ISurface is the only thing widgets draw into. TSurfaceMemory is the in-memory
  implementation used by tests: it records the cell buffer, enforces clipping,
  and counts how many cells changed on the last Flush, so diff locality is a
  deterministic, testable property. TSurfaceVideo (over FPC's video unit) is a
  separate adapter added in the terminal phase; this unit carries no terminal
  dependency. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base;

type
  { The rendering target. Coordinates are surface-absolute and clipped by the
    current clip rectangle. }
  ISurface = interface
    function Width: Integer;
    function Height: Integer;
    { Adopt a new size and request a full repaint. The app calls this when the
      input source reports a settled terminal resize, so the surface never polls
      the terminal itself and a window drag cannot repaint every intermediate
      size. }
    procedure Resize(AWidth, AHeight: Integer);
    procedure Clear(const AAttr: TAttr);
    procedure Put(X, Y: Integer; const ACell: TCell);
    procedure FillRect(const R: TRect; const AAttr: TAttr);
    procedure DimRect(const R: TRect);
    procedure PushClip(const R: TRect);
    procedure PopClip;
    { Request a full repaint on the next Flush: every cell is re-emitted rather
      than diffed. Used after interaction to guarantee a clean screen when the
      terminal's own diffing can leave stale cells (e.g. wide-character edges). }
    procedure Invalidate;
    { The palette index painted for cells whose attr has sfScreenBg. Set by the
      app from the theme so text backgrounds match the screen. }
    procedure SetScreenBg(AIndex: Byte);
    procedure Flush;
  end;

  { In-memory surface for tests: a Width x Height cell array, plus a previous
    frame to diff against. Flush never emits; it counts changed cells and calls.
    CellAt/RowText expose the buffer for cell-by-cell assertions. }
  TSurfaceMemory = class(TInterfacedObject, ISurface)
  private
    FWidth, FHeight: Integer;
    FCells: array of TCell;
    FPrev: array of TCell;
    FClips: array of TRect;
    FClipCount: Integer;
    FFlushCount: Integer;
    FChanged: Integer;
    FFirstFlush: Boolean;
    FForceFull: Boolean;
    FInvalidations: Integer;
    FScreenBg: Byte;
    function IndexOf(X, Y: Integer): Integer;
    function EffectiveClip: TRect;
    function InClip(X, Y: Integer): Boolean;
    function Intersect(const A, B: TRect): TRect;
    function SameCell(const A, B: TCell): Boolean;
  public
    constructor Create(AWidth, AHeight: Integer);
    function CellAt(X, Y: Integer): TCell;
    function FlushCount: Integer;
    function LastFrameChangedCells: Integer;
    function Invalidations: Integer;
    function RowText(Y, X, Len: Integer): UnicodeString;
    procedure ResetFrameStats;
    procedure Resize(AWidth, AHeight: Integer);
    { ISurface }
    function Width: Integer;
    function Height: Integer;
    procedure Clear(const AAttr: TAttr);
    procedure Put(X, Y: Integer; const ACell: TCell);
    procedure FillRect(const R: TRect; const AAttr: TAttr);
    procedure DimRect(const R: TRect);
    procedure PushClip(const R: TRect);
    procedure PopClip;
    procedure Invalidate;
    procedure SetScreenBg(AIndex: Byte);
    procedure Flush;
  end;

implementation

constructor TSurfaceMemory.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FCells, FWidth * FHeight);
  SetLength(FPrev, FWidth * FHeight);
  FClipCount := 0;
  FFlushCount := 0;
  FChanged := 0;
  FFirstFlush := True;
  FForceFull := False;
  FInvalidations := 0;
  FScreenBg := 0;
end;

function TSurfaceMemory.IndexOf(X, Y: Integer): Integer;
begin
  Result := Y * FWidth + X;
end;

function TSurfaceMemory.Intersect(const A, B: TRect): TRect;
var
  X1, Y1, X2, Y2: Integer;
begin
  X1 := A.X;
  if B.X > X1 then
    X1 := B.X;
  Y1 := A.Y;
  if B.Y > Y1 then
    Y1 := B.Y;
  X2 := A.X + A.W;
  if B.X + B.W < X2 then
    X2 := B.X + B.W;
  Y2 := A.Y + A.H;
  if B.Y + B.H < Y2 then
    Y2 := B.Y + B.H;
  Result := Default(TRect);
  Result.X := X1;
  Result.Y := Y1;
  if X2 > X1 then
    Result.W := X2 - X1;
  if Y2 > Y1 then
    Result.H := Y2 - Y1;
end;

function TSurfaceMemory.EffectiveClip: TRect;
begin
  if FClipCount = 0 then
  begin
    Result := Default(TRect);
    Result.X := 0;
    Result.Y := 0;
    Result.W := FWidth;
    Result.H := FHeight;
  end
  else
    Result := FClips[FClipCount - 1];
end;

function TSurfaceMemory.InClip(X, Y: Integer): Boolean;
var
  C: TRect;
begin
  C := EffectiveClip;
  Result := (X >= C.X) and (Y >= C.Y) and (X < C.X + C.W) and (Y < C.Y + C.H);
end;

function TSurfaceMemory.Width: Integer;
begin
  Result := FWidth;
end;

function TSurfaceMemory.Height: Integer;
begin
  Result := FHeight;
end;

procedure TSurfaceMemory.Clear(const AAttr: TAttr);
begin
  FillRect(EffectiveClip, AAttr);
end;

procedure TSurfaceMemory.Put(X, Y: Integer; const ACell: TCell);
begin
  if not InClip(X, Y) then
    Exit;
  FCells[IndexOf(X, Y)] := ACell;
end;

procedure TSurfaceMemory.FillRect(const R: TRect; const AAttr: TAttr);
var
  C: TRect;
  X, Y: Integer;
  Blank: TCell;
begin
  C := Intersect(R, EffectiveClip);
  Blank := Default(TCell);
  Blank.Attr := AAttr;
  Blank.Ch := ErasedChar;
  for Y := C.Y to C.Y + C.H - 1 do
    for X := C.X to C.X + C.W - 1 do
      FCells[IndexOf(X, Y)] := Blank;
end;

procedure TSurfaceMemory.DimRect(const R: TRect);
var
  C: TRect;
  X, Y: Integer;
begin
  C := Intersect(R, EffectiveClip);
  for Y := C.Y to C.Y + C.H - 1 do
    for X := C.X to C.X + C.W - 1 do
      Include(FCells[IndexOf(X, Y)].Attr.Style, sfDim);
end;

procedure TSurfaceMemory.PushClip(const R: TRect);
begin
  if FClipCount >= Length(FClips) then
    SetLength(FClips, FClipCount + 8);
  FClips[FClipCount] := Intersect(EffectiveClip, R);
  Inc(FClipCount);
end;

procedure TSurfaceMemory.PopClip;
begin
  if FClipCount > 0 then
    Dec(FClipCount);
end;

procedure TSurfaceMemory.Invalidate;
begin
  FForceFull := True;
  Inc(FInvalidations);
end;

procedure TSurfaceMemory.SetScreenBg(AIndex: Byte);
begin
  FScreenBg := AIndex;
end;

function TSurfaceMemory.SameCell(const A, B: TCell): Boolean;
begin
  Result := (A.Ch = B.Ch) and (A.Attr.Fg = B.Attr.Fg) and
    (A.Attr.Bg = B.Attr.Bg) and (A.Attr.Style = B.Attr.Style);
end;

procedure TSurfaceMemory.Flush;
var
  I: Integer;
begin
  if FFirstFlush or FForceFull then
  begin
    FChanged := FWidth * FHeight;
    FFirstFlush := False;
    FForceFull := False;
  end
  else
  begin
    FChanged := 0;
    for I := 0 to High(FCells) do
      if not SameCell(FCells[I], FPrev[I]) then
        Inc(FChanged);
  end;
  for I := 0 to High(FCells) do
    FPrev[I] := FCells[I];
  Inc(FFlushCount);
end;

function TSurfaceMemory.CellAt(X, Y: Integer): TCell;
begin
  Result := Default(TCell);
  if (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight) then
    Result := FCells[IndexOf(X, Y)];
end;

function TSurfaceMemory.FlushCount: Integer;
begin
  Result := FFlushCount;
end;

function TSurfaceMemory.LastFrameChangedCells: Integer;
begin
  Result := FChanged;
end;

function TSurfaceMemory.Invalidations: Integer;
begin
  Result := FInvalidations;
end;

function TSurfaceMemory.RowText(Y, X, Len: Integer): UnicodeString;
var
  I, CX: Integer;
begin
  Result := '';
  if (Y < 0) or (Y >= FHeight) then
    Exit;
  for I := 0 to Len - 1 do
  begin
    CX := X + I;
    if (CX >= 0) and (CX < FWidth) then
      Result := Result + FCells[IndexOf(CX, Y)].Ch;
  end;
end;

procedure TSurfaceMemory.ResetFrameStats;
begin
  FFlushCount := 0;
  FChanged := 0;
end;

procedure TSurfaceMemory.Resize(AWidth, AHeight: Integer);
var
  I: Integer;
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FCells, FWidth * FHeight);
  SetLength(FPrev, FWidth * FHeight);
  for I := 0 to High(FCells) do
  begin
    FCells[I] := Default(TCell);
    FPrev[I] := Default(TCell);
  end;
  FClipCount := 0;
  FFirstFlush := True;
  FForceFull := False;
end;

end.
