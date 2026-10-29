unit HildiShellFs;
{ The workspace-bounded filesystem the builtin shell tier runs on.

  The Shell Library never touches the host filesystem; this is the consumer's
  implementation of IShellFileSystem. Every operation enforces the same physical
  containment the file tools use (PhysicalContains), so a redirect, a glob, a
  `cd` or a `rm` cannot leave the workspace - symlinks included. Outside access
  is the process tier's business, not the builtin tier's. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, ShellFs,
  {$ifdef unix}BaseUnix,{$endif}
  HildiWorkspace, HildiWorkspaceChanges;

type
  { One write, reported after it happened. }
  TShellFsChangeEvent = procedure(const AChange: TFileChange) of object;

  TWorkspaceShellFs = class(TInterfacedObject, IShellFileSystem)
  private
    FRoot: string;
    FMaxFileBytes: Int64;
    FOnChange: TShellFsChangeEvent;
    function Normalize(const APath: string): string;
    function EnsureInside(const APath: string; out AError: string): Boolean;
    function ReadAll(const APath: string; out AData, AError: string): Boolean;
    function DeleteTree(const APath: string; out AError: string): Boolean;
    function WorkspaceRelative(const APath: string): string;
    function CaptureText(const APath: string; out AData: string;
      out ASize: Int64): Boolean;
    procedure Report(const APath: string; AKind: TFileChangeKind;
      AIsDir: Boolean; const ABefore, AAfter: string; ACaptured: Boolean;
      ABeforeSize, AAfterSize: Int64);
  public
    constructor Create(const ARoot: string);
    { IShellFileSystem }
    function Resolve(const ACwd, APath: string): string;
    function ReadFile(const APath: string; out AData, AError: string): Boolean;
    function WriteFile(const APath, AData: string; AAppend: Boolean;
      out AError: string): Boolean;
    function ListDir(const APath: string; out AEntries: TStringArray;
      out AError: string): Boolean;
    function Stat(const APath: string; out AKind: TShellFileKind;
      out AError: string): Boolean;
    function Info(const APath: string; out AInfo: TShellFileInfo;
      out AError: string): Boolean;
    { Symbolic links and mode bits. The LINK must be inside the workspace; its
      target text need not be, because writing a link is not following one. }
    function Symlink(const ATarget, ALinkPath: string;
      out AError: string): Boolean;
    function ReadLink(const APath: string; out ATarget, AError: string): Boolean;
    function SetMode(const APath: string; AMode: LongWord;
      out AError: string): Boolean;
    { Called once per write the shell makes (redirect, sed -i, tee, rm, mv,
      cp, mkdir, touch). Nil when nobody is tracking. }
    property OnChange: TShellFsChangeEvent read FOnChange write FOnChange;
    { The operations the command set needs beyond the shell interface. }
    function Delete(const APath: string; ARecursive: Boolean;
      out AError: string): Boolean;
    function Move(const AFrom, ATo: string; out AError: string): Boolean;
    function Copy(const AFrom, ATo: string; out AError: string): Boolean;
    function MakeDir(const APath: string; AParents: Boolean;
      out AError: string): Boolean;
    function Touch(const APath: string; out AError: string): Boolean;
    function ReadText(const APath: string; out AData, AError: string): Boolean;
    property Root: string read FRoot;
    property MaxFileBytes: Int64 read FMaxFileBytes write FMaxFileBytes;
  end;

implementation

const
  DefaultMaxFileBytes = 8 * 1024 * 1024;

constructor TWorkspaceShellFs.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := CanonicalWorkspacePath(ARoot);
  FMaxFileBytes := DefaultMaxFileBytes;
end;

function TWorkspaceShellFs.Normalize(const APath: string): string;
var
  I, N: Integer;
  Seg, Part: string;
  Stack: TStringArray;
begin
  Stack := nil;
  I := 1;
  while I <= Length(APath) + 1 do
  begin
    N := I;
    while (N <= Length(APath)) and (APath[N] <> '/') do
      Inc(N);
    Part := System.Copy(APath, I, N - I);
    I := N + 1;
    if (Part = '') or (Part = '.') then
      Continue;
    if Part = '..' then
    begin
      if Length(Stack) > 0 then
        SetLength(Stack, Length(Stack) - 1);
    end
    else
    begin
      SetLength(Stack, Length(Stack) + 1);
      Stack[High(Stack)] := Part;
    end;
  end;
  Seg := '/';
  for I := 0 to High(Stack) do
  begin
    if I > 0 then
      Seg := Seg + '/';
    Seg := Seg + Stack[I];
  end;
  Result := Seg;
end;

function TWorkspaceShellFs.EnsureInside(const APath: string;
  out AError: string): Boolean;
begin
  AError := '';
  if PhysicalContains(FRoot, APath) then
    Exit(True);
  AError := 'path escapes the workspace: ' + APath;
  Result := False;
end;

function TWorkspaceShellFs.Resolve(const ACwd, APath: string): string;
begin
  if APath = '' then
    Result := Normalize(ACwd)
  else if (APath[1] = '/') or (ACwd = '') then
    Result := Normalize(APath)
  else
    Result := Normalize(ACwd + '/' + APath);
end;

function TWorkspaceShellFs.WorkspaceRelative(const APath: string): string;
begin
  if FRoot = '/' then
    Result := System.Copy(APath, 2, MaxInt)
  else if System.Copy(APath, 1, Length(FRoot) + 1) = FRoot + '/' then
    Result := System.Copy(APath, Length(FRoot) + 2, MaxInt)
  else
    Result := APath;
end;

function TWorkspaceShellFs.CaptureText(const APath: string; out AData: string;
  out ASize: Int64): Boolean;
var
  Fs: TFileStream;
begin
  AData := '';
  ASize := 0;
  Result := False;
  if not FileExists(APath) then
    Exit;
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
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

procedure TWorkspaceShellFs.Report(const APath: string; AKind: TFileChangeKind;
  AIsDir: Boolean; const ABefore, AAfter: string; ACaptured: Boolean;
  ABeforeSize, AAfterSize: Int64);
var
  Change: TFileChange;
begin
  if not Assigned(FOnChange) then
    Exit;
  Change := Default(TFileChange);
  Change.Path := WorkspaceRelative(APath);
  Change.Kind := AKind;
  Change.IsDir := AIsDir;
  Change.Before := ABefore;
  Change.After := AAfter;
  Change.BeforeSize := ABeforeSize;
  Change.AfterSize := AAfterSize;
  Change.Captured := ACaptured;
  { The builtin tier reads the prior text itself, so a capture means Before is
    the real prior content. (A creation has no before side; its kind makes the
    delta moot.) }
  Change.BeforeCaptured := ACaptured;
  FOnChange(Change);
end;

function TWorkspaceShellFs.ReadAll(const APath: string;
  out AData, AError: string): Boolean;
var
  Fs: TFileStream;
  Size: Int64;
begin
  AData := '';
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if not FileExists(APath) then
  begin
    AError := 'no such file or directory';
    Exit(False);
  end;
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Size := Fs.Size;
      if Size > FMaxFileBytes then
      begin
        AError := 'file is larger than the builtin shell read cap (' +
          IntToStr(FMaxFileBytes) + ' bytes)';
        Exit(False);
      end;
      SetLength(AData, Size);
      if Size > 0 then
        Fs.ReadBuffer(AData[1], Size);
    finally
      Fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TWorkspaceShellFs.ReadFile(const APath: string;
  out AData, AError: string): Boolean;
begin
  Result := ReadAll(APath, AData, AError);
end;

function TWorkspaceShellFs.ReadText(const APath: string;
  out AData, AError: string): Boolean;
begin
  Result := ReadAll(APath, AData, AError);
end;

function TWorkspaceShellFs.WriteFile(const APath, AData: string;
  AAppend: Boolean; out AError: string): Boolean;
var
  Fs: TFileStream;
  Before, After: string;
  BeforeSize, AfterSize: Int64;
  Captured, Existed: Boolean;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  Existed := FileExists(APath);
  Captured := True;
  Before := '';
  BeforeSize := 0;
  if Existed then
    Captured := CaptureText(APath, Before, BeforeSize);
  try
    if AAppend then
      Fs := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyNone)
    else
      Fs := TFileStream.Create(APath, fmCreate);
    try
      if AAppend then
        Fs.Seek(0, soEnd);
      if AData <> '' then
        Fs.WriteBuffer(AData[1], Length(AData));
    finally
      Fs.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit(False);
    end;
  end;
  if AAppend and Captured then
    After := Before + AData
  else
    After := AData;
  if not Captured then
    AfterSize := Length(AData)
  else
    AfterSize := Length(After);
  if not Existed then
    Report(APath, fcCreated, False, '', After, Captured, 0, AfterSize)
  else if (not Captured) or (Before <> After) then
    Report(APath, fcModified, False, Before, After, Captured, BeforeSize,
      AfterSize);
