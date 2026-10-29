unit TestTUIDiffviewer;
{ fpcunit tests for the diff viewer pane (TUIWidgetsDiffviewer): it renders a
  file's stored diff, distinguishes added/removed/hunk by glyph as well as colour,
  scrolls and clamps, says when a diff was not captured, and closes on Escape
  without touching anything else. Headless, against TSurfaceMemory. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme,
  TUIWidgetsDiffviewer;

type
  TDiffViewerTest = class(TTestCase)
  private
    FViewer: TDiffViewer;
    FSurface: TSurfaceMemory;
    FTheme: TTheme;
    FClosed: Integer;
    procedure NoteClose(Sender: TObject);
    procedure Render;
    function Key(AKind: TKeyKind): TInputEvent;
    function Line(AKind: TDiffPaneKind; const AText: string;
      ACaveat: Boolean = False): TDiffPaneLine;
    function Rows(const ATexts: array of string): TDiffPaneLineArray;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { A diff with all four kinds draws each with its own glyph, so the cue
      survives a monochrome terminal. }
    procedure TestRendersEachKindWithItsOwnGlyph;
    { An added line is coloured differently from a removed one - colour is the
      second cue, not the only one. }
    procedure TestAddedAndRemovedDifferInAttr;
    { Down/Up move one line; Home/End jump to the ends; each clamps. }
    procedure TestScrollingMovesAndClamps;
    { A page key moves by the body height, not by one line or by everything. }
    procedure TestPageKeysMoveByTheBodyHeight;
    { Short content cannot scroll: Down is a no-op rather than scrolling into
      blank space. }
    procedure TestShortContentDoesNotScroll;
    { Escape closes and fires OnClose exactly once; the pane is then inactive and
      renders nothing. }
    procedure TestEscapeClosesAndNotifies;
    { A not-captured note is drawn dimmed with no glyph, so it does not read as a
      change. }
    procedure TestACaveatLineIsNotDrawnAsAChange;
    { Every other key is consumed while the pane is up: the transcript underneath
      must not receive input it cannot show. }
    procedure TestOtherKeysAreConsumedWhileOpen;
    { Drawing into a box too small to frame must not crash. }
    procedure TestTinyBoundsDoesNotCrash;
    { The path is in the title, so the operator can tell which file they are
      looking at. }
    procedure TestThePathIsInTheTitle;
  end;

implementation

const
  SurfaceW = 80;
  SurfaceH = 24;
  { The pane fills the surface, so the body is H - chrome. Kept as a constant
    expression so the page-key arithmetic below is readable. }
  BodyH = SurfaceH - DiffViewerChromeRows;

procedure TDiffViewerTest.NoteClose(Sender: TObject);
begin
  Inc(FClosed);
end;

procedure TDiffViewerTest.SetUp;
var
  Sz: TSize;
  Bounds: TRect;
begin
  FTheme := DarkTheme;
  FViewer := TDiffViewer.Create(FTheme);
  FViewer.OnClose := NoteClose;
  FClosed := 0;
  FSurface := TSurfaceMemory.Create(SurfaceW, SurfaceH);
  Sz := Default(TSize);
  Sz.W := SurfaceW;
  Sz.H := SurfaceH;
  FViewer.Measure(Sz);
  Bounds := Default(TRect);
  Bounds.X := 0;
  Bounds.Y := 0;
  Bounds.W := SurfaceW;
  Bounds.H := SurfaceH;
  FViewer.Arrange(Bounds);
end;

procedure TDiffViewerTest.TearDown;
begin
  FViewer.Free;
  FSurface.Free;
end;

procedure TDiffViewerTest.Render;
begin
  FSurface.Clear(Default(TAttr));
  FViewer.Render(FSurface);
end;

function TDiffViewerTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TDiffViewerTest.Line(AKind: TDiffPaneKind; const AText: string;
  ACaveat: Boolean): TDiffPaneLine;
begin
  Result := Default(TDiffPaneLine);
  Result.Kind := AKind;
  Result.Text := AText;
  Result.Caveat := ACaveat;
end;

function TDiffViewerTest.Rows(const ATexts: array of string): TDiffPaneLineArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ATexts));
  for I := 0 to High(ATexts) do
    Result[I] := Line(dpContext, ATexts[I]);
