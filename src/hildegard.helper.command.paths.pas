unit hildegard.helper.command.paths;
{ Derives the filesystem paths a shell command NAMES, resolved against the
  effective working directory, so the command tool can gate an access that
  leaves the workspace. Pure (no I/O beyond a stat), so it is unit-testable.

  An access is a literal path-like token (a segment argument or a redirection
  target), the command's `cwd`, or a `cd`/`pushd` target. A token the parser
  could not resolve (`$VAR`, a glob, a command substitution) is treated as an
  access to CHECK, never assumed in-bounds - so a shell cannot hide an escape
  behind expansion.

  A top-level `cd` moves the base for LATER segments (a subshell's does not: a
  parenthesised segment resets it). The physical containment check itself lives
  in hildegard.helper.workspace (PhysicalContains); this unit only names the
  accesses.

  See docs/features/Approval_Path_Scoping/Approval_Path_Scoping_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  hildegard.helper.command.policy, hildegard.helper.workspace;

type
  TPathAccess = record
    Token: string;       // the token as written
    Resolved: string;    // the absolute path it names (lexical)
    Inside: Boolean;     // physically under the workspace root
    Segment: Integer;    // index into the plan's segments
  end;
  TPathAccessArray = array of TPathAccess;

{ Every path-like token in the plan, resolved against ACwd (the command's
  effective base, '' => the workspace root) with a top-level `cd` tracked. In
  segment order, then token order; duplicates (same resolved path) are dropped. }
function PathAccesses(const APlan: TCommandPlan; const AWorkspace: TWorkspace;
  const ACwd: string): TPathAccessArray;

{ The subset of PathAccesses that are physically OUTSIDE the workspace root. }
function OutsideAccesses(const APlan: TCommandPlan;
  const AWorkspace: TWorkspace; const ACwd: string): TPathAccessArray;

{ Expand a leading `~` (and `~/`) to AHome. }
function ExpandHome(const APath, AHome: string): string;

implementation

function ExpandHome(const APath, AHome: string): string;
begin
  Result := APath;
  if (APath = '~') then
    Result := AHome
  else if (Copy(APath, 1, 2) = '~' + PathDelim) then
    Result := IncludeTrailingPathDelimiter(AHome) + Copy(APath, 3, MaxInt);
end;

{ Resolve a token against ABase (an absolute directory). }
function ResolveToken(const AToken, ABase: string): string;
var
  T: string;
begin
  T := ExpandHome(AToken, GetEnvironmentVariable('HOME'));
  if (T <> '') and (T[1] = PathDelim) then
    Result := ExpandFileName(T)
  else
    Result := ExpandFileName(IncludeTrailingPathDelimiter(ABase) + T);
end;

procedure AddAccess(var AList: TPathAccessArray; const AToken, AResolved: string;
  AInside: Boolean; ASegment: Integer);
var
  I: Integer;
begin
  { Drop a duplicate resolved path. }
  for I := 0 to High(AList) do
    if AList[I].Resolved = AResolved then
      Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)].Token := AToken;
  AList[High(AList)].Resolved := AResolved;
  AList[High(AList)].Inside := AInside;
  AList[High(AList)].Segment := ASegment;
end;

function PathAccesses(const APlan: TCommandPlan; const AWorkspace: TWorkspace;
  const ACwd: string): TPathAccessArray;
var
  Base: string;
  I, J: Integer;
  Seg: TCommandSegment;
  IsCd, TopLevel: Boolean;

  procedure AddToken(const AToken: string; ASegment: Integer);
  var
    R: string;
  begin
    if Trim(AToken) = '' then
      Exit;
    R := ResolveToken(AToken, Base);
    AddAccess(Result, AToken, R, PhysicalContains(AWorkspace.Root, R), ASegment);
  end;

begin
  Result := nil;
  if (APlan.Segments = nil) and (ACwd = '') then
    Exit;
  Base := ACwd;
  if Base = '' then
    Base := AWorkspace.Root;
  { The command's own cwd argument is itself an access to check. }
  if ACwd <> '' then
    AddToken(ACwd, 0);
  for I := 0 to High(APlan.Segments) do
  begin
    Seg := APlan.Segments[I];
    IsCd := (Seg.Executable = 'cd') or (Seg.Executable = 'pushd');
    { A subshell (`( ... )`) resets the base after the segment. Detected by the
      segment text being wrapped in parentheses. }
    TopLevel := (Trim(Seg.Text) = '') or (Trim(Seg.Text)[1] <> '(');
    for J := 0 to High(Seg.Paths) do
      AddToken(Seg.Paths[J].Text, I);
    { A `cd`/`pushd` target moves the base for LATER segments. }
    if IsCd and (Length(Seg.Arguments) > 0) then
    begin
      Base := ResolveToken(Seg.Arguments[0], Base);
      if not DirectoryExists(Base) then
        Base := ResolveToken(Seg.Arguments[0], ACwd);   { fall back }
      if (not TopLevel) and (ACwd <> '') then
        Base := ACwd;   { a subshell's cd does not leak }
      if not TopLevel then
        Base := ResolveToken('', AWorkspace.Root);
    end;
  end;
end;

function OutsideAccesses(const APlan: TCommandPlan;
  const AWorkspace: TWorkspace; const ACwd: string): TPathAccessArray;
var
  All: TPathAccessArray;
  I: Integer;
begin
  Result := nil;
  All := PathAccesses(APlan, AWorkspace, ACwd);
  for I := 0 to High(All) do
    if not All[I].Inside then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := All[I];
    end;
end;

end.