end;

function TWorkspaceShellFs.ListDir(const APath: string;
  out AEntries: TStringArray; out AError: string): Boolean;
var
  R: TSearchRec;
  Names: TStringList;
  I: Integer;
begin
  AEntries := nil;
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if not DirectoryExists(APath) then
  begin
    AError := 'not a directory: ' + APath;
    Exit(False);
  end;
  Names := TStringList.Create;
  try
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, R) = 0 then
    try
      repeat
        if (R.Name <> '.') and (R.Name <> '..') then
          Names.Add(R.Name);
      until FindNext(R) <> 0;
    finally
      FindClose(R);
    end;
    SetLength(AEntries, Names.Count);
    for I := 0 to Names.Count - 1 do
      AEntries[I] := Names[I];
    Result := True;
  finally
    Names.Free;
  end;
end;

function TWorkspaceShellFs.Stat(const APath: string;
  out AKind: TShellFileKind; out AError: string): Boolean;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
  begin
    AKind := sfkMissing;
    Exit(False);
  end;
  if DirectoryExists(APath) then
  begin
    AKind := sfkDirectory;
    Exit(True);
  end;
  if FileExists(APath) then
  begin
    AKind := sfkFile;
    Exit(True);
  end;
  AKind := sfkMissing;
  AError := 'no such file or directory';
  Result := False;
