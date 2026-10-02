unit test_tui_encoder;
{ fpcunit tests for hildegard.helper.tui.encoder: the pure frame-diff encoder
  that replaces FPC video's UpdateScreen. Byte-level assertions, no terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.encoder;

type
  TTuiEncoderTest = class(TTestCase)
  private
    function Cell(const ACh: UnicodeString; AFg: Byte = 7): TCell;
    function WideCell: TCell;
    function Contains(const AHaystack: RawByteString;
      const ANeedle: RawByteString): Boolean;
  published
    procedure TestNoChangeEmitsNothing;
    procedure TestChangedCellMovesAndDraws;
    procedure TestForceEmitsUnchangedCells;
    procedure TestEachChangedCellIsPositioned;
    procedure TestAttrChangeEmitsSgr;
    procedure TestScreenBgUsesAppBackground;
    procedure TestExplicitBgEmitsPalette;
    procedure TestWideClusterIsEmitted;
    procedure TestWideClusterAtRightEdgeBecomesSpace;
    procedure TestRemovingWideClusterEmitsLead;
    procedure TestControlCharsSanitized;
    procedure TestOverflowColumnErasesToEndOfLine;
    procedure TestOverflowColumnEmptyForNoRows;
    procedure TestClearDisplayErasesWholeScreen;
  end;

implementation

function TTuiEncoderTest.Cell(const ACh: UnicodeString; AFg: Byte): TCell;
begin
  Result := Default(TCell);
  Result.Ch := ACh;
  Result.Attr.Fg := AFg;
  Result.Attr.Bg := 0;
  Result.Attr.Style := [];
end;

function TTuiEncoderTest.WideCell: TCell;
begin
  { U+4E16 is East Asian Wide: two columns. }
  Result := Cell(UnicodeString(WideChar($4E16)));
end;

function TTuiEncoderTest.Contains(const AHaystack: RawByteString;
  const ANeedle: RawByteString): Boolean;
begin
  Result := Pos(ANeedle, AHaystack) > 0;
end;

procedure TTuiEncoderTest.TestNoChangeEmitsNothing;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 2);
    SetLength(Cur, 2);
    Prev[0] := Cell('a');
    Cur[0] := Cell('a');
    AssertEquals('no bytes', 0, Length(Enc.Encode(Prev, Cur, 2, 1, False)));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestChangedCellMovesAndDraws;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 2);
    SetLength(Cur, 2);
    Cur[1] := Cell('A');
    OutBytes := Enc.Encode(Prev, Cur, 2, 1, False);
    AssertTrue('moves to row 1 col 2', Contains(OutBytes, #27'[1;2H'));
    AssertTrue('draws A', Contains(OutBytes, 'A'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestForceEmitsUnchangedCells;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 1);
    SetLength(Cur, 1);
    Prev[0] := Cell('x');
    Cur[0] := Cell('x');
    AssertTrue('force emits the cell',
      Contains(Enc.Encode(Prev, Cur, 1, 1, True), 'x'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestEachChangedCellIsPositioned;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
  I, Moves: Integer;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 3);
    SetLength(Cur, 3);
    Cur[0] := Cell('A');
    Cur[1] := Cell('B');
    OutBytes := Enc.Encode(Prev, Cur, 3, 1, False);
    Moves := 0;
    for I := 1 to Length(OutBytes) do
      if OutBytes[I] = 'H' then
        Inc(Moves);
    { Absolute positioning per cell: no reliance on the terminal's cursor. }
    AssertEquals('one cursor move per changed cell', 2, Moves);
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestAttrChangeEmitsSgr;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 1);
    SetLength(Cur, 1);
    Cur[0] := Cell('a', 200);
    OutBytes := Enc.Encode(Prev, Cur, 1, 1, False);
    AssertTrue('256-colour foreground', Contains(OutBytes, '38;5;200'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestScreenBgUsesAppBackground;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 1);
    SetLength(Cur, 1);
    Cur[0] := Cell('a', 200);
    Cur[0].Attr.Style := [sfScreenBg];
    Enc.SetScreenBg(234);
    OutBytes := Enc.Encode(Prev, Cur, 1, 1, False);
    AssertTrue('paints the app screen background', Contains(OutBytes, '48;5;234'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestExplicitBgEmitsPalette;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 1);
    SetLength(Cur, 1);
    Cur[0] := Cell('a', 200);
    Cur[0].Attr.Bg := 52;
    OutBytes := Enc.Encode(Prev, Cur, 1, 1, False);
    AssertTrue('palette background', Contains(OutBytes, '48;5;52'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestWideClusterIsEmitted;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 3);
    SetLength(Cur, 3);
    Cur[0] := WideCell;
    Cur[2] := Cell('B');
    OutBytes := Enc.Encode(Prev, Cur, 3, 1, False);
    AssertTrue('wide cluster bytes', Contains(OutBytes, UTF8Encode(
      UnicodeString(WideChar($4E16)))));
    AssertTrue('following cell drawn', Contains(OutBytes, 'B'));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestWideClusterAtRightEdgeBecomesSpace;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 3);
    SetLength(Cur, 3);
    Cur[2] := WideCell;      { last column of a 3-wide frame }
    OutBytes := Enc.Encode(Prev, Cur, 3, 1, False);
    AssertFalse('wide cluster not drawn at the edge',
      Contains(OutBytes, UTF8Encode(UnicodeString(WideChar($4E16)))));
    AssertTrue('a space is drawn instead', Contains(OutBytes, ' '));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestRemovingWideClusterEmitsLead;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 3);
    SetLength(Cur, 3);
    Prev[0] := WideCell;
    { Cur[0] is blank: the lead must be re-emitted so the terminal clears the
      wide glyph's cells. }
    OutBytes := Enc.Encode(Prev, Cur, 3, 1, False);
    AssertTrue('moves back to the first cell', Contains(OutBytes, #27'[1;1H'));
    AssertTrue('writes a blank', Contains(OutBytes, ' '));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestControlCharsSanitized;
var
  Enc: TCellEncoder;
  Prev, Cur: array of TCell;
  OutBytes: RawByteString;
begin
  Enc := TCellEncoder.Create;
  try
    SetLength(Prev, 1);
    SetLength(Cur, 1);
    { An escape sequence arriving as cell content must not reach the terminal. }
    Cur[0] := Cell(UnicodeString(#27'[2J'));
    OutBytes := Enc.Encode(Prev, Cur, 1, 1, False);
    AssertFalse('clear-screen escape not emitted',
      Contains(OutBytes, #27'[2J'));
    AssertTrue('replacement char shown',
      Contains(OutBytes, UTF8Encode(WideChar($FFFD))));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestOverflowColumnErasesToEndOfLine;
var
  Enc: TCellEncoder;
  OutBytes: RawByteString;
  I, Erases: Integer;
begin
  Enc := TCellEncoder.Create;
  try
    OutBytes := Enc.ClearOverflowColumn(3, 2, DefaultAttr);
    { Row 0, column 4 (1-based), then EL; then row 1, column 4, then EL. }
    AssertTrue('positions row 1 at the overflow column',
      Contains(OutBytes, #27'[1;4H'));
    AssertTrue('positions row 2 at the overflow column',
      Contains(OutBytes, #27'[2;4H'));
    Erases := 0;
    for I := 1 to Length(OutBytes) - 2 do
      if Copy(OutBytes, I, 3) = #27'[K' then
        Inc(Erases);
    AssertEquals('one erase per row', 2, Erases);
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestOverflowColumnEmptyForNoRows;
var
  Enc: TCellEncoder;
begin
  Enc := TCellEncoder.Create;
  try
    AssertEquals('no rows, no bytes', 0,
      Length(Enc.ClearOverflowColumn(3, 0, DefaultAttr)));
    AssertEquals('negative column, no bytes', 0,
      Length(Enc.ClearOverflowColumn(-1, 5, DefaultAttr)));
  finally
    Enc.Free;
  end;
end;

procedure TTuiEncoderTest.TestClearDisplayErasesWholeScreen;
var
  Enc: TCellEncoder;
begin
  Enc := TCellEncoder.Create;
  try
    AssertTrue('erases the display', Contains(Enc.ClearDisplay(DefaultAttr),
      #27'[2J'));
  finally
    Enc.Free;
  end;
end;

initialization
  RegisterTest(TTuiEncoderTest);

end.
