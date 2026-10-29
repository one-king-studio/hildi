unit TestTUIFileviewer;
{ Tests for TUIWidgetsFileviewer.

  The four requirements from the spec, each asserted: it reads a markdown file, it
  reads a plain file, a missing file DRAWS AN ERROR rather than raising, and an
  oversized file TRUNCATES with a notice rather than refusing. Plus the scroll
  clamp, which is what stops a viewer scrolling past its own end. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  TUIBase, TUIWidget, TUIInput, TUISurface,
  TUIWidgetsFileviewer;

type
  TFileViewerTest = class(TTestCase)
  private
    FTempDir: string;
    function WriteTemp(const AName: string; const AContent: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestKindByExtension;
    procedure TestPlainFileRendersLines;
    procedure TestMarkdownFileRendersBlocks;
    procedure TestMarkdownIsUnstyledPlainLines;
    procedure TestMissingFileDrawsAnErrorNotARaises;
    procedure TestUnreadablePathDrawsAnError;
    procedure TestOversizedFileTruncatesWithANotice;
    procedure TestEmptyFileRendersNothing;
    procedure TestScrollIsClampedToContent;
    procedure TestScrollKeys;
    procedure TestResizeRewraps;
    procedure TestWrapsLongLines;
    procedure TestNonNavigationKeysAreConsumed;
    procedure TestReloadKeepsPlace;
  end;

implementation

const
  Width = 40;
  Height = 6;

{ TUIBase's TRect is X,Y,W,H; Classes also has a Rect, so build it explicitly
  rather than relying on which one is in scope. }
function Pane(AW, AH: Integer): TRect;
begin
  Result.X := 0;
  Result.Y := 0;
  Result.W := AW;
  Result.H := AH;
end;

procedure TFileViewerTest.SetUp;
begin
  FTempDir := GetTempDir(False) + 'mdviewer-' + IntToHex(Random(MaxInt), 8);
  ForceDirectories(FTempDir);
end;

procedure TFileViewerTest.TearDown;
var
  SR: TSearchRec;
begin
  if FindFirst(FTempDir + PathDelim + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        DeleteFile(FTempDir + PathDelim + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(FTempDir);
end;

function TFileViewerTest.WriteTemp(const AName: string;
  const AContent: string): string;
var
  F: TFileStream;
begin
  Result := FTempDir + PathDelim + AName;
  F := TFileStream.Create(Result, fmCreate);
  try
    if AContent <> '' then
      F.WriteBuffer(AContent[1], Length(AContent));
  finally
    F.Free;
  end;
end;

procedure TFileViewerTest.TestKindByExtension;
begin
  AssertTrue('.md', KindOfPath('a.md') = fvMarkdown);
  AssertTrue('.markdown', KindOfPath('a.markdown') = fvMarkdown);
  AssertTrue('case-insensitive', KindOfPath('A.MD') = fvMarkdown);
  AssertTrue('.txt is plain', KindOfPath('a.txt') = fvPlain);
  { The spec names this case: an icon must show as text, not as an error and not
    as a blank pane. }
  AssertTrue('.ico is plain', KindOfPath('favicon.ico') = fvPlain);
  AssertTrue('no extension', KindOfPath('README') = fvPlain);
end;

procedure TFileViewerTest.TestPlainFileRendersLines;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('a.txt', 'first' + #10 + 'second' + #10 + 'third'));
    AssertTrue('a plain kind', V.Kind = fvPlain);
    AssertEquals('no error', '', V.ErrorText);
    AssertTrue('lines were produced', V.LineCount >= 3);
    AssertEquals('line 0', 'first', V.LineAt(0));
    AssertEquals('line 1', 'second', V.LineAt(1));
    AssertEquals('line 2', 'third', V.LineAt(2));
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestMarkdownFileRendersBlocks;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('a.md', '# Heading' + #10 + #10 + 'A paragraph.'));
    AssertTrue('a markdown kind', V.Kind = fvMarkdown);
    AssertEquals('no error', '', V.ErrorText);
    { The heading's TEXT reaches the viewer: rendering is plain by design in v1,
      but the content must be there. }
    AssertTrue('the heading is drawn', Pos('Heading', V.LineAt(0)) > 0);
    AssertTrue('and the paragraph', V.LineCount >= 2);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestMarkdownIsUnstyledPlainLines;
var
  V: TFileViewer;
begin
  { ponytail ceiling, asserted so it is deliberate rather than forgotten: the v1
    viewer renders markdown as PLAIN text. The marker characters are not
    reproduced, which is the difference between "rendered" and "raw". }
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('b.md', 'an **emphatic** word'));
    { My first version asserted 'plain bold text', whose own word 'bold' made the
      failure message ambiguous; this input makes the markup unmistakable. }
    AssertEquals('the emphasis markers are gone', 'an emphatic word', V.LineAt(0));
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestMissingFileDrawsAnErrorNotARaises;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    { Must not raise: a viewer that cannot open a file has to draw SOMETHING. }
    V.Open(FTempDir + PathDelim + 'does-not-exist.txt');
    AssertTrue('an error is reported', V.ErrorText <> '');
    AssertTrue('it names the file', Pos('does-not-exist.txt', V.ErrorText) > 0);
    { And it is drawable content, not a blank pane. }
    AssertEquals('one line of error', 1, V.LineCount);
    AssertTrue('the error is the line', Pos('cannot open', V.LineAt(0)) > 0);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestUnreadablePathDrawsAnError;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    { A DIRECTORY is not readable as a file; the viewer must say so rather than
      raising EStreamError out of Open. }
    V.Open(FTempDir);
    AssertTrue('an error is reported', V.ErrorText <> '');
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestOversizedFileTruncatesWithANotice;
var
  V: TFileViewer;
  Big: string;
begin
  V := TFileViewer.Create;
  try
    { 2000 bytes of content, read with a 100-byte cap. }
    Big := StringOfChar('x', 2000);
    V.MaxBytes := 100;
    V.Open(WriteTemp('big.txt', Big));
    AssertTrue('reported as truncated', V.Truncated);
    AssertEquals('no error: truncation is not failure', '', V.ErrorText);
    { It loaded the cap, not the whole file and not nothing. }
    AssertTrue('some content is shown', V.LineCount >= 1);
    AssertTrue('bounded by the cap', Length(V.LineAt(0)) <= 200);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestEmptyFileRendersNothing;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('empty.txt', ''));
    AssertEquals('no error', '', V.ErrorText);
    AssertEquals('no lines', 0, V.LineCount);
    AssertEquals('no scroll', 0, V.ScrollY);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestScrollIsClampedToContent;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('short.txt', 'one' + #10 + 'two'));
    V.Arrange(Pane(Width, Height));
    { Two lines in a six-row view: there is nothing to scroll. }
    V.ScrollBy(10);
    AssertEquals('clamped at 0 when content fits', 0, V.ScrollY);
    V.ScrollTo(-5);
    AssertEquals('never negative', 0, V.ScrollY);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestScrollKeys;
var
  V: TFileViewer;
  E: TInputEvent;
  I: Integer;
  Many: string;
begin
  V := TFileViewer.Create;
  try
    Many := '';
    for I := 1 to 40 do
      Many := Many + 'line ' + IntToStr(I) + #10;
    V.Open(WriteTemp('many.txt', Many));
    V.Arrange(Pane(Width, Height));

    FillChar(E, SizeOf(E), 0);
    E.Kind := ikKey;
    E.Key.Kind := kkDown;
    V.HandleEvent(E);
    AssertEquals('one line down', 1, V.ScrollY);

    E.Key.Kind := kkPageDown;
    V.HandleEvent(E);
    AssertEquals('a page down', 1 + Height, V.ScrollY);

    E.Key.Kind := kkEnd;
    V.HandleEvent(E);
    AssertTrue('scrolled to the end region', V.ScrollY > 20);

    E.Key.Kind := kkHome;
    V.HandleEvent(E);
    AssertEquals('home', 0, V.ScrollY);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestResizeRewraps;
var
  V: TFileViewer;
  Before: Integer;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('wrap.txt', StringOfChar('a', 100)));
    V.Arrange(Pane(100, 10));
    Before := V.LineCount;
    AssertEquals('one line at width 100', 1, Before);
    V.Arrange(Pane(20, 10));
    AssertTrue('more lines after narrowing', V.LineCount > Before);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestWrapsLongLines;
var
  V: TFileViewer;
begin
  V := TFileViewer.Create;
  try
    { Width is DISPLAY CELLS, so a wrapped line must not exceed the pane. }
    V.Open(WriteTemp('w.txt', StringOfChar('b', 90)));
    V.Arrange(Pane(30, 10));
    AssertTrue('wrapped into several lines', V.LineCount >= 3);
    AssertTrue('no line overflows the pane',
      Length(V.LineAt(0)) <= 30);
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestNonNavigationKeysAreConsumed;
var
  V: TFileViewer;
  E: TInputEvent;
begin
  V := TFileViewer.Create;
  try
    V.Open(WriteTemp('k.txt', 'x'));
    V.Arrange(Pane(Width, Height));
    FillChar(E, SizeOf(E), 0);
    E.Kind := ikKey;
    E.Key.Kind := kkChar;
    E.Key.Ch := 'q';
    { Consumed: the transcript underneath must not receive input it cannot show. }
    AssertTrue('the key is consumed', V.HandleEvent(E));
  finally
    V.Free;
  end;
end;

procedure TFileViewerTest.TestReloadKeepsPlace;
var
  V: TFileViewer;
  P: string;
  I: Integer;
  Many: string;
begin
  V := TFileViewer.Create;
  try
    Many := '';
    for I := 1 to 40 do
      Many := Many + 'line ' + IntToStr(I) + #10;
    P := WriteTemp('r.txt', Many);
    V.Open(P);
    V.Arrange(Pane(Width, Height));
    V.ScrollTo(10);
    V.Reload;
    AssertEquals('the reader keeps their place', 10, V.ScrollY);
  finally
    V.Free;
  end;
end;

initialization
  RegisterTest(TFileViewerTest);

end.