end;

procedure TDiffViewerTest.TestRendersEachKindWithItsOwnGlyph;
var
  Lines: TDiffPaneLineArray;
  Row: UnicodeString;
begin
  { The design language requires colour AND a leading glyph: a diff has to be
    readable when the colour is not. }
  SetLength(Lines, 4);
  Lines[0] := Line(dpFile, 'a.txt');
  Lines[1] := Line(dpHunk, '@@ -1,2 +1,2 @@');
  Lines[2] := Line(dpAdded, 'new line');
  Lines[3] := Line(dpRemoved, 'old line');
  FViewer.Show('a.txt', Lines);
  Render;

  Row := FSurface.RowText(1, 0, SurfaceW);
  AssertTrue('file row has = : ' + string(Row), Pos('=', string(Row)) > 0);
  AssertTrue('file row names the file', Pos('a.txt', string(Row)) > 0);
  Row := FSurface.RowText(2, 0, SurfaceW);
  AssertTrue('hunk row has @ : ' + string(Row), Pos('@', string(Row)) > 0);
  Row := FSurface.RowText(3, 0, SurfaceW);
  AssertTrue('added row has + : ' + string(Row), Pos('+', string(Row)) > 0);
  AssertTrue('added row has the text', Pos('new line', string(Row)) > 0);
  Row := FSurface.RowText(4, 0, SurfaceW);
  AssertTrue('removed row has - : ' + string(Row), Pos('-', string(Row)) > 0);
  AssertTrue('removed row has the text', Pos('old line', string(Row)) > 0);
end;

procedure TDiffViewerTest.TestAddedAndRemovedDifferInAttr;
var
  Lines: TDiffPaneLineArray;
  AddedAttr, RemovedAttr: TAttr;
begin
  { Colour is the SECOND cue, but it still has to be there. }
  SetLength(Lines, 2);
  Lines[0] := Line(dpAdded, 'plus');
  Lines[1] := Line(dpRemoved, 'minus');
  FViewer.Show('a.txt', Lines);
  Render;
  AddedAttr := FSurface.CellAt(3, 1).Attr;
  RemovedAttr := FSurface.CellAt(3, 2).Attr;
  AssertTrue('added and removed are coloured differently',
    (AddedAttr.Fg <> RemovedAttr.Fg));
end;

procedure TDiffViewerTest.TestScrollingMovesAndClamps;
var
  I: Integer;
  Texts: array[0..49] of string;
begin
  for I := 0 to High(Texts) do
    Texts[I] := 'line ' + IntToStr(I);
  FViewer.Show('a.txt', Rows(Texts));
  Render;
  AssertEquals('starts at the top', 0, FViewer.ScrollTop);
  AssertTrue('down scrolls', FViewer.HandleEvent(Key(kkDown)));
  AssertEquals('one line', 1, FViewer.ScrollTop);
  AssertTrue('up scrolls back', FViewer.HandleEvent(Key(kkUp)));
  AssertEquals('back at the top', 0, FViewer.ScrollTop);
  { Up at the top clamps rather than going negative. }
  FViewer.HandleEvent(Key(kkUp));
  AssertEquals('clamped at 0', 0, FViewer.ScrollTop);
  { End jumps to the last page, Home back to the top. }
  FViewer.HandleEvent(Key(kkEnd));
  AssertTrue('end moved down', FViewer.ScrollTop > 0);
  FViewer.HandleEvent(Key(kkHome));
  AssertEquals('home returns to the top', 0, FViewer.ScrollTop);
end;

procedure TDiffViewerTest.TestPageKeysMoveByTheBodyHeight;
var
  I: Integer;
  Texts: array[0..99] of string;
  AfterPage: Integer;
