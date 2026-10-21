unit hildegard.helper.workspace.snapshot;
{ A before/after picture of a workspace tree, so a spawned command's writes can
  be reported the way the builtin tier's are (Per-call File Changes, phase 2).

  Ignore-aware: every `.gitignore` in the tree applies to its own directory and
  an ignored path - or anything under an ignored directory - is never walked,
  so an edit to an ignored file is not reported. The same rules serve `rg`; a
  consumer that wants `.git` recorded opts out by not skipping it, but the
  snapshot always skips `.git` because its churn is never the model's work.

  Metadata, not contents: an entry is its size and mtime, so snapshotting a
  large tree stays cheap. Contents are read for created and modified files when
  the diff is made; a deleted file's contents are already gone, so its size is
  recorded and Captured stays False.

  Symlinks are skipped (a directory symlink can loop). mtime has one-second
  resolution on Unix, so a same-size rewrite inside one second is not seen -
  the same caveat git's own index has. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  hildegard.helper.gitignore, hildegard.helper.workspace.changes;

type
  TSnapshotEntry = record
    Size: Int64;
    MTime: Int64;
    IsDir: Boolean;
  end;

  TWorkspaceSnapshot = class
  private
    FIndex: TStringList;          // sorted by path; Objects = entry index
    FEntries: array of TSnapshotEntry;
    FRoot: string;
    function GetCount: Integer;
    function GetPath(AIndex: Integer): string;
    function GetEntry(AIndex: Integer): TSnapshotEntry;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    procedure Add(const ARel: string; AIsDir: Boolean; ASize, AMTime: Int64);
    function IndexOf(const ARel: string): Integer;
    property Root: string read FRoot;
    property Count: Integer read GetCount;
    property Paths[AIndex: Integer]: string read GetPath;
    property Entries[AIndex: Integer]: TSnapshotEntry read GetEntry;
  end;

{ Walk ARoot (which must exist) into a snapshot. }
function TakeSnapshot(const ARoot: string): TWorkspaceSnapshot;

{ Record into AChanges every created, modified and deleted path between two
  snapshots of the same root. }
procedure DiffSnapshots(const ABefore, AAfter: TWorkspaceSnapshot;
  AChanges: TFileChangeSet);

implementation

constructor TWorkspaceSnapshot.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ARoot;
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
  FIndex.CaseSensitive := True;
end;

destructor TWorkspaceSnapshot.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

procedure TWorkspaceSnapshot.Add(const ARel: string; AIsDir: Boolean;
  ASize, AMTime: Int64);
var
  Entry: TSnapshotEntry;
  Index: Integer;
begin
  Entry := Default(TSnapshotEntry);
  Entry.Size := ASize;
  Entry.MTime := AMTime;
  Entry.IsDir := AIsDir;
  Index := Length(FEntries);
  SetLength(FEntries, Index + 1);
  FEntries[Index] := Entry;
  FIndex.AddObject(ARel, TObject(PtrInt(Index)));
end;

function TWorkspaceSnapshot.IndexOf(const ARel: string): Integer;
var
  At: Integer;
begin
  At := FIndex.IndexOf(ARel);
  if At < 0 then
    Exit(-1);
  Result := PtrInt(FIndex.Objects[At]);
end;

function TWorkspaceSnapshot.GetCount: Integer;
begin
  Result := FIndex.Count;
end;

function TWorkspaceSnapshot.GetPath(AIndex: Integer): string;
begin
  Result := FIndex[AIndex];
end;

function TWorkspaceSnapshot.GetEntry(AIndex: Integer): TSnapshotEntry;
begin
  Result := FEntries[PtrInt(FIndex.Objects[AIndex])];
end;

function ReadTextFile(const APath: string): string;
var
  Fs: TFileStream;
begin
  Result := '';
  if not FileExists(APath) then
    Exit;
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, Fs.Size);
      if Fs.Size > 0 then
        Fs.ReadBuffer(Result[1], Fs.Size);
    finally
      Fs.Free;
    end;
  except
    Result := '';
  end;
end;

function JoinRel(const ADirRel, AName: string): string;
begin
  if ADirRel = '' then
    Result := AName
  else
    Result := ADirRel + '/' + AName;
end;

function TakeSnapshot(const ARoot: string): TWorkspaceSnapshot;
var
  Rules: TIgnoreRules;

  procedure Walk(const ADirRel, ADirAbs: string);
  var
    SR: TSearchRec;
    Rel, Full, IgnoreText: string;
  begin
    IgnoreText := ReadTextFile(IncludeTrailingPathDelimiter(ADirAbs) + '.gitignore');
    if IgnoreText <> '' then
      Rules.AddFile(ADirRel, IgnoreText);
    if FindFirst(IncludeTrailingPathDelimiter(ADirAbs) + '*', faAnyFile, SR) <> 0 then
      Exit;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        { A symlinked directory can loop; a symlinked file has no stable size
          or mtime. Skip both. (faSymLink is outside the portable subset, but
          both platforms we build for define it.) }
        {$push}{$warnings off}
        if (SR.Attr and faSymLink) <> 0 then
          Continue;
        {$pop}
        Rel := JoinRel(ADirRel, SR.Name);
        Full := IncludeTrailingPathDelimiter(ADirAbs) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          if (SR.Name = '.git') or Rules.IsIgnored(Rel, True) then
            Continue;
          Result.Add(Rel, True, 0, 0);
          Walk(Rel, Full);
        end
        else
        begin
          if Rules.IsIgnored(Rel, False) then
            Continue;
          Result.Add(Rel, False, SR.Size, Int64(FileAge(Full)));
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  Rules := TIgnoreRules.Create;
  try
    Result := TWorkspaceSnapshot.Create(ARoot);
    if DirectoryExists(ARoot) then
      Walk('', ARoot);
  finally
    Rules.Free;
  end;
