unit hildi.replymeta;
{ Reply metadata: a substantive assistant reply may carry a small YAML
  frontmatter block with a title and keywords. This unit extracts that block as
  METADATA and returns the body with the block removed - the markdown renderer
  never sees the frontmatter.

  Tolerant and dependency-free (no YAML library). The block is normally LEADING
  (the first line is `---`), but a model sometimes says something first and emits
  its frontmatter after; a fence block anywhere at the start of a line counts,
  and the text before it stays in the body as a preamble. A block is only
  frontmatter if it actually carries a `title` or `keywords` key - a bare fence
  is a thematic break or a table separator and is left alone. Unknown keys are
  ignored; malformed input yields no metadata and the unchanged text. See
  docs/features/Session_Management/Reply_Metadata_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { The metadata a reply's leading frontmatter block carries, plus the body with
    the block removed. HasMeta is False when there was no leading block (Body is
    then the whole input, unchanged). }
  TReplyMeta = record
    HasMeta: Boolean;
    Title: string;
    Keywords: TStringArray;   // lowercased, de-duplicated, order preserved
    Body: string;             // the reply with the block stripped
  end;

{ Parse a reply. Tolerant: no leading block, an unterminated block, or garbage
  yields HasMeta = False and Body = ARaw. Never raises. }
function ExtractReplyMeta(const ARaw: string): TReplyMeta;

{ The streaming helper: feed the reply in chunks; it buffers only the potential
  leading block and reports what is safe to display. }
type
  TSuppressState = (fmUndecided, fmInBlock, fmDone);
  TFrontMatterSuppressor = record
    State: TSuppressState;
    Pending: string;   // bytes withheld while undecided/in-block
  end;

{ Feed a chunk. Appends any displayable text to AOut and returns True when the
  caller should render. While undecided/in-block, AOut is unchanged. }
function SuppressFrontMatter(var S: TFrontMatterSuppressor;
  const AChunk: string; out AOut: string): Boolean;

{ At the end of the reply: flush anything still withheld. A block that never
  closed (no fence, no blank line) is not frontmatter, so its bytes are body and
  must be shown - the streaming suppressor would otherwise have swallowed them. }
function FlushFrontMatter(var S: TFrontMatterSuppressor;
  out AOut: string): Boolean;

implementation

{ The line starting at AStart (up to but not including #10), with a trailing #13
  stripped. ANext is the offset just past the #10 (or Length+1). False when
  AStart is past the end. }
function NextLine(const S: string; AStart: Integer; out ALine: string;
  out ANext: Integer): Boolean;
var
  P: Integer;
begin
  if AStart > Length(S) then
  begin
    ALine := '';
    ANext := AStart;
    Exit(False);
  end;
  P := AStart;
  while (P <= Length(S)) and (S[P] <> #10) do
    Inc(P);
  ALine := Copy(S, AStart, P - AStart);
  if (ALine <> '') and (ALine[Length(ALine)] = #13) then
    SetLength(ALine, Length(ALine) - 1);
  ANext := P + 1;
  Result := True;
end;

{ A line that is exactly the fence: `---` (surrounding spaces allowed). }
function IsFence(const ALine: string): Boolean;
begin
  Result := Trim(ALine) = '---';
end;

{ Strip surrounding quotes and whitespace from a scalar value. }
function Unquote(const S: string): string;
var
  T: string;
begin
  T := Trim(S);
  if (Length(T) >= 2) and
    (((T[1] = '"') and (T[Length(T)] = '"')) or
     ((T[1] = '''') and (T[Length(T)] = ''''))) then
    T := Copy(T, 2, Length(T) - 2);
  Result := Trim(T);
end;

{ Normalize a keyword: lowercase, trimmed, unquoted. }
function NormKeyword(const S: string): string;
begin
  Result := LowerCase(Unquote(S));
end;

{ Append AKeyword to AList unless empty or already present (order preserved). }
procedure AddKeyword(var AList: TStringArray; const AKeyword: string);
var
  I: Integer;
  K: string;
begin
  K := NormKeyword(AKeyword);
  if K = '' then
    Exit;
  for I := 0 to High(AList) do
    if AList[I] = K then
      Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := K;
end;

{ Split a `[a, b, c]`-style (or bare comma-separated) value into keywords. }
procedure AddKeywordsFromValue(var AList: TStringArray; const AValue: string);
var
  V: string;
  Parts: TStringArray;
  P, Start: Integer;
begin
  V := Trim(AValue);
  if (Length(V) >= 2) and (V[1] = '[') and (V[Length(V)] = ']') then
    V := Copy(V, 2, Length(V) - 2);
  { Split on commas, tolerating empty segments. }
  Parts := nil;
  Start := 1;
  for P := 1 to Length(V) + 1 do
    if (P > Length(V)) or (V[P] = ',') then
    begin
      SetLength(Parts, Length(Parts) + 1);
      Parts[High(Parts)] := Copy(V, Start, P - Start);
      Start := P + 1;
    end;
  for P := 0 to High(Parts) do
    AddKeyword(AList, Parts[P]);
end;

{ Parse the lines between the fences into a title and keywords. }
procedure ParseBlock(const ABlock: string; out ATitle: string;
  out AKeywords: TStringArray);
var
  Line, Key, Value: string;
  P, NextPos, Colon: Integer;
  LastKey: string;
begin
  ATitle := '';
  AKeywords := nil;
  LastKey := '';
  P := 1;
  while NextLine(ABlock, P, Line, NextPos) do
  begin
    P := NextPos;
    Line := Trim(Line);
    if Line = '' then
      Continue;
    if (Length(Line) >= 1) and (Line[1] = '-') then
    begin
      { A list item belongs to the most recent key. }
      if LastKey = 'keywords' then
        AddKeyword(AKeywords, Copy(Line, 2, MaxInt));
      Continue;
    end;
    Colon := Pos(':', Line);
    if Colon <= 0 then
      Continue;
    Key := LowerCase(Trim(Copy(Line, 1, Colon - 1)));
    Value := Copy(Line, Colon + 1, MaxInt);
    LastKey := Key;
    if Key = 'title' then
      ATitle := Unquote(Value)
    else if Key = 'keywords' then
      AddKeywordsFromValue(AKeywords, Value);
    { Unknown keys are ignored (the block is open-ended). }
  end;
end;

function ExtractReplyMeta(const ARaw: string): TReplyMeta;
var
  Line, BlockText, Preamble: string;
  NextPos, BlockStart, CloseStart, CloseNext, P, FenceAt: Integer;
  Found, HasContent: Boolean;
  Title: string;
  Keywords: TStringArray;

  { True when the candidate block carries a metadata KEY. Presence is the
    signal, not a non-empty value: `title:` with an empty value is still
    frontmatter (the model wrote a header), whereas a bare `---` rule or a table
    separator has no keys at all and must be left in the body untouched. }
  function BlockCarriesMeta(const ABlock: string): Boolean;
  var
    L, V, K: string;
    Q, R, C: Integer;
  begin
    Result := False;
    Q := 1;
    while NextLine(ABlock, Q, L, R) do
    begin
      Q := R;
      L := Trim(L);
      if (L = '') or (L[1] = '-') then
        Continue;
      C := Pos(':', L);
      if C <= 0 then
        Continue;
      K := LowerCase(Trim(Copy(L, 1, C - 1)));
      if (K = 'title') or (K = 'keywords') then
      begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  Result := Default(TReplyMeta);
  Result.HasMeta := False;
  Result.Body := ARaw;
  if ARaw = '' then
    Exit;

  { A LEADING block is the normal case: the first line is the fence. }
  if NextLine(ARaw, 1, Line, NextPos) and IsFence(Line) then
    FenceAt := 1
  else
  begin
    { Otherwise the model may have said something FIRST and emitted its
      frontmatter after (a quip, then the block). Scan for a fence line that
      begins a line, and keep the text before it as the start of the body.
      Only a block that actually carries a metadata key counts, so an ordinary
      thematic break or a table separator is never mistaken for frontmatter. }
    FenceAt := 0;
    P := 1;
    while NextLine(ARaw, P, Line, NextPos) do
    begin
      if IsFence(Line) and (P > 1) then
      begin
        FenceAt := P;
        Break;
      end;
      P := NextPos;
    end;
    if FenceAt = 0 then
      Exit;   { no fence at the start of any line: not frontmatter }
  end;

  BlockStart := FenceAt;
  { Advance past the opening fence line. }
  if not NextLine(ARaw, BlockStart, Line, NextPos) then
    Exit;
  BlockStart := NextPos;

  { Find the closing fence - or, tolerantly, a blank line after block content:
    the model often forgets the closing `---`, and a blank line is a reliable
    end-of-block signal (YAML frontmatter has no blank lines). The blank line is
    consumed; the body starts after it. A blank line with no content before it is
    not a close (that is a leading rule, not an empty block). }
  Found := False;
  HasContent := False;
  CloseStart := 0;
  CloseNext := 0;
  P := BlockStart;
  while NextLine(ARaw, P, Line, NextPos) do
  begin
    if IsFence(Line) then
    begin
      CloseStart := P;
      CloseNext := NextPos;
      Found := True;
      Break;
    end;
    if (Trim(Line) = '') and HasContent then
    begin
      CloseStart := P;
      CloseNext := NextPos;
      Found := True;
      Break;
    end;
    if Trim(Line) <> '' then
      HasContent := True;
    P := NextPos;
  end;
  if not Found then
    Exit;   { unterminated: not frontmatter }

  BlockText := Copy(ARaw, BlockStart, CloseStart - BlockStart);
  { A block with no metadata KEY is not frontmatter - it is an ordinary thematic
    break, a table separator, or a stray fence - so it stays in the body. }
  if not BlockCarriesMeta(BlockText) then
    Exit;
  ParseBlock(BlockText, Title, Keywords);

  Result.HasMeta := True;
  Result.Title := Title;
  Result.Keywords := Keywords;
  { The body is what came BEFORE the block (a preamble, kept - it is the model's
    words) followed by what came after it. Dropping the preamble would lose
    content, which is a worse bug than the one this fixes. }
  if FenceAt > 1 then
    Preamble := Copy(ARaw, 1, FenceAt - 1)
  else
    Preamble := '';
  Result.Body := Preamble + Copy(ARaw, CloseNext, MaxInt);
end;

function SuppressFrontMatter(var S: TFrontMatterSuppressor;
  const AChunk: string; out AOut: string): Boolean;
var
  Line, Rest: string;
  P, NextPos: Integer;
  HasContent: Boolean;
begin
  AOut := '';
  S.Pending := S.Pending + AChunk;
  if S.State = fmDone then
  begin
    AOut := S.Pending;
    S.Pending := '';
    Exit(AOut <> '');
  end;
  if S.State = fmUndecided then
  begin
    { Decide whether Pending is the start of a leading fence. `---` alone is
      undecided (the next char tells); `---` + newline starts a block; anything
      else is body. }
    if Length(S.Pending) < 3 then
    begin
      if Copy('---', 1, Length(S.Pending)) = S.Pending then
        Exit(False);   { still a possible fence prefix }
    end;
    if Copy(S.Pending, 1, 3) <> '---' then
    begin
      S.State := fmDone;
      AOut := S.Pending;
      S.Pending := '';
      Exit(AOut <> '');
    end;
    if Length(S.Pending) = 3 then
      Exit(False);   { `---` so far: wait for the next char }
    if S.Pending[4] = #10 then
    begin
      S.Pending := Copy(S.Pending, 5, MaxInt);
      S.State := fmInBlock;
    end
    else if S.Pending[4] = #13 then
    begin
      if Length(S.Pending) = 4 then
        Exit(False);   { `---\r`: wait for the \n }
      if S.Pending[5] = #10 then
      begin
        S.Pending := Copy(S.Pending, 6, MaxInt);
        S.State := fmInBlock;
      end
      else
      begin
        S.State := fmDone;
        AOut := S.Pending;
        S.Pending := '';
        Exit(AOut <> '');
      end;
    end
    else
    begin
      { `---x`: a rule or text, not a fence. }
      S.State := fmDone;
      AOut := S.Pending;
      S.Pending := '';
      Exit(AOut <> '');
    end;
  end;
  { fmInBlock: look for the closing fence line - or, tolerantly, a blank line
    after content (the model often forgets the closing `---`; a blank line ends
    the block, since YAML frontmatter has no blank lines). }
  P := 1;
  HasContent := False;
  while NextLine(S.Pending, P, Line, NextPos) do
  begin
    if IsFence(Line) and (NextPos <= Length(S.Pending)) then
    begin
      { The fence line is newline-terminated (NextPos <= Length): close, and
        the body starts after the newline. A fence with no trailing newline yet
        is not closed - more may be coming (the trailing \n would leak into the
        body otherwise). }
      Rest := Copy(S.Pending, NextPos, MaxInt);
      S.Pending := '';
      S.State := fmDone;
      AOut := Rest;
      Exit(AOut <> '');
    end;
    if (Trim(Line) = '') and HasContent then
    begin
      { A blank line after block content ends the block (the missing-fence case).
        The blank line is consumed; the body starts after it. }
      Rest := Copy(S.Pending, NextPos, MaxInt);
      S.Pending := '';
      S.State := fmDone;
      AOut := Rest;
      Exit(AOut <> '');
    end;
    if Trim(Line) <> '' then
      HasContent := True;
    P := NextPos;
  end;
  { No closing fence yet: keep buffering (nothing displayed). }
  Result := False;
end;

{ At the end of the reply: flush anything still withheld. A block that never
  closed (no fence, no blank line) is not frontmatter, so its bytes are body and
  must be shown - the streaming suppressor would otherwise have swallowed them. }
function FlushFrontMatter(var S: TFrontMatterSuppressor;
  out AOut: string): Boolean;
begin
  AOut := S.Pending;
  S.Pending := '';
  S.State := fmDone;
  Result := AOut <> '';
end;

end.