end;

function TWorkspaceShellFs.Info(const APath: string; out AInfo: TShellFileInfo;
  out AError: string): Boolean;
var
  {$ifdef unix}
  St: Stat;
  {$endif}
  {$ifndef unix}
  Fs: TFileStream;
  Age: LongInt;
  {$endif}
begin
  AInfo := Default(TShellFileInfo);
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if DirectoryExists(APath) then
    AInfo.Kind := sfkDirectory
  else if FileExists(APath) then
    AInfo.Kind := sfkFile
  else
  begin
    AInfo.Kind := sfkMissing;
    AError := 'no such file or directory';
    Exit(False);
  end;
  {$ifdef unix}
  if fpStat(PChar(APath), St) = 0 then
  begin
    AInfo.Mode := St.st_mode and $FFF;
    AInfo.Size := St.st_size;
    AInfo.Modified := St.st_mtime;
  end;
  {$else}
  AInfo.Mode := 0;
  AInfo.Size := 0;
  AInfo.Modified := 0;
  if AInfo.Kind = sfkFile then
  begin
    try
      Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
      try
        AInfo.Size := Fs.Size;
      finally
        Fs.Free;
      end;
    except
      AInfo.Size := 0;
    end;
  end;
  Age := FileAge(APath);
  if Age <> -1 then
    AInfo.Modified := Age;
  {$endif}
  Result := True;