end;

{ Read a file's text if it is within the capture cap; else record its size
  only (Captured = False). }
function CaptureText(const AFull: string; out AData: string;
  out ASize: Int64): Boolean;
var
  Fs: TFileStream;
begin
  AData := '';
  ASize := 0;
  Result := False;
  if not FileExists(AFull) then
    Exit;
  try
    Fs := TFileStream.Create(AFull, fmOpenRead or fmShareDenyNone);
    try
      ASize := Fs.Size;
      if ASize > MaxCapturedChangeBytes then
        Exit;
      SetLength(AData, ASize);
      if ASize > 0 then
        Fs.ReadBuffer(AData[1], ASize);
      Result := True;
    finally
      Fs.Free;
    end;
  except
    Result := False;
  end;
end;

procedure DiffSnapshots(const ABefore, AAfter: TWorkspaceSnapshot;
  AChanges: TFileChangeSet);
var
  I, J: Integer;
  B, A: TSnapshotEntry;
  BPath, APath, Data: string;
  Size: Int64;

  function Full(const ASnapshot: TWorkspaceSnapshot; const ARel: string): string;
  begin
    Result := IncludeTrailingPathDelimiter(ASnapshot.Root) + ARel;
  end;

  procedure ReportDeleted(const ARel: string; const AEntry: TSnapshotEntry);
  var
    C: TFileChange;
  begin
    C := Default(TFileChange);
    C.Path := ARel;
    C.Kind := fcDeleted;
    C.IsDir := AEntry.IsDir;
    C.BeforeSize := AEntry.Size;
    { The bytes are gone by the time we diff; a directory never had any. A
      deletion renders no line delta either way. }
    C.Captured := AEntry.IsDir;
    C.BeforeCaptured := AEntry.IsDir;
    AChanges.Add(C);
  end;

  procedure ReportCreated(const ARel: string; const AEntry: TSnapshotEntry);
  var
    C: TFileChange;
  begin
    C := Default(TFileChange);
    C.Path := ARel;
    C.Kind := fcCreated;
    C.IsDir := AEntry.IsDir;
    if AEntry.IsDir then
      C.Captured := True
    else
      C.Captured := CaptureText(Full(AAfter, ARel), Data, Size);
    C.After := Data;
    C.AfterSize := AEntry.Size;
    { A creation has no before side; the kind makes a delta moot. }
    C.BeforeCaptured := False;
    AChanges.Add(C);
  end;

  procedure ReportModified(const ARel: string; const AEntry: TSnapshotEntry;
    const ABeforeEntry: TSnapshotEntry);
  var
    C: TFileChange;
  begin
    C := Default(TFileChange);
    C.Path := ARel;
    C.Kind := fcModified;
    C.BeforeSize := ABeforeEntry.Size;
    C.AfterSize := AEntry.Size;
    C.Captured := CaptureText(Full(AAfter, ARel), Data, Size);
    C.After := Data;
    { The old bytes are gone by the time the post-run walk happens, so Before is
      NOT captured. Without this flag Summary would compute a line delta against
      an empty Before and report the whole file as added. }
    C.BeforeCaptured := False;
    AChanges.Add(C);
  end;

begin
  I := 0;
  J := 0;
  while (I < ABefore.Count) or (J < AAfter.Count) do
  begin
    if J >= AAfter.Count then
    begin
      ReportDeleted(ABefore.Paths[I], ABefore.Entries[I]);
      Inc(I);
      Continue;
    end;
    if I >= ABefore.Count then
    begin
      ReportCreated(AAfter.Paths[J], AAfter.Entries[J]);
      Inc(J);
      Continue;
    end;
    BPath := ABefore.Paths[I];
    APath := AAfter.Paths[J];
    if BPath < APath then
    begin
      ReportDeleted(BPath, ABefore.Entries[I]);
      Inc(I);
      Continue;
    end;
    if APath < BPath then
    begin
      ReportCreated(APath, AAfter.Entries[J]);
      Inc(J);
      Continue;
    end;
    B := ABefore.Entries[I];
    A := AAfter.Entries[J];
    { A directory's mtime moves whenever a child does; only its existence is a
      change. }
    if (not A.IsDir) and ((A.Size <> B.Size) or (A.MTime <> B.MTime)) then
      ReportModified(APath, A, B);
    Inc(I);
    Inc(J);
  end;
end;

end.
