unit markdown.frontmatter;
{ A UTILITY, not part of the parse.

  The parser (markdown.tree) is plain GFM and treats a leading `---` as a
  thematic break like any other. It does not detect, extract or signal
  frontmatter. Recognising that a document HAS frontmatter is the HARNESS's
  responsibility: this unit exists so the harness can ask, without the parser
  knowing the answer is interesting.

  Why it is separate rather than a field on TMdDocument: a field would BE the
  signal. The parser would be deciding that frontmatter exists and handing it
  over, which is the parser taking a position on a protocol concern. As a utility,
  a caller that does not care about frontmatter never learns it was there.

  It is still pure - RTL only, no tui.*, no hildegard.helper.* - so a consumer
  can use it anywhere the parser is usable. `make markdown-standalone` proves it.

  Scope: FENCED frontmatter only (a `---` line, entries, a closing `---` line),
  and flat `key: value` entries. A nested YAML tree is a different feature; this
  reports the pairs and lets the caller interpret them, which keeps it from
  guessing at YAML's edge cases. }

{$mode delphi}{$H+}

interface

type
  TMdFrontEntry = record
    Key: UnicodeString;
    Value: UnicodeString;
  end;
  TMdFrontEntries = array of TMdFrontEntry;

{ True when AText begins with a frontmatter block: a `---` line, a closing
  `---` line, and the block is the FIRST thing in the document.

  A leading `---` with no closing fence is NOT frontmatter - it is ordinary
  markdown (a thematic break), and reporting it as frontmatter would let a stray
  rule swallow the document. }
function HasFrontmatter(const AText: string): Boolean;

{ The entries between the fences, in document order. Empty when there is no
  frontmatter block. A line with no colon is returned as a key with an empty
  value rather than dropped: a malformed entry should be visible to the caller,
  not silently vanish.

  AValue is the block's inner text verbatim (without the fence lines), so a
  caller that wants to parse it itself can. }
function ExtractFrontmatter(const AText: string;
  out AEntries: TMdFrontEntries; out ARaw: UnicodeString): Boolean;

{ Remove a leading frontmatter block, returning the body. Unchanged when there
  is none. }
function StripFrontmatter(const AText: string): string;

implementation

uses
  SysUtils;

function IsFenceLine(const ALine: string): Boolean;
begin
  Result := Trim(ALine) = '---';
end;

{ The byte offset just past line AStart, or Length(AText) + 1 at the end. }
function NextLineStart(const AText: string; const AStart: Integer): Integer;
var
  P: Integer;
begin
  P := Pos(#10, Copy(AText, AStart, Length(AText)));
  if P = 0 then
    Result := Length(AText) + 1
  else
    Result := AStart + P;
end;

{ Locate the block. Returns True and the first/last inner line offsets when
  AText begins with a closed fence block. }
function LocateBlock(const AText: string; out AInnerStart, ACloseStart: Integer): Boolean;
var
  FirstEnd, P, LineStart: Integer;
  Line: string;
begin
  Result := False;
  AInnerStart := 0;
  ACloseStart := 0;
  if AText = '' then
    Exit;
  FirstEnd := NextLineStart(AText, 1);
  Line := Copy(AText, 1, FirstEnd - 1);
  if not IsFenceLine(Line) then
    Exit;
  AInnerStart := FirstEnd;
  P := FirstEnd;
  while P <= Length(AText) do
  begin
    LineStart := P;
    P := NextLineStart(AText, P);
    Line := Copy(AText, LineStart, P - LineStart);
    if IsFenceLine(Line) then
    begin
      ACloseStart := LineStart;
      Exit(True);
    end;
  end;
  { No closing fence: NOT frontmatter, so a stray rule cannot eat the document. }
  AInnerStart := 0;
end;

function HasFrontmatter(const AText: string): Boolean;
var
  Inner, Close: Integer;
begin
  Result := LocateBlock(AText, Inner, Close);
end;

function ExtractFrontmatter(const AText: string;
  out AEntries: TMdFrontEntries; out ARaw: UnicodeString): Boolean;
var
  Inner, Close, P, LineStart, C: Integer;
  Line, Trimmed: string;
begin
  AEntries := nil;
  ARaw := '';
  Result := LocateBlock(AText, Inner, Close);
  if not Result then
    Exit;
  if Close > Inner then
    ARaw := UnicodeString(Copy(AText, Inner, Close - Inner));
  { Strip one trailing newline from the raw block, so it joins cleanly. }
  if (ARaw <> '') and (ARaw[Length(ARaw)] = #10) then
    SetLength(ARaw, Length(ARaw) - 1);
  if (ARaw <> '') and (ARaw[Length(ARaw)] = #13) then
    SetLength(ARaw, Length(ARaw) - 1);

  P := Inner;
  while P < Close do
  begin
    LineStart := P;
    P := NextLineStart(AText, P);
    Line := Copy(AText, LineStart, P - LineStart);
    if (Line <> '') and (Line[Length(Line)] = #10) then
      SetLength(Line, Length(Line) - 1);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    Trimmed := Trim(Line);
    { A blank line or a comment is not an entry. }
    if (Trimmed = '') or (Trimmed[1] = '#') then
      Continue;
    SetLength(AEntries, Length(AEntries) + 1);
    AEntries[High(AEntries)].Key := '';
    AEntries[High(AEntries)].Value := '';
    C := Pos(':', Trimmed);
    if C > 0 then
    begin
      AEntries[High(AEntries)].Key :=
        UnicodeString(Trim(Copy(Trimmed, 1, C - 1)));
      AEntries[High(AEntries)].Value :=
        UnicodeString(Trim(Copy(Trimmed, C + 1, Length(Trimmed))));
    end
    else
      AEntries[High(AEntries)].Key := UnicodeString(Trimmed);
  end;
end;

function StripFrontmatter(const AText: string): string;
var
  Inner, Close: Integer;
begin
  Result := AText;
  if not LocateBlock(AText, Inner, Close) then
    Exit;
  { Past the closing fence's line. }
  Result := Copy(AText, NextLineStart(AText, Close), Length(AText));
end;

end.
