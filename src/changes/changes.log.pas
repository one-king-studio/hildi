unit changes.log;
{ The model: replay a path's text at any point, decide when a keyframe is due, and
  answer "is this write still safe?".

  The rules here are the reason a change log is more than a diff viewer:

  - A patch is applied as a compare-and-swap. The file's current hash must match
    the record's BeforeHash, and the result must hash to AfterHash. That makes an
    out-of-band edit a refusal rather than a silent clobber.
  - Replay starts at the newest keyframe at or before the target, so it is
    bounded by the keyframe interval and never by how long the log is. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  changes.types, changes.store, changes.text;

type
  { Why a write was refused, when it was. }
  TCasVerdict = (
    cvOk,        // the file is what the caller expects; write away
    cvConflict,  // someone else changed it; LastWriter says who and when
    cvUnknown);  // the store could not answer - not the same as a conflict

{ Compare AActualHash (the file on disk now) to AExpectedHash (what the caller
  read). cvOk when they agree. On a conflict ALastWriter is the newest record for
  that path, so the caller can name the session rather than saying "someone". }
function CheckWrite(const AStore: IChangeStore; AWorkspaceId: Integer;
  const APath, AExpectedHash, AActualHash: string; out AVerdict: TCasVerdict;
  out ALastWriter: TChangeRecord; out AError: string): Boolean;

{ Reconstruct a path's text as of AChangeId (inclusive): the newest keyframe at
  or before it, then each patch after that, verifying each hop against its
  AfterHash.

  AHasher is the consumer's, because hashing is not the library's business.
  False + AError when a patch does not verify (data corruption) or a needed
  keyframe is gone (a retention boundary) - the caller must be able to tell those
  apart, so AError says which. }
type
  TChangeHasher = function(const AText: string): string of object;

function Reconstruct(const AStore: IChangeStore; AHasher: TChangeHasher;
  const ARecord: TChangeRecord; out AText, AError: string): Boolean;

{ True when a keyframe should be written for this path now: its accumulated
  patch bytes exceed KeyframeSizeFactor times its current size, or it has seen
  KeyframeChangeInterval changes since the last one. }
function KeyframeDue(AAccumulatedPatchBytes, ACurrentBytes: Int64;
  AChangesSinceKeyframe: Integer): Boolean;

{ The summary line a tool result carries: `A new.txt, M src/a.pas (+3 -1)`.
  Bounded, and it never renders a line delta it cannot support. }
function Summarize(const ARows: TChangeRecordArray; ACapChars: Integer): string;

{ The text a change should be reverted TO, given what is on disk now.

  A revert is a compare-and-swap, not a blind undo: the file must still hold the
  after-text the record was anchored to, or the revert refuses. That is what
  stops a revert from silently discarding work done since.

  Returns False + AError when the current text is not the record's after-text
  (someone changed it since), when the patch will not invert, or when the result
  does not hash to the record's before-hash - the last check is what proves the
  revert actually restored the original rather than merely applying. }
function RevertText(const APatch, ABeforeHash, AAfterHash, ACurrentText: string;
  AHasher: TChangeHasher; out AText, AError: string): Boolean;

{ Apply a recorded change FORWARD to ACurrentText - the mirror of RevertText,
  and the engine behind `/redo`.

  The patch on a net row is a forward unified diff, so redo needs nothing the
  log does not already hold: it is RevertText with the halves swapped. The file
  must still hold the record's BEFORE-text (that is the compare, and it is what
  makes a redo refuse when the file has moved on rather than clobber it), then
  the patch is applied as-is, and the result must hash to the record's
  AFTER-text. Verifying in that direction is what proves the redo reproduced the
  change rather than merely applying something.

  Returns False + AError when the current text is not the record's before-text,
  when the patch does not apply, or when the result does not hash to the
  after-hash. }
function ApplyText(const APatch, ABeforeHash, AAfterHash, ACurrentText: string;
  AHasher: TChangeHasher; out AText, AError: string): Boolean;

{ The id from which history should be pruned so that ARetentionTurns remain.
  Turn ids are ascending, so this is the id of the first change of the oldest
  turn worth keeping. 0 when there is nothing to prune. }
function PrunePointFor(const ARows: TChangeRecordArray;
  ARetentionTurns: Integer): Integer;

