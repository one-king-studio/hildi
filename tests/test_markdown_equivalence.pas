unit test_markdown_equivalence;
{ Batch and streamed parses must produce the SAME tree.

  This is the property the markdown module exists to have, and it is asserted
  against a corpus of documents rather than one, because the failures that
  matter live at block seams: a fence containing `---`, a table that starts on
  the line after a list item, a setext underline under a paragraph, a loose
  list, a quote that survives a blank line.

  Why this test exists BEFORE the module was extracted (see
  docs/features/Markdown_Viewer/Markdown_v1.TODO.md, Phase 0): once the scanners
  move, a disagreement between batch and streamed is ambiguous - was it always
  broken, or did the move break it? Asserted here first, every later failure has
  a single attribution.

  What "identical" means here is deliberately literal: a flat textual rendering
  of every field of every block, compared byte for byte (see TreeSummary). Same
  block count, same kinds, same levels, same span text/styles/links, in order.
  A structural compare that ignored a field would pass while the field drifted.

  Two limitations, both deliberate and both worth knowing:

  1. CHUNKING IS BY CODEPOINT, NOT BY BYTE. A chunk of 1 means one character.
     Splitting a multi-byte UTF-8 sequence across two Append calls is therefore
     not exercised, and the parser cannot handle it today: `Feed` keeps the
     unconsumed tail in a UnicodeString (`FPartial`), so a half-sequence is
     already mangled by the time it is buffered. That is a real hazard for a
     socket that chunks arbitrarily, but it is a change to the parser's
     buffering, not a property this refactor can preserve - fix it deliberately
     if a transport ever splits codepoints, and this test will then be the place
     to pin it.

  2. THE SUMMARY IS BUILT AS UTF-8 (`UTF8Encode`), never via an implicit
     UnicodeString -> string conversion. That is not cosmetic: on this build the
     implicit conversion writes '?' for non-ASCII (see AGENTS.md), so a lossy
     summary would let `caf\u00e9` and `caf?` compare equal and hide exactly the
     corruption the unicode document is here to catch. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.parse;

type
  TMdEquivalenceTest = class(TTestCase)
  private
    { Every corpus document, sorted, as full relative paths. }
    function CorpusDir: string;
    procedure CollectDocs(AList: TStringList);
    { A flat, field-by-field rendering of the tree. Two equal summaries mean two
      equal trees; an unequal pair names the field that moved. }
    function TreeSummary(const ABlocks: TMdBlockArray): string;
    function StylesKey(const AStyles: TMdInlineStyles): string;
    function AlignKey(AAlign: TMdAlign): string;
    function RowSummary(const ARow: TMdTableRow): string;
    { Parse the whole text in one Append. }
    function BatchParse(const AText: string): TMdBlockArray;
    { Push the text through Append in chunks of AChunkCodepoints, then Finish. }
    function StreamParse(const AText: string; AChunkCodepoints: Integer): TMdBlockArray;
    { Load a document as the same `string` both paths receive. }
    function LoadDoc(const APath: string): string;
  published
    { Guards the whole suite: a missing or empty corpus would make every
      assertion below vacuously true. }
    procedure TestCorpusIsPresent;
    procedure TestEveryDocumentProducesBlocks;
    procedure TestBatchAndStreamingAgreeAtEveryChunkSize;
  end;

implementation

const
  { The chunk sizes the spec names (SPEC §7.2, and the completion criteria).
    Zero means "one Append of the whole document", which is the degenerate
    streamed case: it proves Append alone is not the difference. }
  ChunkSizes: array[0..4] of Integer = (0, 1, 7, 64, 997);
  MinDocuments = 12;

function U8(const S: UnicodeString): string;
begin
  { Explicit: the implicit conversion is lossy for non-ASCII on this build. }
  Result := UTF8Encode(S);
end;

function TMdEquivalenceTest.CorpusDir: string;
begin
  Result := 'tests/data/md_corpus';
end;

procedure TMdEquivalenceTest.CollectDocs(AList: TStringList);
var
  SR: TSearchRec;
  Mask: string;
begin
  AList.Clear;
  Mask := CorpusDir + PathDelim + '*.md';
  if FindFirst(Mask, faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        AList.Add(CorpusDir + PathDelim + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  AList.Sort;
end;

function TMdEquivalenceTest.StylesKey(const AStyles: TMdInlineStyles): string;
var
  S: TMdInlineStyle;
begin
  Result := '{';
  for S := Low(TMdInlineStyle) to High(TMdInlineStyle) do
    if S in AStyles then
      Result := Result + IntToStr(Ord(S)) + ',';
  Result := Result + '}';
end;

function TMdEquivalenceTest.AlignKey(AAlign: TMdAlign): string;
begin
  case AAlign of
    maNone: Result := '-';
    maLeft: Result := 'l';
    maCenter: Result := 'c';
    maRight: Result := 'r';
  end;
end;

function TMdEquivalenceTest.RowSummary(const ARow: TMdTableRow): string;
var
  I, J: Integer;
begin
  Result := 'row(';
  for I := 0 to High(ARow) do
  begin
    Result := Result + 'cell(';
    for J := 0 to High(ARow[I]) do
      Result := Result + 'sp' + StylesKey(ARow[I][J].Styles) +
        '[' + U8(ARow[I][J].Text) + ']link[' + U8(ARow[I][J].Link) + ']';
    Result := Result + ')';
  end;
  Result := Result + ')';
end;

function TMdEquivalenceTest.TreeSummary(const ABlocks: TMdBlockArray): string;
var
  I, J, K: Integer;
  B: TMdBlock;
begin
  Result := 'blocks=' + IntToStr(Length(ABlocks));
  for I := 0 to High(ABlocks) do
  begin
    B := ABlocks[I];
    Result := Result + LineEnding + '#' + IntToStr(I) +
      ' kind=' + IntToStr(Ord(B.Kind)) +
      ' level=' + IntToStr(B.Level) +
      ' lang=[' + U8(B.Language) + ']' +
      ' ordered=' + BoolToStr(B.Ordered, True) +
      ' ordinal=' + IntToStr(B.Ordinal);
    for J := 0 to High(B.Spans) do
      Result := Result + LineEnding + '  sp' + StylesKey(B.Spans[J].Styles) +
        '[' + U8(B.Spans[J].Text) + ']link[' + U8(B.Spans[J].Link) + ']';
    if Length(B.Align) > 0 then
    begin
      Result := Result + LineEnding + '  align=';
      for J := 0 to High(B.Align) do
        Result := Result + AlignKey(B.Align[J]);
    end;
    if Length(B.Head) > 0 then
      Result := Result + LineEnding + '  head=' + RowSummary(B.Head);
    for J := 0 to High(B.Rows) do
      Result := Result + LineEnding + '  r' + IntToStr(J) + '=' +
        RowSummary(B.Rows[J]);
  end;
end;

function TMdEquivalenceTest.BatchParse(const AText: string): TMdBlockArray;
var
  Parser: TMarkdownParser;
begin
  Parser := TMarkdownParser.Create;
  try
    Result := Parser.Parse(AText);
  finally
    Parser.Free;
  end;
end;

function TMdEquivalenceTest.StreamParse(const AText: string;
  AChunkCodepoints: Integer): TMdBlockArray;
var
  Parser: TMarkdownParser;
  Whole: UnicodeString;
  Chunk: UnicodeString;
  I, N, Size: Integer;
begin
  { Chunk on the decoded text so a chunk boundary can never fall inside a
    multi-byte sequence; see limitation 1 in the unit header. }
  Whole := UnicodeString(AText);
  Parser := TMarkdownParser.Create;
  try
    Parser.Reset;
    Size := AChunkCodepoints;
    if Size <= 0 then
      Size := Length(Whole);
    if Size < 1 then
      Size := 1;
    I := 1;
    while I <= Length(Whole) do
    begin
      N := Size;
      if I + N - 1 > Length(Whole) then
        N := Length(Whole) - I + 1;
      Chunk := Copy(Whole, I, N);
      Parser.Append(UTF8Encode(Chunk));
      Inc(I, N);
    end;
    Parser.Finish;
    Result := Parser.Blocks;
  finally
    Parser.Free;
  end;
end;

function TMdEquivalenceTest.LoadDoc(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure TMdEquivalenceTest.TestCorpusIsPresent;
var
  Docs: TStringList;
begin
  Docs := TStringList.Create;
  try
    CollectDocs(Docs);
    AssertTrue('the corpus directory exists: ' + CorpusDir,
      DirectoryExists(CorpusDir));
    AssertTrue('at least ' + IntToStr(MinDocuments) + ' corpus documents, found ' +
      IntToStr(Docs.Count), Docs.Count >= MinDocuments);
  finally
    Docs.Free;
  end;
end;

procedure TMdEquivalenceTest.TestEveryDocumentProducesBlocks;
var
  Docs: TStringList;
  I: Integer;
  Blocks: TMdBlockArray;
begin
  Docs := TStringList.Create;
  try
    CollectDocs(Docs);
    for I := 0 to Docs.Count - 1 do
    begin
      Blocks := BatchParse(LoadDoc(Docs[I]));
      { Not a behaviour pin: it guards the equivalence test below from passing
        because both paths produced nothing. }
      AssertTrue(ExtractFileName(Docs[I]) + ' produced no blocks at all',
        Length(Blocks) > 0);
    end;
  finally
    Docs.Free;
  end;
end;

procedure TMdEquivalenceTest.TestBatchAndStreamingAgreeAtEveryChunkSize;
var
  Docs: TStringList;
  I, C: Integer;
  Text, BatchSummary, StreamSummary: string;
begin
  Docs := TStringList.Create;
  try
    CollectDocs(Docs);
    AssertTrue('corpus is non-empty', Docs.Count > 0);
    for I := 0 to Docs.Count - 1 do
    begin
      Text := LoadDoc(Docs[I]);
      BatchSummary := TreeSummary(BatchParse(Text));
      for C := Low(ChunkSizes) to High(ChunkSizes) do
      begin
        StreamSummary := TreeSummary(StreamParse(Text, ChunkSizes[C]));
        if BatchSummary <> StreamSummary then
          Fail(ExtractFileName(Docs[I]) + ': batch and streamed disagree at a ' +
            IntToStr(ChunkSizes[C]) + '-codepoint chunk' + LineEnding +
            '=== batch ===' + LineEnding + BatchSummary + LineEnding +
            '=== streamed ===' + LineEnding + StreamSummary);
      end;
    end;
  finally
    Docs.Free;
  end;
end;

initialization
  RegisterTest(TMdEquivalenceTest);

end.
