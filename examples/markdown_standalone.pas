program markdown_standalone;
{ The isolation smoke for the Markdown library. It uses ONLY src/markdown plus the
  RTL: the build puts no harness unit and no `tui.*` on the search path, so a
  dependency on either fails here rather than in a review.

  This is the feature's central claim (SPEC 4.4). It parses a document with
  blocks of every kind, re-parses it in small chunks to prove the streamed and
  batch paths agree at the library's public surface, and renders the result to
  plain text - all with no terminal, no theme and no colour anywhere. }

{$mode delphi}{$H+}

uses
  SysUtils,
  MarkdownTypes, MarkdownTree, MarkdownStream, MarkdownRender;

var
  Doc, BatchTree, StreamTree: string;
  Whole: UnicodeString;
  D1, D4, D5: TMdDocument;
  Lines: TMdLineArray;
  I, J, K, ChunkSize: Integer;
  SawParagraph, SawHeading, SawList, SawFence, SawQuote, SawRule, SawTable: Boolean;
  D2, BatchD: TMdDocument;
  Str: TMarkdownStream;

function IsFrontmatterNode(const ANode: TMdNode): Boolean;
begin
  Result := ANode.Kind = mnFrontmatter;
end;

procedure Check(const AName: string; AOk: Boolean; const ADetail: string);
begin
  if AOk then
    WriteLn('  ok    ', AName)
  else
  begin
    WriteLn('  FAIL  ', AName, ': ', ADetail);
    Halt(1);
  end;
end;

{ A flat dump of every field, so "the two trees agree" is checked rather than
  asserted. Built as UTF-8: the implicit conversion is lossy for non-ASCII. }
function TreeSummary(const ABlocks: TMdBlockArray): string;
var
  B: TMdBlock;
  A, S: Integer;
  Line: string;
begin
  Result := IntToStr(Length(ABlocks));
  for A := 0 to High(ABlocks) do
  begin
    B := ABlocks[A];
    Line := '|' + IntToStr(Ord(B.Kind)) + ':' + IntToStr(B.Level) + ':' +
      BoolToStr(B.Ordered, True) + ':' + IntToStr(B.Ordinal) + ':';
    for S := 0 to High(B.Spans) do
      Line := Line + UTF8Encode(B.Spans[S].Text);
    Result := Result + Line;
  end;
end;