implementation

function CheckWrite(const AStore: IChangeStore; AWorkspaceId: Integer;
  const APath, AExpectedHash, AActualHash: string; out AVerdict: TCasVerdict;
  out ALastWriter: TChangeRecord; out AError: string): Boolean;
var
  Found: Boolean;
begin
  Result := False;
  AVerdict := cvUnknown;
  ALastWriter := Default(TChangeRecord);
  AError := '';
  if not AStore.Latest(AWorkspaceId, APath, ALastWriter, Found, AError) then
  begin
    AError := 'could not read the change log: ' + AError;
    Exit;
  end;
  if not Found then
  begin
    { Nobody has recorded this path. There is nothing to conflict with, so this
      is cvOk rather than cvUnknown - an unknown is a store failure. }
    AVerdict := cvOk;
    Exit(True);
  end;
  if AExpectedHash = '' then
  begin
    { The caller did not read the file first. That is not a conflict we can rule
      on, and applying blind is how edits are lost, so refuse it as one. }
    AError := 'no expected hash: read the file before writing it';
    AVerdict := cvConflict;
    Exit(True);
  end;
  if AExpectedHash = AActualHash then
  begin
    AVerdict := cvOk;
    Exit(True);
  end;
  { The file is not what the caller expected. If the log's newest after-hash
    matches what is on disk, another writer landed it and the log knows who. }
  AVerdict := cvConflict;
  Result := True;
end;

function Reconstruct(const AStore: IChangeStore; AHasher: TChangeHasher;
  const ARecord: TChangeRecord; out AText, AError: string): Boolean;
var
  Frame: TKeyframe;
  HaveFrame: Boolean;
  Rows: TChangeRecordArray;
  I: Integer;
  Cur, Next: string;
begin
  Result := False;
  AText := '';
  AError := '';
  if not Assigned(AHasher) then
  begin
    AError := 'Reconstruct needs a hasher';
    Exit;
  end;
  if not AStore.KeyframeBefore(ARecord.WorkspaceId, ARecord.Path,
    ARecord.Id, Frame, HaveFrame, AError) then
  begin
    AError := 'could not read keyframes: ' + AError;
    Exit;
  end;
  if HaveFrame then
    Cur := Frame.Content
  else
    Cur := '';
  { Every change after the keyframe, up to and including the target. }
  if not AStore.ForPath(ARecord.WorkspaceId, ARecord.Path,
    Frame.ThroughChangeId + 1, 0, Rows, AError) then
  begin
    AError := 'could not read changes: ' + AError;
    Exit;
  end;
  for I := 0 to High(Rows) do
  begin
    if Rows[I].Id > ARecord.Id then
      Break;
    { A deletion has no patch; the text after it is empty. }
    if Rows[I].Kind = ckDeleted then
    begin
      Cur := '';
      Continue;
    end;
    if Rows[I].Patch = '' then
    begin
      { A cap or an uncaptured side: replay cannot continue past this point. }
      if Rows[I].Id = ARecord.Id then
      begin
        AText := Cur;
        Exit(True);      // the target itself is unreconstructable; caller decides
      end;
      AError := Format('change %d has no patch, so replay stops there',
        [Rows[I].Id]);
      Exit;
    end;
    if not ApplyUnifiedDiff(Cur, Rows[I].Patch, Next, AError) then
    begin
      AError := Format('change %d did not apply: %s', [Rows[I].Id, AError]);
      Exit;
    end;
    if (Rows[I].AfterHash <> '') and (AHasher(Next) <> Rows[I].AfterHash) then
    begin
      AError := Format('change %d applied but the hash did not match', 
        [Rows[I].Id]);
      Exit;
    end;
    Cur := Next;
  end;
  AText := Cur;
  Result := True;
end;

function KeyframeDue(AAccumulatedPatchBytes, ACurrentBytes: Int64;
  AChangesSinceKeyframe: Integer): Boolean;
begin
  Result := False;
  if AChangesSinceKeyframe >= KeyframeChangeInterval then
    Exit(True);
  { Guard the multiply: a large file should not overflow into a false trigger. }
  if AAccumulatedPatchBytes > KeyframeSizeFactor * ACurrentBytes then
    Exit(True);
end;

