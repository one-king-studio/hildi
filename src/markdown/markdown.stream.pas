unit markdown.stream;
{ Incremental parsing for the node tree.

  The design rule (v1 SPEC 4.3, carried into v2): the SEGMENTER DECIDES WHERE, NOT
  WHAT. It tracks which kind of block is open and decides only where that block
  ENDS. Each closed segment is handed to the full block scanner, so every block
  kind works when streamed without the streaming layer knowing about it.

  This matters for a renderer: a finalised block is final and never re-parsed, so
  appending stays amortised O(n) instead of re-scanning the document on every
  chunk. The open tail is retained as RAW TEXT and shown as plain text, so an
  incomplete block renders as its own characters rather than flickering through
  half-parsed shapes.

  Closure rules, each of which is a bug if wrong:

    okFence   a line that closes the fence (same marker, >= the opening length)
    okTable   a line with no pipe
    okList    a non-marker, non-indented line. A BLANK LINE DOES NOT CLOSE IT
    okQuote   the `>` prefix stopping. A BLANK LINE DOES NOT CLOSE IT
    okText    a blank line

  Pure: the RTL plus markdown.types/markdown.tree. `make markdown-standalone`
  proves it. }

{$mode delphi}{$H+}

interface

uses
  Classes,   { TStream, for FeedFrom. RTL/FCL, so the module stays pure. }
  markdown.types, markdown.tree;

type
  TMdOpenKind = (okNone, okFence, okCustom, okMath, okText, okList, okTable,
    okQuote);

  { A SINK: the receiving end of a stream, the way an IObserver is the receiving
    end of an observable - but without the observable machinery (no Subscribe, no
    multicast, no teardown, no operators), because a parse has exactly one
    consumer and its lifetime is the caller's.

    Deliberately NOT a TStream: TStream is a byte buffer you Read/Write, and has
    no way to say "block 7 closed". The payload here is structural events, not
    bytes. Where TStream does help is the INPUT side - see FeedFrom below.

    All methods are optional: implement what you need and leave the rest empty
    (a sink that only wants completion overrides OnCompleted alone). }
  IMdStreamSink = interface
    { A block finished and will never be re-parsed. AId is its node id in the
      document being built. This is the event a renderer needs: it can append one
      widget and never touch it again. }
    procedure OnBlockClosed(const AId: Integer);
    { The open tail changed (more characters arrived). A polling renderer can
      ignore this and read TailText on its own clock. }
    procedure OnTailChanged(const ATail: UnicodeString);
    { The stream ended. No further notifications follow. }
    procedure OnCompleted;
  end;

  { The open segment's lines. Local to this unit: markdown.tree's equivalent is
    private to it. }
  TStrArray = array of UnicodeString;

  { Feed text in chunks; the closed blocks accumulate as a tree and the open
    tail stays raw. Not thread-safe and not re-entrant: one per stream. }
  TMarkdownStream = class
  private
    FDoc: TMdDocument;
    FBuffer: TStrArray;      { lines of the OPEN segment, not yet parsed }
    FPartial: UnicodeString; { received text with no newline yet }
    FOpen: TMdOpenKind;
    FMarker: UnicodeString;  { the opening fence marker, for okFence }
    FStarted: Boolean;       { whether the document root exists }
    FSink: IMdStreamSink;    { optional; not owned }
    FTailNotified: UnicodeString;
    FCompleted: Boolean;
    procedure EnsureRoot;
    procedure NotifyBlocksClosed(const AFromId: Integer);
    procedure NotifyTail;
    procedure AddLine(const ALine: UnicodeString);
    procedure CloseSegment;
  public
    { ASink is optional and NOT owned: the caller decides its lifetime. }
    constructor Create(const ASink: IMdStreamSink = nil);
    { Append a chunk. Lines complete inside the chunk are processed now. }
    procedure Append(const AChunk: string);
    { End of stream: close the open segment. Idempotent. }
    procedure Finish;
    { The closed blocks so far, as a tree. The open tail is NOT included. }
    function Document: TMdDocument;
    { The open tail as raw text, or '' when nothing is open. A renderer shows
      this as plain text, which is why an incomplete block cannot flicker. }
    function TailText: UnicodeString;
    { How many blocks are finalised. Grows monotonically. }
    function FinalizedCount: Integer;
    { The kind currently open, for a caller that wants to know. }
    function OpenKind: TMdOpenKind;
    { Feed every remaining byte of AStream through Append, then Finish. This is
      the convenience TStream is genuinely FOR: a file or socket is bytes, the
      parser wants chunks, and this bridges them without the caller writing a
      read loop. }
    procedure FeedFrom(AStream: TStream; ABufSize: Integer = 8192);
  end;

