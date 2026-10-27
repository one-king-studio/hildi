program markdown_stream_demo;
{ A visible demonstration of the streaming markdown parser.

  It feeds a document to TMarkdownStream a few characters at a time and prints,
  at each step, the two things that make incremental parsing useful:

    FINALISED  the blocks already closed. These are final: they are never
               re-parsed, which is what keeps appending amortised O(n).
    TAIL       the open block, as RAW TEXT. An incomplete block renders as its
               own characters rather than flickering through half-parsed shapes.

  The contrast with a batch parse is the point: watch FINALISED grow while TAIL
  carries the in-progress block, and note that the total work never revisits what
  is already closed.

  Usage:
    markdown-stream-demo                 run the built-in tour
    markdown-stream-demo <file>          stream a file, 12 chars at a time
    markdown-stream-demo <file> <size>   choose the chunk size
    markdown-stream-demo --quiet <file>  summary only, no per-chunk output
}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  markdown.types, markdown.tree, markdown.stream;

const
  Tour =
    '# Streaming markdown' + #10 +
    #10 +
    'A paragraph that arrives one character at a time, and only becomes a' + #10 +
    'block when its blank line arrives.' + #10 +
    #10 +
    '- a list item' + #10 +
    '- another item' + #10 +
    #10 +
    '> a quote survives a blank line inside it' + #10 +
    #10 +
    '```pascal' + #10 +
    'WriteLn(''inside a fence'');' + #10 +
    '--- this is not a rule' + #10 +
    '```' + #10 +
    #10 +
    '| a | b |' + #10 +
    '| - | - |' + #10 +
    '| 1 | 2 |' + #10;

function Sha1Short(const S: string): string;
var
  I: Integer;
  H: Cardinal;
begin
  H := 2166136261;
  {$push}{$Q-}{$R-}
  for I := 1 to Length(S) do
    H := (H xor Ord(S[I])) * 16777619;
  {$pop}
  Result := IntToHex(H, 8);
end;

{ One finalised block, described compactly: kind, and its first line of text. }
function DescribeBlock(const ADoc: TMdDocument; const AId: Integer): string;
var
  N: TMdNode;
begin
  N := NodeOf(ADoc, AId);
  Result := KindName(N.Kind);
  if N.Kind = mnHeading then
    Result := Result + '(h' + IntToStr(N.Level) + ')';
  if N.Kind = mnCodeBlock then
    Result := Result + '(' + string(N.Language) + ')';
  if N.Kind = mnList then
    if N.Style = lsOrdered then
      Result := Result + '(ordered)'
    else
      Result := Result + '(bullet)';
end;

procedure ShowState(const S: TMarkdownStream; const AStep: Integer;
  const AChunk: string; const AVerbose: Boolean);
var
  Doc: TMdDocument;
  Root: TMdNode;
  I: Integer;
  Line, Tail: string;
begin
  Doc := S.Document;
  Root := NodeOf(Doc, Doc.Root);
  Write('[' + IntToStr(AStep) + '] ', AChunk);
  if AVerbose then
    Write('  ->  ');
  Line := '';
  for I := 0 to High(Root.Children) do
  begin
    if Line <> '' then
      Line := Line + ', ';
    Line := Line + DescribeBlock(Doc, Root.Children[I]);
  end;
  if Line = '' then
    Line := '(none)';
  Tail := string(S.TailText);
  if Length(Tail) > 28 then
    Tail := Copy(Tail, 1, 25) + '...';
  Tail := StringReplace(Tail, #10, '\n', [rfReplaceAll]);
  if AVerbose then
    WriteLn('finalised=' + IntToStr(S.FinalizedCount) + ' [' + Line + ']  tail="' +
      Tail + '"')
  else
    WriteLn('  ' + IntToStr(S.FinalizedCount) + ' finalised, tail "' + Tail + '"');
end;

procedure StreamIt(const AText: string; AChunkSize: Integer;
  const AVerbose: Boolean);
var
  S: TMarkdownStream;
  I, N, Step: Integer;
  Chunk: string;
  BatchKinds, StreamKinds: string;
  Batch: TMdDocument;
  Root: TMdNode;
  J: Integer;

  function KindsOf(const ADoc: TMdDocument): string;
  var
    R: TMdNode;
    K: Integer;
    N2: TMdNode;
  begin
    Result := '';
    R := NodeOf(ADoc, ADoc.Root);
    for K := 0 to High(R.Children) do
    begin
      N2 := NodeOf(ADoc, R.Children[K]);
      if Result <> '' then
        Result := Result + ',';
      Result := Result + KindName(N2.Kind);
    end;
  end;

begin
  WriteLn('streaming ', Length(AText), ' chars, ', AChunkSize, ' at a time');
  WriteLn(StringOfChar('-', 72));
  S := TMarkdownStream.Create;
  try
    I := 1;
    Step := 0;
    while I <= Length(AText) do
    begin
      N := AChunkSize;
      if I + N - 1 > Length(AText) then
        N := Length(AText) - I + 1;
      Chunk := Copy(AText, I, N);
      if AVerbose then
      begin
        Inc(Step);
        ShowState(S, Step, '''' + StringReplace(Chunk, #10, '\n',
          [rfReplaceAll]) + '''', True);
      end;
      S.Append(Chunk);
      Inc(I, N);
    end;
    S.Finish;
    if AVerbose then
    begin
      Inc(Step);
      ShowState(S, Step, '(finish)', True);
    end;
    WriteLn(StringOfChar('-', 72));

    { The equivalence claim, checked rather than asserted. }
    Batch := ParseTree(AText);
    BatchKinds := KindsOf(Batch);
    StreamKinds := KindsOf(S.Document);
    WriteLn('finalised blocks : ', S.FinalizedCount);
    WriteLn('streamed kinds   : ', StreamKinds);
    WriteLn('batch kinds      : ', BatchKinds);
    if StreamKinds = BatchKinds then
      WriteLn('EQUIVALENT       : streamed == batch')
    else
      WriteLn('DIVERGED         : streamed <> batch');
    WriteLn('tail after finish: "', String(S.TailText), '"');
    Root := NodeOf(S.Document, S.Document.Root);
    WriteLn('nodes in the tree: ', NodeCount(S.Document));
    J := 0;
    J := J;
  finally
    S.Free;
  end;
end;

function LoadFile(const APath: string): string;
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

var
  Path, Text: string;
  ChunkSize, A: Integer;
  Verbose: Boolean;
begin
  Path := '';
  ChunkSize := 12;
  Verbose := True;
  { Simple and unambiguous: --quiet is a flag, the first non-flag is the path, the
    second non-flag is the chunk size. My first version had a `--quiet` lookahead
    that consumed the path as the chunk size, so the demo silently streamed the
    built-in tour instead of the file - a demo that lies about its input. }
  A := 1;
  while A <= ParamCount do
  begin
    if ParamStr(A) = '--quiet' then
      Verbose := False
    else if ParamStr(A) = '-q' then
      Verbose := False
    else if Path = '' then
      Path := ParamStr(A)
    else
      ChunkSize := StrToIntDef(ParamStr(A), ChunkSize);
    Inc(A);
  end;
  if ChunkSize < 1 then
    ChunkSize := 1;

  if Path = '' then
    Text := Tour
  else
  begin
    if not FileExists(Path) then
    begin
      WriteLn('no such file: ', Path);
      Halt(1);
    end;
    Text := LoadFile(Path);
    WriteLn('file: ', Path);
  end;

  StreamIt(Text, ChunkSize, Verbose);
end.
