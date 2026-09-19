unit hildegard.helper.workspace;
{ The active workspace: the directory the agent operates in. It is
  canonicalised to an absolute path, verified accessible at startup, used to
  resolve relative paths, and serves as the trust boundary for path checks
  (subpaths are in-bounds; escapes are not).

  A workspace is a guardrail boundary, not a sandbox. Canonicalisation is
  best-effort: symlinks are resolved only to the extent the platform helper
  does. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.store;

type
  TWorkspace = class
  private
    FRoot: string;
  public
    { Canonicalises APath (empty => the process working directory), verifies it
      exists and is a readable directory, and returns an instance. On failure
      returns nil with AError set. }
    class function Open(const APath: string; out AError: string): TWorkspace;
    function Root: string;
    { Resolves APath against the root; the result need not exist. }
    function Resolve(const APath: string): string;
    { True when APath resolves to the root or lies under it. }
    function Contains(const APath: string): Boolean;
  end;

function CanonicalWorkspacePath(const APath: string): string;
function WorkspaceAccessible(const APath: string;
  out AError: string): Boolean;

implementation

{$ifdef unix}
uses
  BaseUnix;
{$endif}

function CanonicalWorkspacePath(const APath: string): string;
var
  P: string;
begin
  if Trim(APath) = '' then
    P := GetCurrentDir
  else
    P := APath;
  P := ExpandFileName(P);
  { Drop a trailing separator unless the path is a root ('/'). }
  if (Length(P) > 1) and (P[Length(P)] = PathDelim) then
    P := Copy(P, 1, Length(P) - 1);
  Result := P;
end;

function WorkspaceAccessible(const APath: string;
  out AError: string): Boolean;
begin
  AError := '';
  if not DirectoryExists(APath) then
  begin
    AError := 'workspace is not a directory or does not exist: ' + APath;
    Exit(False);
  end;
  {$ifdef unix}
  if fpAccess(PAnsiChar(AnsiString(APath)), R_OK) <> 0 then
  begin
    AError := 'workspace is not readable: ' + APath;
    Exit(False);
  end;
  {$endif}
  Result := True;
end;

function IsUnder(const ARoot, APath: string): Boolean;
var
  Prefix: string;
begin
  if APath = ARoot then
    Exit(True);
  Prefix := ARoot;
  if (Prefix <> '') and (Prefix[Length(Prefix)] <> PathDelim) then
    Prefix := Prefix + PathDelim;
  Result := Copy(APath, 1, Length(Prefix)) = Prefix;
end;

class function TWorkspace.Open(const APath: string;
  out AError: string): TWorkspace;
var
  Root: string;
begin
  Result := nil;
  AError := '';
  Root := CanonicalWorkspacePath(APath);
  if not WorkspaceAccessible(Root, AError) then
    Exit;
  Result := TWorkspace.Create;
  Result.FRoot := Root;
end;

function TWorkspace.Root: string;
begin
  Result := FRoot;
end;

function TWorkspace.Resolve(const APath: string): string;
begin
  if Trim(APath) = '' then
    Exit(FRoot);
  if APath[1] = PathDelim then
    Result := ExpandFileName(APath)
  else
    Result := ExpandFileName(IncludeTrailingPathDelimiter(FRoot) + APath);
end;

function TWorkspace.Contains(const APath: string): Boolean;
begin
  Result := IsUnder(FRoot, Resolve(APath));
end;

end.