end;

function TWorkspaceShellFs.DeleteTree(const APath: string;
  out AError: string): Boolean;
var
  R: TSearchRec;
  Child: string;
begin
  AError := '';
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, R) = 0 then
  try
    repeat
      if (R.Name = '.') or (R.Name = '..') then
        Continue;
      Child := IncludeTrailingPathDelimiter(APath) + R.Name;
      if (R.Attr and faDirectory) <> 0 then
      begin
        if not DeleteTree(Child, AError) then
          Exit(False);
      end
      else if not DeleteFile(Child) then
      begin
        AError := 'cannot delete ' + Child;
        Exit(False);
      end;
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
  if not RemoveDir(APath) then
  begin
    AError := 'cannot remove directory ' + APath;
    Exit(False);
  end;
  Result := True;
end;

function TWorkspaceShellFs.Delete(const APath: string; ARecursive: Boolean;
  out AError: string): Boolean;
var
  Before: string;
  BeforeSize: Int64;
  Captured: Boolean;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if Normalize(APath) = FRoot then
  begin
    AError := 'refusing to remove the workspace root';
    Exit(False);
  end;
  if DirectoryExists(APath) then
  begin
    if ARecursive then
      Exit(DeleteTree(APath, AError));
    if RemoveDir(APath) then
      Exit(True);
    AError := 'directory not empty: ' + APath;
    Exit(False);
  end;
  if FileExists(APath) then
  begin
    Before := '';
    BeforeSize := 0;
    Captured := CaptureText(APath, Before, BeforeSize);
    if DeleteFile(APath) then
    begin
      Report(APath, fcDeleted, False, Before, '', Captured, BeforeSize, 0);
      Exit(True);
    end;
    AError := 'cannot delete ' + APath;
    Exit(False);
  end;
  AError := 'no such file or directory: ' + APath;
  Result := False;
end;

function TWorkspaceShellFs.Move(const AFrom, ATo: string;
  out AError: string): Boolean;
var
  Before, After: string;
  BeforeSize, AfterSize: Int64;
  Captured: Boolean;
begin
  AError := '';
  Captured := CaptureText(AFrom, Before, BeforeSize);
  if (not EnsureInside(AFrom, AError)) or (not EnsureInside(ATo, AError)) then
    Exit(False);
  if not FileExists(AFrom) and not DirectoryExists(AFrom) then
  begin
    AError := 'no such file or directory: ' + AFrom;
    Exit(False);
  end;
  if DirectoryExists(ATo) then
  begin
    AError := 'destination is a directory: ' + ATo;
    Exit(False);
  end;
  try
    { mv overwrites a file. Unix rename() does; Windows MoveFile does not, so
      remove the target first (the same semantics on both). }
    if FileExists(ATo) and (not DeleteFile(ATo)) then
    begin
      AError := 'cannot replace ' + ATo;
      Exit(False);
    end;
    Result := RenameFile(AFrom, ATo);
    if not Result then
      AError := 'cannot move ' + AFrom + ' to ' + ATo
    else
    begin
      Report(AFrom, fcDeleted, False, Before, '', Captured, BeforeSize, 0);
      Captured := CaptureText(ATo, After, AfterSize);
      Report(ATo, fcCreated, False, '', After, Captured, 0, AfterSize);
    end;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TWorkspaceShellFs.Copy(const AFrom, ATo: string;
  out AError: string): Boolean;
var
  Src, Dst: TFileStream;
  Before, After: string;
  BeforeSize, AfterSize: Int64;
  Captured, Existed: Boolean;
