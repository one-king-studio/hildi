unit hildegard.helper.mcp.config;
{ Typed MCP server configuration and its scope resolution. Pure: no store, no
  files, no I/O. The SQLite store owns the rows (hildegard.helper.store); this
  unit decides which row wins for a context. A future file source
  (JSON/JSONC/TOML) produces the same rows and reuses the same resolution.
  See docs/features/MCP_Client/Config_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { Where a server definition lives. Most specific wins on a name clash. }
  TMcpScope = (msGlobal, msWorkspace, msAgent);

  { A stored server definition, as read from any source. }
  TMcpServerRow = record
    Id: Integer;
    Scope: TMcpScope;
    WorkspaceId: Integer;   // 0 for global (and agent)
    AgentId: string;        // '' unless agent scope (reserved; agent support later)
    Name: string;
    Command: string;
    Args: array of string;
    Env: array of string;   // 'NAME=VALUE' additions (secrets stay out of argv)
    WorkingDir: string;     // '' => process cwd
    Enabled: Boolean;
    ListTimeoutMs: Integer; // 0 => client default
    CallTimeoutMs: Integer; // 0 => client default
    CreatedAt: Int64;
  end;

  TMcpServerRowArray = array of TMcpServerRow;

  { The effective server, after resolution. }
  TMcpServerConfig = record
    Name: string;
    Command: string;
    Args: array of string;
    Env: array of string;
    WorkingDir: string;
    Enabled: Boolean;
    ListTimeoutMs: Integer;
    CallTimeoutMs: Integer;
    Scope: TMcpScope;       // the scope the winning row came from
  end;

  TMcpServerArray = array of TMcpServerConfig;

  { The context a session resolves against. }
  TMcpConfigContext = record
    WorkspaceId: Integer;   // 0 = no workspace (global only)
    AgentId: string;        // '' today
  end;

  TMcpConfig = record
    Servers: TMcpServerArray;   // effective, enabled, name-sorted
    Context: TMcpConfigContext;
  end;

{ Merge rows for a context by precedence (agent > workspace > global): a more
  specific row overrides the same name; distinct names union. Returns the
  enabled servers only, sorted by name for determinism. }
function ResolveMcpConfig(const ARows: TMcpServerRowArray;
  const AContext: TMcpConfigContext): TMcpServerArray;

{ Validate one row's fields. Used by the store on write and by tests. }
function ValidateMcpServerRow(const ARow: TMcpServerRow;
  out AError: string): Boolean;

{ Validate an effective (resolved) list: at most MaxMcpServers. }
function ValidateMcpConfig(const AServers: TMcpServerArray;
  out AError: string): Boolean;

{ True when AName is a legal MCP server name: 1..MaxMcpNameChars characters
  from [A-Za-z0-9_-]. }
function IsValidMcpName(const AName: string): Boolean;

const
  MaxMcpServers = 32;      // a bound; more is almost certainly a mistake
  MaxMcpNameChars = 64;

implementation

function IsValidMcpName(const AName: string): Boolean;
var
  I: Integer;
begin
  if (AName = '') or (Length(AName) > MaxMcpNameChars) then
    Exit(False);
  for I := 1 to Length(AName) do
    if not (AName[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
  Result := True;
end;

function ScopeRank(AScope: TMcpScope): Integer;
begin
  Result := Ord(AScope);   // msGlobal=0 < msWorkspace=1 < msAgent=2
end;

{ Whether a row applies to a context. Global always; workspace when the ids
  match and the context has a workspace; agent when the ids match and the
  context has an agent. }
function RowApplies(const ARow: TMcpServerRow;
  const AContext: TMcpConfigContext): Boolean;
begin
  Result := False;
  case ARow.Scope of
    msGlobal: Result := True;
    msWorkspace: Result := (AContext.WorkspaceId <> 0) and
      (ARow.WorkspaceId = AContext.WorkspaceId);
    msAgent: Result := (AContext.AgentId <> '') and
      (ARow.AgentId = AContext.AgentId);
  end;
end;

function ToConfig(const ARow: TMcpServerRow): TMcpServerConfig;
begin
  Result := Default(TMcpServerConfig);
  Result.Name := ARow.Name;
  Result.Command := ARow.Command;
  Result.Args := Copy(ARow.Args, 0, Length(ARow.Args));
  Result.Env := Copy(ARow.Env, 0, Length(ARow.Env));
  Result.WorkingDir := ARow.WorkingDir;
  Result.Enabled := ARow.Enabled;
  Result.ListTimeoutMs := ARow.ListTimeoutMs;
  Result.CallTimeoutMs := ARow.CallTimeoutMs;
  Result.Scope := ARow.Scope;
end;

procedure SortByName(var AServers: TMcpServerArray);
var
  I, J: Integer;
  Tmp: TMcpServerConfig;
begin
  for I := 0 to High(AServers) - 1 do
    for J := I + 1 to High(AServers) do
      if AServers[J].Name < AServers[I].Name then
      begin
        Tmp := AServers[I];
        AServers[I] := AServers[J];
        AServers[J] := Tmp;
      end;
end;

function ResolveMcpConfig(const ARows: TMcpServerRowArray;
  const AContext: TMcpConfigContext): TMcpServerArray;
var
  I, J: Integer;
  Winner: array of Integer;   // index into ARows, -1 = none
  Names: array of string;
  Count: Integer;

  function NameIndex(const AName: string): Integer;
  var
    K: Integer;
  begin
    for K := 0 to Count - 1 do
      if Names[K] = AName then
        Exit(K);
    Result := -1;
  end;

begin
  Result := nil;
  Count := 0;
  SetLength(Names, 0);
  SetLength(Winner, 0);
  for I := 0 to High(ARows) do
  begin
    if not RowApplies(ARows[I], AContext) then
      Continue;
    J := NameIndex(ARows[I].Name);
    if J < 0 then
    begin
      SetLength(Names, Count + 1);
      SetLength(Winner, Count + 1);
      Names[Count] := ARows[I].Name;
      Winner[Count] := I;
      Inc(Count);
    end
    else if ScopeRank(ARows[I].Scope) >= ScopeRank(ARows[Winner[J]].Scope) then
      Winner[J] := I;   // more specific (or equal: later) wins
  end;

  for I := 0 to Count - 1 do
  begin
    if not ARows[Winner[I]].Enabled then
      Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := ToConfig(ARows[Winner[I]]);
  end;
  SortByName(Result);
end;

function ValidateMcpServerRow(const ARow: TMcpServerRow;
  out AError: string): Boolean;
var
  I, P: Integer;
begin
  AError := '';
  if not IsValidMcpName(ARow.Name) then
  begin
    AError := 'server name "' + ARow.Name + '" is empty, too long, or has ' +
      'illegal characters (allowed: [A-Za-z0-9_-])';
    Exit(False);
  end;
  if ARow.Command = '' then
  begin
    AError := 'server "' + ARow.Name + '" has an empty command';
    Exit(False);
  end;
  for I := 0 to High(ARow.Env) do
  begin
    P := Pos('=', ARow.Env[I]);
    if (P <= 1) then
    begin
      AError := 'server "' + ARow.Name + '" has an invalid env entry "' +
        ARow.Env[I] + '" (expected NAME=VALUE)';
      Exit(False);
    end;
  end;
  Result := True;
end;

function ValidateMcpConfig(const AServers: TMcpServerArray;
  out AError: string): Boolean;
begin
  AError := '';
  if Length(AServers) > MaxMcpServers then
  begin
    AError := 'too many MCP servers: ' + IntToStr(Length(AServers)) +
      ' (max ' + IntToStr(MaxMcpServers) + ')';
    Exit(False);
  end;
  Result := True;
end;

end.
