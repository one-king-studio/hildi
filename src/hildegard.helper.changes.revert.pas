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
  hildegard.helper.workspace;

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

implementation

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

end.