begin
  AError := '';
  Existed := FileExists(ATo);
  Captured := False;
  Before := '';
  BeforeSize := 0;
  if Existed then
    Captured := CaptureText(ATo, Before, BeforeSize);
  if (not EnsureInside(AFrom, AError)) or (not EnsureInside(ATo, AError)) then
    Exit(False);
  if DirectoryExists(AFrom) then
  begin
    AError := 'is a directory: ' + AFrom;
    Exit(False);
  end;
  if not FileExists(AFrom) then
  begin
    AError := 'no such file or directory: ' + AFrom;
    Exit(False);
  end;
  try
    Src := TFileStream.Create(AFrom, fmOpenRead or fmShareDenyNone);
    try
      Dst := TFileStream.Create(ATo, fmCreate);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
    Result := True;
    Captured := CaptureText(ATo, After, AfterSize);
    if not Existed then
      Report(ATo, fcCreated, False, '', After, Captured, 0, AfterSize)
    else if (not Captured) or (Before <> After) then
      Report(ATo, fcModified, False, Before, After, Captured, BeforeSize,
        AfterSize);
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TWorkspaceShellFs.MakeDir(const APath: string; AParents: Boolean;
  out AError: string): Boolean;
var
  Existed: Boolean;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if DirectoryExists(APath) then
  begin
    if AParents then
      Exit(True);
    AError := 'file exists: ' + APath;
    Exit(False);
  end;
  Existed := DirectoryExists(APath);
  try
    if AParents then
    begin
      ForceDirectories(APath);
      Result := DirectoryExists(APath);
      if not Result then
        AError := 'cannot create directory ' + APath;
    end
    else
    begin
      Result := CreateDir(APath);
      if not Result then
        AError := 'cannot create directory ' + APath;
    end;
    if Result and (not Existed) then
      Report(APath, fcCreated, True, '', '', True, 0, 0);
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TWorkspaceShellFs.Touch(const APath: string; out AError: string): Boolean;
var
  Fs: TFileStream;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  if FileExists(APath) or DirectoryExists(APath) then
    Exit(True);
  try
    Fs := TFileStream.Create(APath, fmCreate);
    Fs.Free;
    Report(APath, fcCreated, False, '', '', True, 0, 0);
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TWorkspaceShellFs.Symlink(const ATarget, ALinkPath: string;
  out AError: string): Boolean;
begin
  AError := '';
  { The LINK must be inside the workspace; its target text need not be. A link
    whose text points outside is only dangerous when something FOLLOWS it, and
    that is what the confinement check on read governs. }
  if not EnsureInside(ALinkPath, AError) then
    Exit(False);
  {$ifdef unix}
  if fpSymlink(PChar(ATarget), PChar(ALinkPath)) = 0 then
  begin
    Report(ALinkPath, fcCreated, False, '', ATarget, True, 0, 0);
    Exit(True);
  end;
  AError := 'could not create symlink: ' + ALinkPath;
  Result := False;
  {$else}
  { Windows needs privilege or developer mode. Refuse rather than silently
    creating a COPY, which would look like success and behave differently. }
  AError := 'symlinks are not supported on this platform';
  Result := False;
  {$endif}
end;

function TWorkspaceShellFs.ReadLink(const APath: string; out ATarget,
  AError: string): Boolean;
var
  Buf: array[0..4095] of Char;
  N: Integer;
begin
  AError := '';
  ATarget := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  {$ifdef unix}
  N := fpReadlink(PChar(APath), @Buf[0], SizeOf(Buf) - 1);
  if N < 0 then
  begin
    AError := 'not a symbolic link: ' + APath;
    Exit(False);
  end;
  Buf[N] := #0;
  ATarget := string(PChar(@Buf[0]));
  Result := True;
  {$else}
  AError := 'symlinks are not supported on this platform';
  Result := False;
  {$endif}
end;

function TWorkspaceShellFs.SetMode(const APath: string; AMode: LongWord;
  out AError: string): Boolean;
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
  {$ifdef unix}
  if fpChmod(PChar(APath), AMode) = 0 then
    Exit(True);
  AError := 'could not chmod: ' + APath;
  Result := False;
  {$else}
  { No mode bits on Windows. A script that chmods should not fail there. }
  Result := True;
  {$endif}
end;

end.
