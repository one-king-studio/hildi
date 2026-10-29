unit hildi.workspace;
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
  SysUtils, hildi.store;

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

{ Canonicalises APath (empty => the process working directory), verifies it
  exists and is a readable directory, and returns an instance. On failure
  returns nil with AError set. }
function CanonicalWorkspacePath(const APath: string): string;
function WorkspaceAccessible(const APath: string;
  out AError: string): Boolean;

{ Resolve APath (relative allowed) against ABase ('' => ARoot) *physically*:
  the lexical join is walked up to its nearest EXISTING ancestor, that ancestor
  is realpath(3)-resolved (symlinks collapsed), and the non-existent tail is
  re-appended. Never raises; a resolution failure yields the lexical path. }
function PhysicalResolve(const ARoot, APath: string;
  const ABase: string = ''): string;

{ True only when BOTH the lexical and the physical readings of APath are
  in-bounds under ARoot. The two-readings rule is deliberate: `..` after a
  symlink is mode-dependent (bash's cd is logical by default, physical with
  -P), so neither reading alone is trusted. }
function PhysicalContains(const ARoot, APath: string;
  const ABase: string = ''): Boolean;

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

{ --- the physical primitive --------------------------------------------- }

{$ifdef unix}
{ realpath(3): resolve every symlink and `..` to a canonical absolute path.
  Returns '' when the path does not exist or cannot be resolved. }
function c_realpath(APath: PAnsiChar; AResolved: PAnsiChar): PAnsiChar;
  cdecl; external 'c' name 'realpath';
{$endif}

{ The absolute lexical path for APath against ABase (no symlink resolution). }
function LexicalJoin(const ARoot, APath, ABase: string): string;
var
  Base: string;
begin
  Base := ABase;
  if Base = '' then
    Base := ARoot;
  if Trim(APath) = '' then
    Exit(ExpandFileName(Base));
  if APath[1] = PathDelim then
    Result := ExpandFileName(APath)
  else
    Result := ExpandFileName(IncludeTrailingPathDelimiter(Base) + APath);
end;

{ Resolve APath physically: walk up to the nearest existing ancestor, realpath
  it, then re-append the (non-existent) tail. }
function PhysicalResolve(const ARoot, APath: string;
  const ABase: string = ''): string;
var
  Lex, Ancestor, Tail, Resolved: string;
  Buf: array[0..4095] of AnsiChar;
  P: PAnsiChar;
  Slash: Integer;
begin
  Lex := LexicalJoin(ARoot, APath, ABase);
  Result := Lex;
  {$ifdef unix}
  { Walk up: find the nearest ancestor that exists. }
  Ancestor := Lex;
  Tail := '';
  while (Ancestor <> '') and (not FileExists(Ancestor)) and
    (not DirectoryExists(Ancestor)) do
  begin
    Slash := LastDelimiter(PathDelim, Ancestor);
    if Slash <= 1 then
      Break;
    if Tail = '' then
      Tail := Copy(Ancestor, Slash + 1, MaxInt)
    else
      Tail := Copy(Ancestor, Slash + 1, MaxInt) + PathDelim + Tail;
    Ancestor := Copy(Ancestor, 1, Slash - 1);
  end;
  P := c_realpath(PAnsiChar(AnsiString(Ancestor)), @Buf[0]);
  if P <> nil then
  begin
    Resolved := string(AnsiString(P));
    if Tail <> '' then
      Resolved := IncludeTrailingPathDelimiter(Resolved) + Tail;
    Result := Resolved;
  end;
  {$endif}
end;

function PhysicalContains(const ARoot, APath: string;
  const ABase: string = ''): Boolean;
var
  Phys, RootPhys: string;
begin
  { The PHYSICAL reading is authoritative: a path is in-bounds when it resolves
    (symlinks + `..` collapsed) under the root's physical form. Comparing
    physical-to-physical is what lets an absolute path that names a symlinked
    workspace (e.g. /var -> /private/var) be recognised as inside, and it still
    refuses a symlink inside that points out. The lexical reading is not
    required: it would wrongly reject a real path under a symlinked root. }
  RootPhys := PhysicalResolve(ARoot, ARoot);
  Phys := PhysicalResolve(ARoot, APath, ABase);
  Result := IsUnder(RootPhys, Phys);
end;

end.