implementation

uses
  SysUtils;

function IsSpaceU(const AText: UnicodeString; AIndex: Integer): Boolean;
begin
  Result := (AText[AIndex] = ' ') or (AText[AIndex] = #9) or
    (AText[AIndex] = #10) or (AText[AIndex] = #13);
end;

function TrimU(const S: UnicodeString): UnicodeString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and IsSpaceU(S, A) do
    Inc(A);
  while (B >= A) and IsSpaceU(S, B) do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

function StartsWith(const S, APrefix: UnicodeString): Boolean;
begin
  Result := Copy(S, 1, Length(APrefix)) = APrefix;
end;

{ --- the segmenter's classifiers ------------------------------------------ }

{ The fence marker an opener line establishes, or '' when it is not a fence. }
function FenceOpener(const ALine: UnicodeString): UnicodeString;
var
  S: UnicodeString;
  I: Integer;
begin
  Result := '';
  S := TrimU(ALine);
  if (S = '') or not (S[1] in ['`', '~']) then
    Exit;
  I := 1;
  while (I <= Length(S)) and (S[I] = S[1]) do
    Inc(I);
  if I <= 3 then
    Exit;   { fewer than three markers is not a fence }
  if (S[1] = '`') and (Pos('`', Copy(S, I, Length(S))) > 0) then
    Exit;
  Result := Copy(S, 1, I - 1);
end;

function ClosesFence(const ALine: UnicodeString; const AMarker: UnicodeString): Boolean;
var
  S: UnicodeString;
  I: Integer;
begin
  S := TrimU(ALine);
  Result := False;
  if (S = '') or not (S[1] in ['`', '~']) then
    Exit;
  I := 1;
  while (I <= Length(S)) and (S[I] = S[1]) do
    Inc(I);
  Result := (S[1] = AMarker[1]) and (I - 1 >= Length(AMarker)) and
    (TrimU(Copy(S, I, Length(S))) = '');
end;

function ListMarkerAt(const ALine: UnicodeString; out AIndent: Integer): Boolean;
var
  I: Integer;
begin
  AIndent := 0;
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
  begin
    Inc(AIndent);
    Inc(I);
  end;
  if I > Length(ALine) then
    Exit(False);
  if ALine[I] in ['-', '*', '+'] then
    Exit((I = Length(ALine)) or (ALine[I + 1] = ' '));
  while (I <= Length(ALine)) and (ALine[I] in ['0'..'9']) do
    Inc(I);
  Result := (I > 1) and (I <= Length(ALine)) and (ALine[I] in ['.', ')']) and
    ((I = Length(ALine)) or (ALine[I + 1] = ' '));
end;

function HasPipe(const ALine: UnicodeString): Boolean;
var
  I: Integer;
begin
  I := 1;
  while I <= Length(ALine) do
    if ALine[I] = '\' then
      Inc(I, 2)
    else if ALine[I] = '|' then
      Exit(True)
    else
      Inc(I);
  Result := False;
end;

function IsQuoted(const ALine: UnicodeString): Boolean;
var
  S: UnicodeString;
begin
  S := TrimU(ALine);
  Result := StartsWith(S, '>');
end;

function IndentOf(const ALine: UnicodeString): Integer;
begin
  Result := 0;
  while (Result < Length(ALine)) and (ALine[Result + 1] = ' ') do
    Inc(Result);
end;

{ --- merging --------------------------------------------------------------- }

procedure MergeInto(var ADest: TMdDocument; const ASrc: TMdDocument);
var
  Offset, I, J, NewId, NewRoot: Integer;
  OffsetMap: array of Integer;
  N: TMdNode;
begin
  if Length(ASrc.Nodes) = 0 then
    Exit;
  if Length(ADest.Nodes) = 0 then
  begin
    ADest := ASrc;
    Exit;
  end;
  Offset := Length(ADest.Nodes) - 1;   { ids in ASrc start at 1 }
  { ADest keeps its own root (id 1); ASrc's root is NOT copied, only its
    children, which are re-parented onto ADest's root. }
  NewRoot := ADest.Root;
  SetLength(OffsetMap, Length(ASrc.Nodes));
  for I := 0 to High(OffsetMap) do
    OffsetMap[I] := 0;

  { Reserve the ids first, so children can be remapped in one pass. }
  for I := 1 to High(ASrc.Nodes) do
  begin
    if ASrc.Nodes[I].Id = ASrc.Root then
      Continue;
    SetLength(ADest.Nodes, Length(ADest.Nodes) + 1);
    NewId := High(ADest.Nodes);
    OffsetMap[I] := NewId;
  end;

  for I := 1 to High(ASrc.Nodes) do
  begin
    if ASrc.Nodes[I].Id = ASrc.Root then
      Continue;
    N := ASrc.Nodes[I];
    NewId := OffsetMap[I];
    N.Id := NewId;
    { Re-point the parent, and re-home the root's children onto ADest's root. }
    if N.Parent = ASrc.Root then
      N.Parent := NewRoot
    else if (N.Parent >= 1) and (N.Parent <= High(OffsetMap)) then
      N.Parent := OffsetMap[N.Parent];
    for J := 0 to High(N.Children) do
      if (N.Children[J] >= 1) and (N.Children[J] <= High(OffsetMap)) then
        N.Children[J] := OffsetMap[N.Children[J]];
    ADest.Nodes[NewId] := N;
  end;

  { Re-home the top-level children, in order. }
  for I := 1 to High(ASrc.Nodes) do
    if (ASrc.Nodes[I].Parent = ASrc.Root) then
    begin
      SetLength(ADest.Nodes[NewRoot].Children,
        Length(ADest.Nodes[NewRoot].Children) + 1);
      ADest.Nodes[NewRoot].Children[High(ADest.Nodes[NewRoot].Children)] :=
        OffsetMap[I];
    end;
end;

{ --- TMarkdownStream ------------------------------------------------------- }

constructor TMarkdownStream.Create(const ASink: IMdStreamSink);
begin
  inherited Create;
  FDoc := Default(TMdDocument);
  FBuffer := nil;
  FPartial := '';
  FOpen := okNone;
  FMarker := '';
  FStarted := False;
  FSink := ASink;
  FTailNotified := '';
  FCompleted := False;
end;

{ Tell the sink which blocks newly closed. Ids are contiguous and monotonic, so
  the range [AFromId .. count-1] is exactly the new blocks. }
procedure TMarkdownStream.NotifyBlocksClosed(const AFromId: Integer);
var
  I: Integer;
begin
  if not Assigned(FSink) then
    Exit;
  EnsureRoot;
  for I := AFromId to Length(FDoc.Nodes[FDoc.Root].Children) - 1 do
    FSink.OnBlockClosed(FDoc.Nodes[FDoc.Root].Children[I]);
end;

{ Notify on an ACTUAL change: a sink that repaints would otherwise be told the
  same tail thousands of times for a long block. }
procedure TMarkdownStream.NotifyTail;
var
  T: UnicodeString;
begin
  if not Assigned(FSink) then
    Exit;
  T := TailText;
  if T = FTailNotified then
    Exit;
  FTailNotified := T;
  FSink.OnTailChanged(T);
end;

procedure TMarkdownStream.EnsureRoot;
var
  Root: TMdNode;
begin
  if FStarted then
    Exit;
  FStarted := True;
  SetLength(FDoc.Nodes, 1);
  FDoc.Nodes[0] := Default(TMdNode);
  Root := Default(TMdNode);
  Root.Kind := mnDocument;
  SetLength(FDoc.Nodes, 2);
  Root.Id := 1;
  FDoc.Nodes[1] := Root;
  FDoc.Root := 1;
end;

procedure TMarkdownStream.CloseSegment;
var
  Text: UnicodeString;
  I, NewCount, Before: Integer;
begin
  if Length(FBuffer) = 0 then
  begin
    FOpen := okNone;
    FMarker := '';
    Exit;
  end;
  { ONE buffer for the whole segment, sized up front. The previous version built
    the text with `Text := Text + #10; Text := Text + Line` in a loop, which is
    O(n^2) in the segment and allocates a new string per line. }
  NewCount := 0;
  for I := 0 to High(FBuffer) do
    Inc(NewCount, Length(FBuffer[I]) + 1);
  SetLength(Text, NewCount);
  NewCount := 0;
  for I := 0 to High(FBuffer) do
  begin
    if I > 0 then
    begin
      Inc(NewCount);
      Text[NewCount] := #10;
    end;
    if FBuffer[I] <> '' then
    begin
      Move(FBuffer[I][1], Text[NewCount + 1], Length(FBuffer[I]) * SizeOf(UnicodeChar));
      Inc(NewCount, Length(FBuffer[I]));
    end;
  end;
  SetLength(Text, NewCount);

  EnsureRoot;
  Before := Length(FDoc.Nodes[FDoc.Root].Children);
  { Parse the segment INTO this document. No temporary TMdDocument, no MergeInto,
    no OffsetMap: ids continue from where this document left off, which removes
    the per-block allocation burst the streaming requirement is about. }
  AppendParsed(FDoc, UTF8Encode(Text), FDoc.Root);
  FBuffer := nil;
  FOpen := okNone;
  FMarker := '';
  NotifyBlocksClosed(Before);
end;

procedure TMarkdownStream.AddLine(const ALine: UnicodeString);
var
  Blank: Boolean;
  Indent: Integer;
  Closes, StartsNew: Boolean;
begin
  EnsureRoot;
  Blank := TrimU(ALine) = '';
  Closes := False;

  case FOpen of
    okFence:
      { The CLOSING FENCE LINE IS PART OF THE FENCE, so it is buffered and the
        segment closed AFTER it. Closing first (as my first version did) put the
        closer in a fresh segment, which then looked like a NEW fence opener. }
      Closes := ClosesFence(ALine, FMarker);
    okCustom:
      Closes := TrimU(ALine) = ':::';
    okMath:
      Closes := TrimU(ALine) = '$$';
    okTable:
      Closes := (not Blank) and not HasPipe(ALine);
    okList:
      { A BLANK LINE DOES NOT CLOSE A LIST: another item may follow. }
      if not Blank then
        Closes := (not ListMarkerAt(ALine, Indent)) and (IndentOf(ALine) = 0);
    okQuote:
      { A BLANK LINE DOES NOT CLOSE A QUOTE either. }
      if not Blank then
        Closes := not IsQuoted(ALine);
    okText:
      Closes := Blank;
    okNone:
      Closes := False;
  end;

  if (FOpen in [okFence, okCustom, okMath]) and Closes then
  begin
    { Buffer the closer, then close: the whole fence is one segment. }
    SetLength(FBuffer, Length(FBuffer) + 1);
    FBuffer[High(FBuffer)] := ALine;
    CloseSegment;
    Exit;
  end;

  if Closes and (FOpen <> okNone) then
    CloseSegment;

  SetLength(FBuffer, Length(FBuffer) + 1);
  FBuffer[High(FBuffer)] := ALine;

  { A blank line never OPENS a block; it only ends one. }
  if (FOpen = okNone) and not Blank then
  begin
    StartsNew := True;
    FMarker := FenceOpener(ALine);
    if FMarker <> '' then
      FOpen := okFence
    else if Copy(TrimU(ALine), 1, 3) = ':::' then
      FOpen := okCustom
    else if TrimU(ALine) = '$$' then
      FOpen := okMath
    else if ListMarkerAt(ALine, Indent) then
      FOpen := okList
    else if IsQuoted(ALine) then
      FOpen := okQuote
    else if HasPipe(ALine) then
      FOpen := okTable
    else
      FOpen := okText;
    StartsNew := StartsNew;
  end;
end;

procedure TMarkdownStream.Append(const AChunk: string);
var
  S, Line: UnicodeString;
  P: Integer;
begin
  S := FPartial + UnicodeString(AChunk);
  FPartial := '';
  P := Pos(#10, S);
  while P > 0 do
  begin
    Line := Copy(S, 1, P - 1);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    AddLine(Line);
    S := Copy(S, P + 1, Length(S));
    P := Pos(#10, S);
  end;
  FPartial := S;
  NotifyTail;
end;

procedure TMarkdownStream.Finish;
begin
  if FPartial <> '' then
  begin
    AddLine(FPartial);
    FPartial := '';
  end;
  CloseSegment;
  NotifyTail;
  { Exactly once: Finish is documented as idempotent, so a second call must not
    report a second completion. }
  if Assigned(FSink) and not FCompleted then
  begin
    FCompleted := True;
    FSink.OnCompleted;
  end;
end;

procedure TMarkdownStream.FeedFrom(AStream: TStream; ABufSize: Integer);
var
  Buf: AnsiString;
  Got: Integer;
begin
  if (AStream = nil) or (ABufSize < 1) then
    Exit;
  SetLength(Buf, ABufSize);
  repeat
    Got := AStream.Read(Buf[1], ABufSize);
    if Got > 0 then
      Append(Copy(Buf, 1, Got));
  until Got <= 0;
  Finish;
end;

function TMarkdownStream.Document: TMdDocument;
begin
  EnsureRoot;
  Result := FDoc;
end;

function TMarkdownStream.TailText: UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FBuffer) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + FBuffer[I];
  end;
  if FPartial <> '' then
  begin
    if Result <> '' then
      Result := Result + #10;
    Result := Result + FPartial;
  end;
end;

function TMarkdownStream.FinalizedCount: Integer;
begin
  EnsureRoot;
  { BLOCKS, not nodes. My first version returned Length(Nodes) - 2, which counts
    the paragraph's text child as a second block. A caller asking how many blocks
    are finalised means the root's children. }
  Result := Length(FDoc.Nodes[FDoc.Root].Children);
end;

function TMarkdownStream.OpenKind: TMdOpenKind;
begin
  Result := FOpen;
end;

end.
