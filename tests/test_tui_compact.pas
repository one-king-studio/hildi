unit test_tui_compact;
{ fpcunit tests for hildegard.helper.tui.compact: trimming blank edges and
  eliding long content to head + '...' + tail. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.compact;

type
  TCompactTest = class(TTestCase)
  private
    function Lines(const A: array of string): UnicodeString;
  published
    procedure TestShortTextIsUnchanged;
    procedure TestTenLinesIsUnchanged;
    procedure TestElevenLinesElides;
    procedure TestLongTextKeepsFirstTwoAndLastThree;
    procedure TestTrimsBlankEdges;
    procedure TestTrimsWhitespaceOnlyEdges;
    procedure TestPreservesInteriorBlanks;
    procedure TestEmptyText;
    procedure TestCustomOptions;
    procedure TestTailKeepsTheEnd;
    procedure TestTailShortTextUnchanged;
    procedure TestTailTrimsBlankEdges;
  end;

implementation

function TCompactTest.Lines(const A: array of string): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + UnicodeString(A[I]);
  end;
end;

procedure TCompactTest.TestShortTextIsUnchanged;
begin
  AssertEquals('three lines unchanged', Lines(['a', 'b', 'c']),
    CompactLines(Lines(['a', 'b', 'c']), DefaultCompactOptions));
end;

procedure TCompactTest.TestTenLinesIsUnchanged;
begin
  AssertEquals('ten lines unchanged',
    Lines(['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']),
    CompactLines(Lines(['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']),
      DefaultCompactOptions));
end;

procedure TCompactTest.TestElevenLinesElides;
begin
  AssertEquals('eleven lines elide',
    Lines(['1', '2', '...', '9', '10', '11']),
    CompactLines(Lines(['1', '2', '3', '4', '5', '6', '7', '8', '9', '10',
      '11']), DefaultCompactOptions));
end;

procedure TCompactTest.TestLongTextKeepsFirstTwoAndLastThree;
begin
  AssertEquals('twelve lines elide',
    Lines(['L1', 'L2', '...', 'L10', 'L11', 'L12']),
    CompactLines(Lines(['L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8', 'L9',
      'L10', 'L11', 'L12']), DefaultCompactOptions));
end;

procedure TCompactTest.TestTrimsBlankEdges;
begin
  AssertEquals('blank edges gone', Lines(['a', 'b']),
    CompactLines(Lines(['', '', 'a', 'b', '', '']), DefaultCompactOptions));
end;

procedure TCompactTest.TestTrimsWhitespaceOnlyEdges;
begin
  AssertEquals('whitespace-only edges gone', Lines(['a', 'b']),
    CompactLines(Lines(['   ', #9, 'a', 'b', '  ']), DefaultCompactOptions));
end;

procedure TCompactTest.TestPreservesInteriorBlanks;
begin
  AssertEquals('interior blank kept', Lines(['a', '', 'b']),
    CompactLines(Lines(['a', '', 'b']), DefaultCompactOptions));
end;

procedure TCompactTest.TestEmptyText;
begin
  AssertEquals('empty stays empty', UnicodeString(''),
    CompactLines('', DefaultCompactOptions));
  AssertEquals('blank-only stays empty', UnicodeString(''),
    CompactLines(#10 + '  ' + #10, DefaultCompactOptions));
end;

procedure TCompactTest.TestCustomOptions;
var
  Opts: TCompactOptions;
begin
  Opts := DefaultCompactOptions;
  Opts.MaxLines := 4;
  Opts.HeadLines := 1;
  Opts.TailLines := 1;
  AssertEquals('custom elision', Lines(['1', '...', '5']),
    CompactLines(Lines(['1', '2', '3', '4', '5']), Opts));
end;

procedure TCompactTest.TestTailKeepsTheEnd;
begin
  AssertEquals('last two lines behind an ellipsis',
    Lines(['...', '4', '5']),
    TailLines(Lines(['1', '2', '3', '4', '5']), 2));
end;

procedure TCompactTest.TestTailShortTextUnchanged;
begin
  AssertEquals('short text unchanged', Lines(['1', '2']),
    TailLines(Lines(['1', '2']), 6));
end;

procedure TCompactTest.TestTailTrimsBlankEdges;
begin
  AssertEquals('blank edges trimmed', Lines(['a', 'b']),
    TailLines(Lines(['', 'a', 'b', '']), 6));
end;

initialization
  RegisterTest(TCompactTest);

end.
