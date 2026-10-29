unit hildi.mcp.cli;
{ Pure parsing for the `mcp` admin subcommand (add/list/remove/enable/disable).
  No store, no I/O, so it is fully unit-testable. The agent CLI dispatches the
  parsed command to the store. See MCP_Admin_CLI_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildi.mcp.config;

type
  TMcpVerb = (mvList, mvAdd, mvRemove, mvEnable, mvDisable, mvTest,
              mvImport, mvExport, mvAuth, mvHelp);

  { A parsed `mcp` command. Fields are meaningful per Verb. }
  TMcpCommand = record
    Verb: TMcpVerb;
    Name: string;                 // add/remove/enable/disable
    Command: string;              // add: the executable
    Args: array of string;        // add: server argv (after --)
    Scope: TMcpScope;             // default msGlobal
    Env: array of string;         // add: NAME=VALUE (repeatable)
    WorkingDir: string;           // add: --cwd
    Disabled: Boolean;            // add: --disabled
    Path: string;                 // import: file; export: --out target
    Url: string;                  // add: --url (HTTP server)
    Headers: array of string;     // add: --header 'Name: value' (repeatable)
  end;

  EMcpCLIError = class(Exception);

{ Parse the args after the `mcp` verb. Raises EMcpCLIError on a bad verb,
  option, or missing operand. }
function ParseMcpCommand(const AArgs: array of string): TMcpCommand;

{ A stable listing (sorted by scope then name). }
function FormatMcpServers(const ARows: TMcpServerRowArray): string;

function McpUsageText: string;

implementation

function ScopeToWire(AScope: TMcpScope): string;
begin
  case AScope of
    msGlobal: Result := 'global';
    msWorkspace: Result := 'workspace';
    msAgent: Result := 'agent';
  end;
end;

function ParseScope(const AValue: string; out AScope: TMcpScope): Boolean;
begin
  Result := True;
  if AValue = 'global' then
    AScope := msGlobal
  else if AValue = 'workspace' then
    AScope := msWorkspace
  else if AValue = 'agent' then
    AScope := msAgent
  else
    Result := False;
end;

function VerbOf(const AWord: string; out AVerb: TMcpVerb): Boolean;
begin
  Result := True;
  if AWord = 'list' then AVerb := mvList
  else if AWord = 'add' then AVerb := mvAdd
  else if AWord = 'remove' then AVerb := mvRemove
  else if AWord = 'enable' then AVerb := mvEnable
  else if AWord = 'disable' then AVerb := mvDisable
  else if AWord = 'test' then AVerb := mvTest
  else if AWord = 'import' then AVerb := mvImport
  else if AWord = 'export' then AVerb := mvExport
  else if AWord = 'auth' then AVerb := mvAuth
  else if (AWord = 'help') or (AWord = '--help') or (AWord = '-h') then
    AVerb := mvHelp
  else
    Result := False;
end;

function ParseMcpCommand(const AArgs: array of string): TMcpCommand;
var
  I: Integer;
  Arg: string;
  InArgs: Boolean;
  Positionals: array of string;
  NPos: Integer;

  procedure AddPos(const AValue: string);
  begin
    SetLength(Positionals, NPos + 1);
    Positionals[NPos] := AValue;
    Inc(NPos);
  end;

  procedure AddEnv(const AValue: string);
  begin
    if Pos('=', AValue) <= 1 then
      raise EMcpCLIError.Create('--env requires NAME=VALUE, got: ' + AValue);
    SetLength(Result.Env, Length(Result.Env) + 1);
    Result.Env[High(Result.Env)] := AValue;
  end;

begin
  Result := Default(TMcpCommand);
  Result.Scope := msGlobal;
  NPos := 0;
  Positionals := nil;
  InArgs := False;

  if Length(AArgs) = 0 then
    raise EMcpCLIError.Create('mcp: a subcommand is required (list|add|remove|' +
      'enable|disable)');
  if not VerbOf(AArgs[0], Result.Verb) then
    raise EMcpCLIError.Create('mcp: unknown subcommand: ' + AArgs[0]);

  I := 1;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    if InArgs then
    begin
      SetLength(Result.Args, Length(Result.Args) + 1);
      Result.Args[High(Result.Args)] := Arg;
    end
    else if Arg = '--' then
      InArgs := True
    else if Arg = '--scope' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--scope requires a value');
      if not ParseScope(AArgs[I], Result.Scope) then
        raise EMcpCLIError.Create('--scope must be global|workspace, got: ' +
          AArgs[I]);
    end
    else if Arg = '--env' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--env requires a value');
      AddEnv(AArgs[I]);
    end
    else if Arg = '--cwd' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--cwd requires a value');
      Result.WorkingDir := AArgs[I];
    end
    else if Arg = '--disabled' then
      Result.Disabled := True
    else if Arg = '--out' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--out requires a value');
      Result.Path := AArgs[I];
    end
    else if Arg = '--url' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--url requires a value');
      Result.Url := AArgs[I];
    end
    else if Arg = '--header' then
    begin
      Inc(I);
      if I > High(AArgs) then
        raise EMcpCLIError.Create('--header requires a value');
      if Pos(':', AArgs[I]) <= 1 then
        raise EMcpCLIError.Create('--header requires "Name: value", got: ' +
          AArgs[I]);
      SetLength(Result.Headers, Length(Result.Headers) + 1);
      Result.Headers[High(Result.Headers)] := AArgs[I];
    end
    else if (Arg <> '') and (Arg[1] = '-') then
      raise EMcpCLIError.Create('mcp: unknown option: ' + Arg)
    else
      AddPos(Arg);
    Inc(I);
  end;

  case Result.Verb of
    mvAdd:
      begin
        { stdio: NAME COMMAND -- ARGS... ; http: NAME --url URL }
        if (NPos < 1) or ((NPos < 2) and (Result.Url = '')) then
          raise EMcpCLIError.Create(
            'mcp add: NAME and COMMAND (or NAME --url URL) are required');
        Result.Name := Positionals[0];
        if Result.Url = '' then
          Result.Command := Positionals[1];
      end;
    mvRemove, mvEnable, mvDisable, mvTest, mvAuth:
      begin
        if NPos < 1 then
          raise EMcpCLIError.Create('mcp: a server NAME is required');
        Result.Name := Positionals[0];
      end;
    mvImport:
      begin
        if NPos < 1 then
          raise EMcpCLIError.Create('mcp import: a FILE is required');
        Result.Path := Positionals[0];
      end;
    mvList, mvExport, mvHelp:
      ;
  end;
end;

function ScopeRank(AScope: TMcpScope): Integer;
begin
  Result := Ord(AScope);
end;

function FormatMcpServers(const ARows: TMcpServerRowArray): string;
var
  Sorted: TMcpServerRowArray;
  I, J: Integer;
  Tmp: TMcpServerRow;
  Line, ArgsStr, State: string;
begin
  Sorted := Copy(ARows, 0, Length(ARows));
  for I := 0 to High(Sorted) - 1 do
    for J := I + 1 to High(Sorted) do
      if (ScopeRank(Sorted[J].Scope) < ScopeRank(Sorted[I].Scope)) or
        ((Sorted[J].Scope = Sorted[I].Scope) and
         (Sorted[J].Name < Sorted[I].Name)) then
      begin
        Tmp := Sorted[I];
        Sorted[I] := Sorted[J];
        Sorted[J] := Tmp;
      end;

  Result := '';
  if Length(Sorted) = 0 then
    Exit('(no MCP servers configured)');
  for I := 0 to High(Sorted) do
  begin
    ArgsStr := '';
    if Sorted[I].Transport = mtHttp then
      ArgsStr := Sorted[I].Url
    else
      for J := 0 to High(Sorted[I].Args) do
        ArgsStr := ArgsStr + ' ' + Sorted[I].Args[J];
    if Sorted[I].Enabled then
      State := 'enabled'
    else
      State := 'disabled';
    Line := Format('%-9s  %-16s  %s%s  [%s]',
      [ScopeToWire(Sorted[I].Scope), Sorted[I].Name, Sorted[I].Command,
       ArgsStr, State]);
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Line;
  end;
end;

function McpUsageText: string;
begin
  Result :=
    'Manage MCP servers (configuration only; does not connect).' + LineEnding +
    LineEnding +
    'Usage:' + LineEnding +
    '  hildi-agent-cli mcp list [--scope global|workspace]' +
      LineEnding +
    '  hildi-agent-cli mcp add NAME COMMAND [OPTIONS] -- [ARGS...]' +
      LineEnding +
    '  hildi-agent-cli mcp remove NAME [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp enable NAME [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp disable NAME [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp test NAME [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp auth NAME [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp import FILE [--scope ...]' + LineEnding +
    '  hildi-agent-cli mcp export [--scope ...] [--out FILE]' +
      LineEnding +
    LineEnding +
    'Options (add):' + LineEnding +
    '  --scope global|workspace   where the server is defined (default global)' +
      LineEnding +
    '  --env NAME=VALUE           environment addition (repeatable)' +
      LineEnding +
    '  --cwd DIR                  working directory for the child' + LineEnding +
    '  --disabled                 add it disabled' + LineEnding +
    '  --url URL                  add an HTTP server (instead of COMMAND)' +
      LineEnding +
    '  --header "Name: value"     HTTP request header (repeatable)' + LineEnding +
    LineEnding +
    'Example:' + LineEnding +
    '  mcp add playwright docker -- run -i --rm --init ' +
      'mcr.microsoft.com/playwright/mcp' + LineEnding +
    '  mcp add meta --url https://mcp.example.com/rpc ' +
      '--header "Authorization: Bearer TOKEN"';
end;

end.
