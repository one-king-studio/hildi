unit hildegard.helper.board;
{ The workspace board: append-only entries with supersession.

  A board entry is a FACT: it is never edited, a correction supersedes it by
  pointer, and the history is the point. That is what separates it from the task
  list, whose status is mutable state by definition.

  Nothing here knows about SQLite: persistence is IBoardStore, supplied by the
  consumer, the same seam the changes library uses. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TBoardKind = (
    bkNote,      // a scratchpad line: "remind myself later"
    bkQuestion,  // blocked on something, asking anyone
    bkAnswer,    // a reply to a question
    bkDecision,  // a choice that was settled, with its rationale
    bkFinding,   // a discovered fact about the codebase or the task
    bkStatus);   // what I am working on right now

const
  BoardKindNames: array[TBoardKind] of string = (
    'note', 'question', 'answer', 'decision', 'finding', 'status');

type
  TStringArrayLite = array of string;

  TBoardEntry = record
    Id: Integer;
    WorkspaceId: Integer;
    Kind: TBoardKind;
    Topic: string;            // slug: the page identity
    Title: string;            // one line: what a notice shows
    Body: string;             // Markdown: the detail
    ReplyTo: Integer;         // 0 => not a reply
    Supersedes: Integer;      // 0 => not a correction
    Paths: TStringArrayLite;  // workspace paths this entry is about
    FromSession, FromLabel: string;
    DeletedAt: Int64;         // 0 => live
    DeletedBy: string;
    Pinned: Boolean;
    CreatedAt: Int64;
    { Filled by a read, never stored: }
    Current: Boolean;         // newest live, non-superseded entry in its topic
    StaleCount: Integer;      // changes to Paths since this was written
  end;

  TBoardEntryArray = array of TBoardEntry;

  TBoardFilter = record
    Topic: string;            // '' => any
    Kind: TBoardKind;
    KindSet: Boolean;         // False => any kind
    SinceId: Integer;         // 0 => from the beginning
    Limit: Integer;           // 0 => default
    IncludeDeleted: Boolean;
  end;

  TBoardModOp = (bmDelete, bmRestore, bmLock, bmUnlock, bmPin, bmUnpin);

const
  BoardModOpNames: array[TBoardModOp] of string = (
    'delete', 'restore', 'lock', 'unlock', 'pin', 'unpin');

  DefaultBoardReadLimit = 20;
  { Retention for the noise classes. Knowledge - decision, finding, question,
    answer - is never pruned. }
  DefaultBoardKeepNotes = 200;
  DefaultBoardNoteMaxAgeSec = 30 * 24 * 60 * 60;   // 30 days
  { The tail element is data only; the prose lives in the system prompt. }
  MaxBoardTocBytes = 120;

function BoardKindFromName(const AName: string; out AKind: TBoardKind): Boolean;
function BoardKindToName(AKind: TBoardKind): string;
{ The six valid names, for an error message that teaches. }
function BoardKindList: string;

{ A newline-joined path list <-> the array a record carries. Newline rather than
  a join table: the count is small and the only query is "which of these
  changed". }
function PathsToText(const APaths: TStringArrayLite): string;
function TextToPaths(const AText: string): TStringArrayLite;

implementation

function BoardKindToName(AKind: TBoardKind): string;
begin
  Result := BoardKindNames[AKind];
end;

function BoardKindFromName(const AName: string; out AKind: TBoardKind): Boolean;
var
  K: TBoardKind;
begin
  Result := False;
  AKind := bkNote;
  for K := Low(TBoardKind) to High(TBoardKind) do
    if SameText(AName, BoardKindNames[K]) then
    begin
      AKind := K;
      Exit(True);
    end;
end;

function BoardKindList: string;
var
  K: TBoardKind;
begin
  Result := '';
  for K := Low(TBoardKind) to High(TBoardKind) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + BoardKindNames[K];
  end;
end;

function PathsToText(const APaths: TStringArrayLite): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(APaths) do
  begin
    if APaths[I] = '' then
      Continue;
    if Result <> '' then
      Result := Result + #10;
    Result := Result + APaths[I];
  end;
end;

function TextToPaths(const AText: string): TStringArrayLite;
var
  P, Start, N: Integer;
  Line: string;
begin
  Result := nil;
  N := 0;
  P := 1;
  while P <= Length(AText) do
  begin
    Start := P;
    while (P <= Length(AText)) and (AText[P] <> #10) do
      Inc(P);
    Line := Trim(Copy(AText, Start, P - Start));
    if Line <> '' then
    begin
      SetLength(Result, N + 1);
      Result[N] := Line;
      Inc(N);
    end;
    Inc(P);
  end;
end;

end.
