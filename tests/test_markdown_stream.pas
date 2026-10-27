unit test_markdown_stream;
{ Tests for markdown.stream - incremental parsing of the node tree.

  The property that matters: a streamed parse must produce the SAME tree as a
  batch parse of the concatenated text. Everything else here supports that.

  Note the shape of the assertion. It compares the FINALISED nodes, because the
  open tail is deliberately raw and not part of the tree until it closes. That is
  the design (v1 SPEC 4.3 carried into v2): a closed block is final, so appending
  stays amortised O(n) instead of re-scanning the document per chunk. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.tree, markdown.stream;

type
  TMdStreamTest = class(TTestCase)
  private
    { Parse in one chunk and via the streamer, and compare a flat kind chain. }
    function BatchKinds(const AText: string): string;
    function StreamKinds(const AText: string; AChunk: Integer): string;
    function KindsOf(const ADoc: TMdDocument): string;
  published
    { equivalence, first }
    procedure TestStreamMatchesBatchAtEveryChunkSize;
    procedure TestStreamMatchesBatchOverTheCorpus;
    { segmenter closure rules - each is a bug if wrong }
    procedure TestBlankLineDoesNotCloseAList;
    procedure TestBlankLineDoesNotCloseAQuote;
    procedure TestANonIndentedLineClosesAList;
    procedure TestAFenceStaysOpenUntilItsCloser;
    procedure TestAPipeRowContinuesATable;
    procedure TestBlankClosesText;
    { the open tail }
    procedure TestOpenTailIsRawText;
    procedure TestTailIncludesThePartialLine;
    procedure TestFinishIsIdempotent;
    procedure TestFinalizedCountGrowsMonotonically;
    procedure TestEmptyStream;
    procedure TestOpenKindIsReported;
  end;

implementation

function TMdStreamTest.KindsOf(const ADoc: TMdDocument): string;
var
  I: Integer;
  N: TMdNode;
begin
  Result := '';
  for I := 1 to NodeCount(ADoc) do
  begin
    N := NodeOf(ADoc, I);
    { Skip the text nodes: chunk boundaries can split a text run, and that is a
      legitimate difference in shape rather than in meaning. Kinds and structure
      are what must match. }
    if N.Kind in [mnText, mnLineBreak] then
      Continue;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + KindName(N.Kind);
  end;
end;

function TMdStreamTest.BatchKinds(const AText: string): string;
begin
  Result := KindsOf(ParseTree(AText));
end;

function TMdStreamTest.StreamKinds(const AText: string; AChunk: Integer): string;
var
  S: TMarkdownStream;
  I, N: Integer;
  Chunk: string;
begin
  S := TMarkdownStream.Create;
  try
    I := 1;
    while I <= Length(AText) do
    begin
      N := AChunk;
      if I + N - 1 > Length(AText) then
        N := Length(AText) - I + 1;
      Chunk := Copy(AText, I, N);
      S.Append(Chunk);
      Inc(I, N);
    end;
    S.Finish;
    Result := KindsOf(S.Document);
  finally
    S.Free;
  end;
end;

{ --- equivalence ---------------------------------------------------------- }

procedure TMdStreamTest.TestStreamMatchesBatchAtEveryChunkSize;
const
  Cases: array[0..7] of string = (
    '# Heading' + #10 + #10 + 'A paragraph.',
    '- a' + #10 + '- b' + #10 + #10 + '> q' + #10 + #10 + 'z',
    '```p' + #10 + 'code' + #10 + '---' + #10 + '```' + #10 + #10 + 'after',
    '| a | b |' + #10 + '| - | - |' + #10 + '| 1 | 2 |',
    'Title' + #10 + '=====' + #10 + #10 + 'body',
    '- a' + #10 + '  - b' + #10 + '- c',
    '> quote' + #10 + #10 + 'para',
    '---' + #10 + 'x' + #10 + '---');
  Sizes: array[0..4] of Integer = (1, 7, 64, 997, 100000);
var
  I, K: Integer;
  Batch, Streamed: string;
begin
  for I := 0 to High(Cases) do
  begin
    Batch := BatchKinds(Cases[I]);
    for K := 0 to High(Sizes) do
    begin
      Streamed := StreamKinds(Cases[I], Sizes[K]);
      if Batch <> Streamed then
        Fail('case ' + IntToStr(I) + ' at chunk ' + IntToStr(Sizes[K]) +
          ': batch [' + Batch + '] streamed [' + Streamed + ']');
    end;
  end;
end;

procedure TMdStreamTest.TestStreamMatchesBatchOverTheCorpus;
var
  Docs: TStringList;
  SR: TSearchRec;
  Text: string;
  Stream: TFileStream;
  I: Integer;
  Batch, Streamed: string;
begin
  Docs := TStringList.Create;
  try
    if FindFirst('tests/data/md_corpus/*.md', faAnyFile, SR) = 0 then
    begin
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
          Docs.Add('tests/data/md_corpus/' + SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    AssertTrue('corpus present', Docs.Count > 0);
    Docs.Sort;
    for I := 0 to Docs.Count - 1 do
    begin
      Stream := TFileStream.Create(Docs[I], fmOpenRead or fmShareDenyWrite);
      try
        SetLength(Text, Stream.Size);
        if Stream.Size > 0 then
          Stream.ReadBuffer(Text[1], Stream.Size);
      finally
        Stream.Free;
      end;
      Batch := BatchKinds(Text);
      Streamed := StreamKinds(Text, 7);
      if Batch <> Streamed then
        Fail(ExtractFileName(Docs[I]) + ': batch [' + Batch + '] streamed [' +
          Streamed + ']');
    end;
  finally
    Docs.Free;
  end;
end;

{ --- closure rules -------------------------------------------------------- }

procedure TMdStreamTest.TestBlankLineDoesNotCloseAList;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('- a' + #10);
    S.Append(#10);
    { Still the same open list: another item may follow. }
    AssertTrue('the list is still open', S.OpenKind = okList);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestBlankLineDoesNotCloseAQuote;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('> a' + #10);
    S.Append(#10);
    AssertTrue('the quote is still open', S.OpenKind = okQuote);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestANonIndentedLineClosesAList;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('- a' + #10);
    AssertTrue('list open', S.OpenKind = okList);
    S.Append('plain' + #10);
    { The list closed and a new segment opened as text. }
    AssertTrue('the list closed', S.OpenKind = okText);
    AssertTrue('one block was finalised', S.FinalizedCount = 1);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestAFenceStaysOpenUntilItsCloser;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('```' + #10);
    AssertTrue('fence open', S.OpenKind = okFence);
    S.Append('---' + #10);
    { A `---` inside a fence is content, not a rule, and not a closer. }
    AssertTrue('still open', S.OpenKind = okFence);
    S.Append('```' + #10);
    AssertTrue('closed', S.OpenKind = okNone);
    AssertTrue('the fence was finalised', S.FinalizedCount >= 1);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestAPipeRowContinuesATable;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('| a | b |' + #10);
    S.Append('| - | - |' + #10);
    AssertTrue('table open', S.OpenKind = okTable);
    S.Append('| 1 | 2 |' + #10);
    AssertTrue('still open', S.OpenKind = okTable);
    S.Append('done' + #10);
    AssertTrue('the table closed', S.OpenKind = okText);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestBlankClosesText;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('a paragraph' + #10);
    AssertTrue('text open', S.OpenKind = okText);
    S.Append(#10);
    AssertTrue('closed by the blank', S.OpenKind = okNone);
  finally
    S.Free;
  end;
end;

{ --- the open tail -------------------------------------------------------- }

procedure TMdStreamTest.TestOpenTailIsRawText;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('**unfinished bold' + #10);
    { The tail is the raw text, NOT a parsed node: an incomplete block renders as
      its own characters rather than a half-parsed shape. }
    AssertEquals('raw tail', '**unfinished bold', string(S.TailText));
    AssertEquals('and no node was created for it', 0, S.FinalizedCount);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestTailIncludesThePartialLine;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('a complete line' + #10 + 'and a par');
    { A streamed line shows before its newline arrives. }
    AssertEquals('the partial line is included',
      'a complete line' + #10 + 'and a par', string(S.TailText));
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestFinishIsIdempotent;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    S.Append('a paragraph' + #10);
    S.Finish;
    AssertEquals('one block', 1, S.FinalizedCount);
    S.Finish;
    S.Finish;
    { A second Finish must not duplicate the block. }
    AssertEquals('still one block', 1, S.FinalizedCount);
    AssertEquals('no tail', '', string(S.TailText));
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestFinalizedCountGrowsMonotonically;
var
  S: TMarkdownStream;
  I, Prev: Integer;
begin
  S := TMarkdownStream.Create;
  try
    Prev := 0;
    for I := 1 to 5 do
    begin
      S.Append('# heading ' + IntToStr(I) + #10 + #10);
      AssertTrue('count grew', S.FinalizedCount >= Prev);
      Prev := S.FinalizedCount;
    end;
    AssertTrue('five headings were finalised', Prev >= 5);
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestEmptyStream;
var
  S: TMarkdownStream;
  D: TMdDocument;
begin
  S := TMarkdownStream.Create;
  try
    S.Finish;
    D := S.Document;
    AssertEquals('only the root', 1, NodeCount(D));
    AssertTrue('and it is a document', NodeOf(D, D.Root).Kind = mnDocument);
    AssertEquals('no tail', '', string(S.TailText));
  finally
    S.Free;
  end;
end;

procedure TMdStreamTest.TestOpenKindIsReported;
var
  S: TMarkdownStream;
begin
  S := TMarkdownStream.Create;
  try
    AssertTrue('nothing open yet', S.OpenKind = okNone);
    S.Append('x' + #10);
    AssertTrue('text', S.OpenKind = okText);
    S.Append(#10);
    AssertTrue('closed', S.OpenKind = okNone);
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TMdStreamTest);

end.