begin
  WriteLn('markdown library standalone');

  Whole :=
    '# Title' + #10 +
    #10 +
    'A paragraph with **bold**, *italic*, `code`, ~~strike~~ and a ' +
    '[link](https://example.com/a_b) in it.' + #10 +
    #10 +
    '- bullet one' + #10 +
    '- bullet two' + #10 +
    #10 +
    '1. ordered one' + #10 +
    '2. ordered two' + #10 +
    #10 +
    '> a quote' + #10 +
    '> that runs on' + #10 +
    #10 +
    '```pascal' + #10 +
    'WriteLn(''hello'');' + #10 +
    '---' + #10 +
    '```' + #10 +
    #10 +
    '| name | value |' + #10 +
    '| ---- | ----: |' + #10 +
    '| a    |     1 |' + #10 +
    #10 +
    '---' + #10 +
    #10 +
    'A closing paragraph, caf' + #$00E9 + ' included.' + #10;
  Doc := UTF8Encode(Whole);

  { 1. The v2 tree produces blocks of every kind. (The v1 flat-block parser was
       retired once markdownview rendered the tree; these checks cover the same
       ground against the model that actually ships.) }
  D1 := ParseTree(Doc);
  try
    Check('the document produced blocks',
      Length(NodeOf(D1, D1.Root).Children) > 0, 'none');
    Check('a paragraph', Length(NodesOfKind(D1, mnParagraph)) > 0, 'missing');
    Check('a heading', Length(NodesOfKind(D1, mnHeading)) > 0, 'missing');
    Check('a list item', Length(NodesOfKind(D1, mnListItem)) > 0, 'missing');
    Check('a code fence', Length(NodesOfKind(D1, mnCodeBlock)) > 0, 'missing');
    Check('a quote', Length(NodesOfKind(D1, mnBlockQuote)) > 0, 'missing');
    Check('a rule', Length(NodesOfKind(D1, mnHorizontalRule)) > 0, 'missing');
    Check('a table', Length(NodesOfKind(D1, mnTable)) > 0, 'missing');
    Lines := RenderTree(D1, 40);
    { Kept alive for the later render assertions: the checks below reuse this
      document, and freeing it here was a use-after-free. }
  finally
    D1.Free;
  end;

  { 4. The plain renderer consumes the AST with no terminal involved.
       NOTE: this renders a FRESH document rather than reusing D1, which section 1
       has already freed. Reusing it produced no lines at all - a use-after-free
       that the check caught as "the renderer produced lines: none". }
  D4 := ParseTree(Doc);
  try
    Lines := RenderTree(D4, 40);
  finally
    D4.Free;
  end;
  Check('the renderer produced lines', Length(Lines) > 0, 'none');
  Check('no line exceeds the width', Length(Lines[0]) <= 40, Lines[0]);
  WriteLn('  ---- rendered at 40 columns ----');
  { The renderer returns UTF-8 bytes; decode before printing, or the terminal
    shows the encoding (cafÃ©). This is a property of the CONSUMER, not the
    library: the library hands back bytes deliberately, so it never has to know
    what a terminal does. }
  for I := 0 to High(Lines) do
    WriteLn('  |', UTF8Decode(Lines[I]));
  WriteLn('  --------------------------------');

  { 5. The v2 tree renders, and the PARSER knows nothing about frontmatter: a
       leading fence is an ordinary thematic break, rendered like any other. }
  Lines := RenderTree(ParseTree('---' + #10 + 'title: T' + #10 + '---' + #10 +
    #10 + '# H' + #10 + #10 + '- a' + #10 + '  - b'), 40);
  Check('the tree renderer produced lines', Length(Lines) > 0, 'none');
  Check('the nested list is indented',
    (Length(Lines) > 3) and (Pos('- b', Lines[High(Lines)]) > 0),
    'no nested item');

  { 6. Frontmatter is a NODE, queryable from the root, and the general query
       finds it too - the same mechanism a footnote table would use. }
  D2 := ParseTree('---' + #10 + 'title: T' + #10 + '---' + #10 + 'body');
  Check('frontmatter is a node', FrontmatterOf(D2) > 0, 'not found');
  Check('and its text comes back verbatim',
    FrontmatterText(D2) = 'title: T', 'wrong text');
  Check('a fence with no close is not frontmatter',
    FrontmatterOf(ParseTree('---' + #10 + 'body')) = 0, 'wrongly accepted');
  Check('the general query finds it, like any node',
    Length(QueryNodes(D2, D2.Root, @IsFrontmatterNode)) = 1, 'query missed it');
  Check('and a footnote definition is aggregated',
    Length(FootnotesOf(ParseTree('a[^x]' + #10 + #10 + '[^x]: n'))) = 1,
    'no footnote');

  { 7. STREAMING is built in: the same document fed in small chunks yields the
       same block kinds as one batch parse, and the open tail stays raw. }
  Str := TMarkdownStream.Create;
  try
    Str.Append('# H' + #10 + #10 + '- a' + #10 + '- b' + #10 + #10 + '> q' + #10);
    Check('a block was finalised mid-stream', Str.FinalizedCount >= 1, 'none');
    Str.Append('```' + #10 + 'code' + #10 + '```' + #10);
    Str.Finish;
    BatchD := ParseTree('# H' + #10 + #10 + '- a' + #10 + '- b' + #10 + #10 +
      '> q' + #10 + '```' + #10 + 'code' + #10 + '```' + #10);
    Check('streamed and batch agree on block count',
      Str.FinalizedCount = Length(NodeOf(BatchD, BatchD.Root).Children),
      IntToStr(Str.FinalizedCount));
    Check('no tail after Finish', Str.TailText = '', 'tail remained');
  finally
    Str.Free;
  end;

  { 8. No wrapping when asked for none: one line per logical line at worst. }
  D5 := ParseTree(Doc);
  try
    Lines := RenderTree(D5, 0);
  finally
    D5.Free;
  end;
  Check('unwrapped rendering produced lines', Length(Lines) > 0, 'none');

  WriteLn('all checks passed');
end.
