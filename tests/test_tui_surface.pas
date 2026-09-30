unit test_tui_surface;
{ fpcunit tests for hildegard.helper.tui.base and .surface.

  Every test drives TSurfaceMemory, so nothing here needs a terminal. The
  surface is asserted cell-by-cell; the flush counters make diff locality a
  deterministic property. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.surface;

type
  TTuiSurfaceTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Cell(const ACh: UnicodeString; AFg, ABg: Byte): TCell;
  published
    procedure TestBaseTypesCompile;
    procedure TestSurfaceClearFillsAllCells;
    procedure TestPutOutsideClipIsIgnored;
    procedure TestPushClipIntersects;
    procedure TestFillRect;
    procedure Test256ColorIndexRetainedInCell;
    procedure TestFlushIdempotent;
    procedure TestInvalidateForcesFullRepaint;
    procedure TestDimAddsFaintButKeepsGlyphsAndColors;
  end;

implementation

function TTuiSurfaceTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiSurfaceTest.Cell(const ACh: UnicodeString; AFg, ABg: Byte): TCell;
begin
  Result := Default(TCell);
  Result.Ch := ACh;
  Result.Attr.Fg := AFg;
  Result.Attr.Bg := ABg;
  Result.Attr.Style := [];
end;

procedure TTuiSurfaceTest.TestBaseTypesCompile;
var
  R: TRect;
  C: TCell;
begin
  R := Default(TRect);
  R.X := 1;
  R.Y := 2;
  R.W := 3;
  R.H := 4;
  C := Default(TCell);
  C.Ch := 'x';
  C.Attr := DefaultAttr;
  AssertEquals('rect x', 1, R.X);
  AssertEquals('rect y', 2, R.Y);
  AssertEquals('rect w', 3, R.W);
  AssertEquals('rect h', 4, R.H);
  AssertEquals('default fg', 7, C.Attr.Fg);
  AssertEquals('default bg', 0, C.Attr.Bg);
  AssertEquals('cell ch', 'x', C.Ch);
  AssertTrue('erased char is empty', ErasedChar = '');
end;

procedure TTuiSurfaceTest.TestSurfaceClearFillsAllCells;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(3, 2);
  try
    S.Clear(DefaultAttr);
    AssertEquals('cell 0,0 erased', '', S.CellAt(0, 0).Ch);
    AssertEquals('cell 2,1 fg', 7, S.CellAt(2, 1).Attr.Fg);
    AssertEquals('cell 2,1 bg', 0, S.CellAt(2, 1).Attr.Bg);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestPutOutsideClipIsIgnored;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(4, 4);
  try
    S.Clear(DefaultAttr);
    S.PushClip(Rc(1, 1, 2, 2));
    S.Put(0, 0, Cell('o', 7, 0));
    S.Put(1, 1, Cell('i', 7, 0));
    S.PopClip;
    AssertEquals('outside clip ignored', '', S.CellAt(0, 0).Ch);
    AssertEquals('inside clip kept', 'i', S.CellAt(1, 1).Ch);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestPushClipIntersects;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(4, 4);
  try
    S.Clear(DefaultAttr);
    S.PushClip(Rc(0, 0, 2, 2));
    S.PushClip(Rc(1, 1, 3, 3));
    S.Put(1, 1, Cell('a', 7, 0));
    S.Put(2, 2, Cell('b', 7, 0));
    S.Put(0, 0, Cell('c', 7, 0));
    S.PopClip;
    S.PopClip;
    AssertEquals('inside both clips', 'a', S.CellAt(1, 1).Ch);
    AssertEquals('outside intersect', '', S.CellAt(2, 2).Ch);
    AssertEquals('outside first clip', '', S.CellAt(0, 0).Ch);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestFillRect;
var
  S: TSurfaceMemory;
  A: TAttr;
begin
  S := TSurfaceMemory.Create(4, 4);
  try
    S.Clear(DefaultAttr);
    A := DefaultAttr;
    A.Fg := 200;
    S.FillRect(Rc(1, 1, 2, 2), A);
    AssertEquals('inside fg', 200, S.CellAt(1, 1).Attr.Fg);
    AssertEquals('inside blank glyph', '', S.CellAt(2, 2).Ch);
    AssertEquals('outside fg left', 7, S.CellAt(0, 0).Attr.Fg);
    AssertEquals('outside fg right', 7, S.CellAt(3, 3).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.Test256ColorIndexRetainedInCell;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(2, 2);
  try
    S.Clear(DefaultAttr);
    S.Put(1, 1, Cell('Z', 200, 52));
    AssertEquals('cube fg retained', 200, S.CellAt(1, 1).Attr.Fg);
    AssertEquals('cube bg retained', 52, S.CellAt(1, 1).Attr.Bg);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestFlushIdempotent;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(4, 4);
  try
    S.Clear(DefaultAttr);
    S.Flush;
    AssertEquals('first flush changes all cells', 16, S.LastFrameChangedCells);
    S.Flush;
    AssertEquals('second flush changes none', 0, S.LastFrameChangedCells);
    AssertEquals('flush counted', 2, S.FlushCount);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestInvalidateForcesFullRepaint;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(4, 4);
  try
    S.Clear(DefaultAttr);
    S.Flush;
    S.Flush;
    AssertEquals('nothing changed on an idle flush', 0,
      S.LastFrameChangedCells);
    S.Invalidate;
    S.Flush;
    AssertEquals('invalidate re-emits every cell', 16,
      S.LastFrameChangedCells);
    AssertEquals('invalidation counted', 1, S.Invalidations);
  finally
    S.Free;
  end;
end;

procedure TTuiSurfaceTest.TestDimAddsFaintButKeepsGlyphsAndColors;
var
  S: TSurfaceMemory;
  C: TCell;
begin
  S := TSurfaceMemory.Create(4, 2);
  try
    S.Clear(DefaultAttr);
    C := Cell('A', 200, 52);
    C.Attr.Style := [sfBold];
    S.Put(1, 1, C);
    S.DimRect(Rc(0, 0, 4, 2));
    AssertEquals('glyph kept', 'A', S.CellAt(1, 1).Ch);
    AssertEquals('fg kept', 200, S.CellAt(1, 1).Attr.Fg);
    AssertEquals('bg kept', 52, S.CellAt(1, 1).Attr.Bg);
    AssertTrue('dim added', sfDim in S.CellAt(1, 1).Attr.Style);
    AssertTrue('bold kept', sfBold in S.CellAt(1, 1).Attr.Style);
    AssertTrue('blank cell dimmed too', sfDim in S.CellAt(0, 0).Attr.Style);
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TTuiSurfaceTest);
end.