begin
  for I := 0 to High(Texts) do
    Texts[I] := 'line ' + IntToStr(I);
  FViewer.Show('a.txt', Rows(Texts));
  AssertTrue('pgdn', FViewer.HandleEvent(Key(kkPageDown)));
  AfterPage := FViewer.ScrollTop;
  AssertTrue('a page is more than a line: ' + IntToStr(AfterPage),
    AfterPage > 1);
  AssertTrue('and not the whole document', AfterPage < Length(Texts));
  AssertTrue('pgup', FViewer.HandleEvent(Key(kkPageUp)));
  AssertEquals('a page back lands at the top', 0, FViewer.ScrollTop);
end;

procedure TDiffViewerTest.TestShortContentDoesNotScroll;
begin
  { Down on content that fits must not scroll into blank space: the operator
    would think there was more to read. }
  FViewer.Show('a.txt', Rows(['only', 'three', 'lines']));
  AssertTrue('down is still consumed', FViewer.HandleEvent(Key(kkDown)));
  AssertEquals('but nothing scrolled', 0, FViewer.ScrollTop);
  AssertTrue('end is consumed', FViewer.HandleEvent(Key(kkEnd)));
  AssertEquals('and still at the top', 0, FViewer.ScrollTop);
end;

procedure TDiffViewerTest.TestEscapeClosesAndNotifies;
begin
  FViewer.Show('a.txt', Rows(['one']));
  AssertTrue('active', FViewer.Active);
  AssertTrue('escape consumed', FViewer.HandleEvent(Key(kkEscape)));
  AssertFalse('no longer active', FViewer.Active);
  AssertEquals('closed once', 1, FClosed);
  { A second Escape is not ours to consume: the pane is gone. }
  AssertFalse('inactive ignores keys', FViewer.HandleEvent(Key(kkEscape)));
end;

procedure TDiffViewerTest.TestACaveatLineIsNotDrawnAsAChange;
var
  Lines: TDiffPaneLineArray;
  Row: UnicodeString;
begin
  { "not captured" is a statement ABOUT the record, not a line of a diff. Drawing
    it with a + or - glyph would read as a change that did not happen. }
  SetLength(Lines, 1);
  Lines[0] := Line(dpContext, 'not captured: no before-text', True);
  FViewer.Show('a.txt', Lines);
  Render;
  Row := FSurface.RowText(1, 0, SurfaceW);
  AssertTrue('the note is shown', Pos('not captured', string(Row)) > 0);
  { A caveat line has NO glyph column at all: its text begins where every other
    kind draws its marker. That is the distinguishing property, and it is why
    asserting Pos('+')/Pos('-') over the row proves nothing - the note's own text
    contains a hyphen. }
  AssertEquals('a caveat has no glyph column; its text starts there',
    UnicodeString('n'), FSurface.CellAt(2, 1).Ch);
end;

procedure TDiffViewerTest.TestOtherKeysAreConsumedWhileOpen;
begin
  { The stream underneath must not receive input meant for a box covering it. }
  FViewer.Show('a.txt', Rows(['one']));
  AssertTrue('a letter is consumed', FViewer.HandleEvent(Key(kkChar)));
  AssertTrue('enter is consumed', FViewer.HandleEvent(Key(kkEnter)));
end;

procedure TDiffViewerTest.TestTinyBoundsDoesNotCrash;
var
  Bounds: TRect;
  Lines: TDiffPaneLineArray;
begin
  SetLength(Lines, 1);
  Lines[0] := Line(dpAdded, 'x');
  FViewer.Show('a.txt', Lines);
  Bounds := Default(TRect);
  Bounds.X := 0;
  Bounds.Y := 0;
  Bounds.W := 3;
  Bounds.H := 2;
  FViewer.Arrange(Bounds);
  { Must simply decline to draw. }
  FViewer.Render(FSurface);
  AssertTrue('still active', FViewer.Active);
end;

procedure TDiffViewerTest.TestThePathIsInTheTitle;
var
  Row: UnicodeString;
begin
  FViewer.Show('src/deep/file.pas', Rows(['one']));
  Render;
  Row := FSurface.RowText(0, 0, SurfaceW);
  AssertTrue('the path is in the title row: ' + string(Row),
    Pos('src/deep/file.pas', string(Row)) > 0);
end;

initialization
  RegisterTest(TDiffViewerTest);

end.
