unit hildegard.helper.changes.revert;
{ Apply a recorded change back to disk - the filesystem half of revert.

  The library decides WHAT the reverted text is (`changes.log.RevertText`: compare,
  invert, apply, verify against the before-hash). This unit decides WHETHER it is
  safe to write: the path must be inside the workspace, the bytes must be read at
  a bounded size, and the write must be atomic so a failed revert never leaves a
  half-written file.

  A revert is a compare-and-swap, not a blind undo. Every refusal says why, and
  nothing is written when a check fails - a wrong revert is data loss, so a
  refusal is always the better outcome. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  changes.types, changes.log,
  hildegard.helper.workspace, hildegard.helper.hash;

type
  { The production hasher: TChangeHasher backed by the same Sha256Hex the
    recorder stamps with. A caller that passed a different function would have
    every revert rejected at the verify step, so this exists to make the correct
    choice the easy one. }
  TSha256Hasher = class
  public
    function OfText(const AText: string): string;
  end;

type
  TRevertOutcome = (
    rvReverted,      // the file was restored
    rvSkipped,       // nothing to do: the record carries no patch
    rvUnsafe,        // refused: outside the workspace, or too large to read
    rvMoved,         // refused: the file changed since the record was written
    rvFailed);       // refused: the patch would not invert or verify

  TRevertResult = record
    Outcome: TRevertOutcome;
    Path: string;
    Detail: string;   // why, when not rvReverted
  end;

  TRevertResultArray = array of TRevertResult;

{ Revert one record's change in the file it names, under ARoot.

  A record with no patch is SKIPPED rather than failed: the process tier captures
  the after-text but never the before-text, so those records carry sizes and no
  diff. Reporting them as failures would bury the ones that can be reverted.

  AHasher must be the same function the recorder used, or the verify step will
  reject every revert. AMaxBytes bounds what is read; a larger file is refused
  rather than read partially, because a partial read cannot be verified. }
function RevertRecord(const ARoot: string; const ARecord: TChangeRecord;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResult: TRevertResult): Boolean;

{ Revert one TURN: every net row it wrote, one file at a time.

  A turn is the unit `/undo` moves, and it must be all-or-nothing in spirit: if
  any file would be refused, the whole turn is refused BEFORE anything is
  written, so the transcript and the workspace cannot disagree. That pre-flight
  is why this reads every file first and only then writes.

  Only NET rows are reverted. Per-call rows include edits a later call in the
  same turn undid; applying those in order would trample the net result.

  Returns True when the turn reached a decision (reverted, or refused with a
  reason), False only on a store failure. }
function RevertTurn(const ARoot: string; const ARows: TChangeRecordArray;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResults: TRevertResultArray): Boolean;

{ Apply one record's change FORWARD again - the filesystem half of `/redo`.

  The exact mirror of RevertRecord: the patch on a net row is a forward diff, so
  a redo is the same compare-and-swap with the guard on the before-hash instead
  of the after-hash. The outcome names are the revert's on purpose - a redo
  refused for the same four reasons is the same four answers, and the operator
  does not need a second vocabulary for "it moved on". }
function ApplyRecord(const ARoot: string; const ARecord: TChangeRecord;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResult: TRevertResult): Boolean;

{ Apply one TURN forward: every net row it wrote, all-or-nothing, with the same
  pre-flight as RevertTurn. Redo walks the suffix the undo took away OLDEST
  first, so each turn's before-hash matches what the previous one left behind -
  the mirror of undo's newest-first order. }
function ApplyTurn(const ARoot: string; const ARows: TChangeRecordArray;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResults: TRevertResultArray): Boolean;

implementation

function TSha256Hasher.OfText(const AText: string): string;
begin
  Result := Sha256Hex(AText);
end;

const
  { Above this, refuse rather than read: a revert that cannot verify the whole
    file must not write at all. }
  DefaultMaxBytes = 8 * 1024 * 1024;

function SysReadText(const APath: string; AMaxBytes: Integer;
  out AText: string; out ATooLarge: Boolean; out AError: string): Boolean;
var
  Fs: TFileStream;
begin
  Result := False;
  AText := '';
  ATooLarge := False;
  AError := '';
  if not FileExists(APath) then
  begin
    AError := 'no such file';
    Exit;
  end;
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      if Fs.Size > AMaxBytes then
      begin
        ATooLarge := True;
        AError := Format('file is %d bytes, above the %d-byte revert limit',
          [Fs.Size, AMaxBytes]);
        Exit;
      end;
      SetLength(AText, Fs.Size);
      if Fs.Size > 0 then
        Fs.ReadBuffer(AText[1], Fs.Size);
    finally
      Fs.Free;
    end;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

function SysWriteAtomic(const APath, AContent: string;
  out AError: string): Boolean;
var
  Tmp: string;
  Fs: TFileStream;
begin
  Result := False;
  AError := '';
  Tmp := APath + '.hh-revert-tmp';
  try
    Fs := TFileStream.Create(Tmp, fmCreate);
    try
      if AContent <> '' then
        Fs.WriteBuffer(AContent[1], Length(AContent));
    finally
      Fs.Free;
    end;
    DeleteFile(APath);
    if not RenameFile(Tmp, APath) then
    begin
      AError := 'could not replace the file';
      DeleteFile(Tmp);
      Exit;
    end;
  except
    on E: Exception do
    begin
      DeleteFile(Tmp);
      AError := E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

function RevertRecord(const ARoot: string; const ARecord: TChangeRecord;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResult: TRevertResult): Boolean;
var
  Full, Current, Reverted, Err: string;
  TooLarge: Boolean;
  Ok: Boolean;
begin
  Result := False;
  AResult := Default(TRevertResult);
  AResult.Path := ARecord.Path;
  if AMaxBytes <= 0 then
    AMaxBytes := DefaultMaxBytes;

  { Nothing to undo: the process tier records sizes with no patch. }
  if ARecord.Patch = '' then
  begin
    AResult.Outcome := rvSkipped;
    AResult.Detail := 'no patch was captured for this change';
    Exit(True);
  end;

  { Confinement, before reading anything: a record names a relative path, but a
    corrupted or hand-edited row must not be able to write outside the root. }
  if not PhysicalContains(ARoot, ARecord.Path) then
  begin
    AResult.Outcome := rvUnsafe;
    AResult.Detail := 'the path is outside the workspace';
    Exit(True);
  end;
  Full := IncludeTrailingPathDelimiter(ARoot) + ARecord.Path;

  if not SysReadText(Full, AMaxBytes, Current, TooLarge, Err) then
  begin
    if TooLarge then
    begin
      AResult.Outcome := rvUnsafe;
      AResult.Detail := Err;
    end
    else
    begin
      AResult.Outcome := rvFailed;
      AResult.Detail := Err;
    end;
    Exit(True);
  end;

  Ok := RevertText(ARecord.Patch, ARecord.BeforeHash, ARecord.AfterHash,
    Current, AHasher, Reverted, Err);
  if not Ok then
  begin
    { A compare failure means the file moved on; anything else means the record
      will not invert. The two are different problems and the operator needs to
      tell them apart. }
    if Pos('changed since', Err) > 0 then
      AResult.Outcome := rvMoved
    else
      AResult.Outcome := rvFailed;
    AResult.Detail := Err;
    Exit(True);
  end;

  if not SysWriteAtomic(Full, Reverted, Err) then
  begin
    AResult.Outcome := rvFailed;
    AResult.Detail := Err;
    Exit(True);
  end;

  AResult.Outcome := rvReverted;
  Result := True;
end;

function RevertTurn(const ARoot: string; const ARows: TChangeRecordArray;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResults: TRevertResultArray): Boolean;
var
  I, N: Integer;
  R: TChangeRecord;
  Res: TRevertResult;
  Planned: array of TRevertResult;
  Reverted: array of string;
  Current, Text, Err: string;
  TooLarge, Ok: Boolean;
begin
  { Two passes on purpose. The first decides for every file, with nothing
    written; the second writes only if EVERY file was revertible. A turn that
    reverted half its files and then refused the rest would leave the transcript
    and the workspace disagreeing, which is worse than refusing outright. }
  Result := False;
  AResults := nil;
  Planned := nil;
  { 0 means "the caller did not care"; without this, every file reads as
    oversized and the whole turn reports rvUnsafe. }
  if AMaxBytes <= 0 then
    AMaxBytes := DefaultMaxBytes;

  for I := 0 to High(ARows) do
  begin
    R := ARows[I];
    { Only net rows describe what the turn did. }
    if not R.IsNet then
      Continue;
    Res := Default(TRevertResult);
    Res.Path := R.Path;
    if R.Patch = '' then
    begin
      Res.Outcome := rvSkipped;
      Res.Detail := 'no patch was captured for this change';
    end
    else if not PhysicalContains(ARoot, R.Path) then
    begin
      Res.Outcome := rvUnsafe;
      Res.Detail := 'the path is outside the workspace';
    end
    else if not SysReadText(IncludeTrailingPathDelimiter(ARoot) + R.Path,
      AMaxBytes, Current, TooLarge, Err) then
    begin
      if TooLarge then
        Res.Outcome := rvUnsafe
      else
        Res.Outcome := rvFailed;
      Res.Detail := Err;
    end
    else if not RevertText(R.Patch, R.BeforeHash, R.AfterHash, Current, AHasher,
      Text, Err) then
    begin
      if Pos('changed since', Err) > 0 then
        Res.Outcome := rvMoved
      else
        Res.Outcome := rvFailed;
      Res.Detail := Err;
    end
    else
    begin
      Res.Outcome := rvReverted;   // planned, not yet written
      N := Length(Planned);
      SetLength(Planned, N + 1);
      Planned[N] := Res;
      SetLength(Reverted, N + 1);
      Reverted[N] := Text;
      Continue;                    // nothing to record below
    end;
    { A refusal: the whole turn is refused, so record it and stop planning. }
    SetLength(Planned, Length(Planned) + 1);
    Planned[High(Planned)] := Res;
  end;

  { Any refusal fails the turn before a single byte is written. Skipped rows are
    not refusals: they are files that cannot be reverted at all. }
  for I := 0 to High(Planned) do
    if (Planned[I].Outcome <> rvReverted) and
      (Planned[I].Outcome <> rvSkipped) then
    begin
      AResults := Planned;
      Exit(True);   { decided: refused, nothing written }
    end;

  { All clear: write. }
  N := 0;
  for I := 0 to High(Planned) do
    if Planned[I].Outcome = rvReverted then
    begin
      Ok := SysWriteAtomic(
        IncludeTrailingPathDelimiter(ARoot) + Planned[I].Path, Reverted[N], Err);
      Inc(N);
      if not Ok then
      begin
        { Half-written is the one outcome worth reporting as a hard failure: the
          pre-flight said every file was safe, so this is an I/O fault. }
        Planned[I].Outcome := rvFailed;
        Planned[I].Detail := Err;
        AResults := Planned;
        Exit(True);
      end;
    end;

  AResults := Planned;
  Result := True;
end;

{ --- redo: the same engine, run forwards -------------------------------- }

type
  { RevertText and ApplyText are deliberately signature-identical: one inverts
    the patch and verifies against the before-hash, the other applies it and
    verifies against the after-hash. Passing the transform in is what makes redo
    PROVABLY the mirror of revert rather than a second copy that can drift out
    of step with the refusal rules. }
  TTextTransform = function(const APatch, ABeforeHash, AAfterHash,
    ACurrentText: string; AHasher: TChangeHasher; out AText,
    AError: string): Boolean;

function RunRecord(const ARoot: string; const ARecord: TChangeRecord;
  AHasher: TChangeHasher; AMaxBytes: Integer; AOp: TTextTransform;
  out AResult: TRevertResult): Boolean;
var
  Full, Current, Produced, Err: string;
  TooLarge, Ok: Boolean;
begin
  Result := False;
  AResult := Default(TRevertResult);
  AResult.Path := ARecord.Path;
  if AMaxBytes <= 0 then
    AMaxBytes := DefaultMaxBytes;

  { Nothing to move: the process tier records sizes with no patch. }
  if ARecord.Patch = '' then
  begin
    AResult.Outcome := rvSkipped;
    AResult.Detail := 'no patch was captured for this change';
    Exit(True);
  end;

  { Confinement, before reading anything: a record names a relative path, but a
    corrupted or hand-edited row must not be able to write outside the root. }
  if not PhysicalContains(ARoot, ARecord.Path) then
  begin
    AResult.Outcome := rvUnsafe;
    AResult.Detail := 'the path is outside the workspace';
    Exit(True);
  end;
  Full := IncludeTrailingPathDelimiter(ARoot) + ARecord.Path;

  if not SysReadText(Full, AMaxBytes, Current, TooLarge, Err) then
  begin
    if TooLarge then
      AResult.Outcome := rvUnsafe
    else
      AResult.Outcome := rvFailed;
    AResult.Detail := Err;
    Exit(True);
  end;

  Ok := AOp(ARecord.Patch, ARecord.BeforeHash, ARecord.AfterHash, Current,
    AHasher, Produced, Err);
  if not Ok then
  begin
    { A compare failure means the file moved on; anything else means the record
      will not transform. The two are different problems. }
    if Pos('changed since', Err) > 0 then
      AResult.Outcome := rvMoved
    else
      AResult.Outcome := rvFailed;
    AResult.Detail := Err;
    Exit(True);
  end;

  if not SysWriteAtomic(Full, Produced, Err) then
  begin
    AResult.Outcome := rvFailed;
    AResult.Detail := Err;
    Exit(True);
  end;

  AResult.Outcome := rvReverted;
  Result := True;
end;

function RunTurn(const ARoot: string; const ARows: TChangeRecordArray;
  AHasher: TChangeHasher; AMaxBytes: Integer; AOp: TTextTransform;
  out AResults: TRevertResultArray): Boolean;
var
  I, N: Integer;
  R: TChangeRecord;
  Res: TRevertResult;
  Planned: array of TRevertResult;
  Produced: array of string;
  Current, Text, Err: string;
  TooLarge, Ok: Boolean;
begin
  { Two passes, for the same reason as the revert: decide every file with
    nothing written, then write only if every file was safe. }
  Result := False;
  AResults := nil;
  Planned := nil;
  if AMaxBytes <= 0 then
    AMaxBytes := DefaultMaxBytes;

  for I := 0 to High(ARows) do
  begin
    R := ARows[I];
    if not R.IsNet then
      Continue;
    Res := Default(TRevertResult);
    Res.Path := R.Path;
    if R.Patch = '' then
    begin
      Res.Outcome := rvSkipped;
      Res.Detail := 'no patch was captured for this change';
    end
    else if not PhysicalContains(ARoot, R.Path) then
    begin
      Res.Outcome := rvUnsafe;
      Res.Detail := 'the path is outside the workspace';
    end
    else if not SysReadText(IncludeTrailingPathDelimiter(ARoot) + R.Path,
      AMaxBytes, Current, TooLarge, Err) then
    begin
      if TooLarge then
        Res.Outcome := rvUnsafe
      else
        Res.Outcome := rvFailed;
      Res.Detail := Err;
    end
    else if not AOp(R.Patch, R.BeforeHash, R.AfterHash, Current, AHasher, Text,
      Err) then
    begin
      if Pos('changed since', Err) > 0 then
        Res.Outcome := rvMoved
      else
        Res.Outcome := rvFailed;
      Res.Detail := Err;
    end
    else
    begin
      Res.Outcome := rvReverted;   // planned, not yet written
      N := Length(Planned);
      SetLength(Planned, N + 1);
      Planned[N] := Res;
      SetLength(Produced, N + 1);
      Produced[N] := Text;
      Continue;
    end;
    SetLength(Planned, Length(Planned) + 1);
    Planned[High(Planned)] := Res;
  end;

  for I := 0 to High(Planned) do
    if (Planned[I].Outcome <> rvReverted) and
      (Planned[I].Outcome <> rvSkipped) then
    begin
      AResults := Planned;
      Exit(True);   { decided: refused, nothing written }
    end;

  N := 0;
  for I := 0 to High(Planned) do
    if Planned[I].Outcome = rvReverted then
    begin
      Ok := SysWriteAtomic(
        IncludeTrailingPathDelimiter(ARoot) + Planned[I].Path, Produced[N], Err);
      Inc(N);
      if not Ok then
      begin
        Planned[I].Outcome := rvFailed;
        Planned[I].Detail := Err;
        AResults := Planned;
        Exit(True);
      end;
    end;

  AResults := Planned;
  Result := True;
end;

function ApplyRecord(const ARoot: string; const ARecord: TChangeRecord;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResult: TRevertResult): Boolean;
begin
  Result := RunRecord(ARoot, ARecord, AHasher, AMaxBytes, ApplyText, AResult);
end;

function ApplyTurn(const ARoot: string; const ARows: TChangeRecordArray;
  AHasher: TChangeHasher; AMaxBytes: Integer;
  out AResults: TRevertResultArray): Boolean;
begin
  Result := RunTurn(ARoot, ARows, AHasher, AMaxBytes, ApplyText, AResults);
end;

end.