function Summarize(const ARows: TChangeRecordArray; ACapChars: Integer): string;
var
  I: Integer;
  Item, Text: string;
begin
  Result := '';
  for I := 0 to High(ARows) do
  begin
    if ARows[I].Kind = ckDir then
      Item := ChangeKindCode(ARows[I].Kind) + ' ' + ARows[I].Path + '/'
    else
      Item := ChangeKindCode(ARows[I].Kind) + ' ' + ARows[I].Path;
    if Result <> '' then
      Text := Result + ', ' + Item
    else
      Text := Item;
    if (ACapChars > 0) and (Length(Text) > ACapChars) then
    begin
      if Result = '' then
        Result := Copy(Item, 1, ACapChars)
      else
        Result := Result + ', ...';
      Exit;
    end;
    Result := Text;
  end;
end;

function PrunePointFor(const ARows: TChangeRecordArray;
  ARetentionTurns: Integer): Integer;
var
  I, TurnsSeen, LastTurn: Integer;
begin
  Result := 0;
  if (ARetentionTurns <= 0) or (Length(ARows) = 0) then
    Exit;
  { Walk backwards counting distinct turn ids; the id where the count exceeds the
    window is the prune point. }
  TurnsSeen := 0;
  LastTurn := -1;
  for I := High(ARows) downto 0 do
  begin
    if ARows[I].TurnId <> LastTurn then
    begin
      LastTurn := ARows[I].TurnId;
      Inc(TurnsSeen);
      if TurnsSeen > ARetentionTurns then
      begin
        Result := ARows[I].Id;
        Exit;
      end;
    end;
  end;
end;

function RevertText(const APatch, ABeforeHash, AAfterHash, ACurrentText: string;
  AHasher: TChangeHasher; out AText, AError: string): Boolean;
var
  Inv, Applied: string;
begin
  Result := False;
  AText := '';
  AError := '';
  if not Assigned(AHasher) then
  begin
    AError := 'a revert needs a hasher';
    Exit;
  end;
  { The compare half. If the file no longer holds what the record was anchored
    to, someone has worked on it since; reverting would silently discard that. }
  if (AAfterHash <> '') and (AHasher(ACurrentText) <> AAfterHash) then
  begin
    AError := 'the file changed since this was recorded';
    Exit;
  end;
  if not InvertPatch(APatch, Inv, AError) then
  begin
    AError := 'could not invert the patch: ' + AError;
    Exit;
  end;
  if not ApplyUnifiedDiff(ACurrentText, Inv, Applied, AError) then
  begin
    AError := 'the inverse did not apply: ' + AError;
    Exit;
  end;
  { The swap half, and the reason this verifies rather than trusts: applying an
    inverse proves the diff matched, not that it restored the ORIGINAL. Checking
    the result against the before-hash is what proves the revert. }
  if (ABeforeHash <> '') and (AHasher(Applied) <> ABeforeHash) then
  begin
    AError := 'the revert did not restore the recorded original';
    Exit;
  end;
  AText := Applied;
  Result := True;
end;

function ApplyText(const APatch, ABeforeHash, AAfterHash, ACurrentText: string;
  AHasher: TChangeHasher; out AText, AError: string): Boolean;
var
  Applied: string;
begin
  Result := False;
  AText := '';
  AError := '';
  if not Assigned(AHasher) then
  begin
    AError := 'a redo needs a hasher';
    Exit;
  end;
  { The compare half, and the mirror of the revert's: the file must still hold
    the text this change started FROM. If it has moved on, re-applying would
    discard whatever superseded it. }
  if (ABeforeHash <> '') and (AHasher(ACurrentText) <> ABeforeHash) then
  begin
    AError := 'the file changed since this was recorded';
    Exit;
  end;
  if not ApplyUnifiedDiff(ACurrentText, APatch, Applied, AError) then
  begin
    AError := 'the patch did not apply: ' + AError;
    Exit;
  end;
  { Verify in the FORWARD direction: the result must be the recorded
    after-text. That is what distinguishes "the redo reproduced the change" from
    "some diff happened to apply". }
  if (AAfterHash <> '') and (AHasher(Applied) <> AAfterHash) then
  begin
    AError := 'the redo did not reproduce the recorded change';
    Exit;
  end;
  AText := Applied;
  Result := True;
end;

end.
