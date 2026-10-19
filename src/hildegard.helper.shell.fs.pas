unit hildegard.helper.shell.fs;
{ The workspace-bounded filesystem the builtin shell tier runs on.

  The Shell Library never touches the host filesystem; this is the consumer's
  implementation of IShellFileSystem. Every operation enforces the same physical
  containment the file tools use (PhysicalContains), so a redirect, a glob, a
  `cd` or a `rm` cannot leave the workspace - symlinks included. Outside access
  is the process tier's business, not the builtin tier's. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, shell.fs, hildegard.helper.workspace;

type
  TWorkspaceShellFs = class(TInterfacedObject, IShellFileSystem)
  private
    FRoot: string;
    FMaxFileBytes: Int64;
    function Normalize(const APath: string): string;
    function EnsureInside(const APath: string; out AError: string): Boolean;
    function ReadAll(const APath: string; out AData, AError: string): Boolean;
    function DeleteTree(const APath: string; out AError: string): Boolean;
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
begin
  AError := '';
  if not EnsureInside(APath, AError) then
    Exit(False);
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
      Result := False;
    end;
  end;
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
    if DeleteFile(APath) then
      Exit(True);
    AError := 'cannot delete ' + APath;
    Exit(False);
  end;
  AError := 'no such file or directory: ' + APath;
  Result := False;
end;

function TWorkspaceShellFs.Move(const AFrom, ATo: string;
  out AError: string): Boolean;
begin
  AError := '';
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
    Result := RenameFile(AFrom, ATo);
    if not Result then
      AError := 'cannot move ' + AFrom + ' to ' + ATo;
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
begin
  AError := '';
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
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

end.
