program agent_cli;
{ hildegard-helper agent: a Unix-style CLI that turns an instruction into work.

  Interactive by default; `-p/--prompt` (or piped stdin) runs a single prompt.
  Output is a labelled, pipeable transcript with an optional token-rate limit:

    agent -p "what time is it?"
    agent -p "summarise notes.md" --no-reasoning --max-tps 40 | less -R
    echo "list the files here" | agent

  Config from environment or ./.env:
    HILDEGARD_LLM_ENDPOINT, HILDEGARD_LLM_MODEL,
    HILDEGARD_LLM_API_KEY (or FIREWORKS_API_KEY), HILDEGARD_SYSTEM_PROMPT

  Run:  make agent-cli && ./build/bin/hildegard-helper-agent-cli --help }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes, ctypes, DateUtils, SyncObjs, Process,
  {$ifdef unix}BaseUnix,{$endif}
  hildegard.helper.ansi, hildegard.helper.env, hildegard.helper.cli,
  hildegard.helper.transcript, hildegard.helper.llm, hildegard.helper.agent,
  hildegard.helper.command.policy, hildegard.helper.command.tool,
  hildegard.helper.files,
  hildegard.helper.approval, hildegard.helper.approval.store,
  hildegard.helper.session, hildegard.helper.session.store,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.recall.tool,
  hildegard.helper.mcp.cli, hildegard.helper.mcp.config,
  hildegard.helper.mcp.client,
  hildegard.helper.mcp.oauth, hildegard.helper.mcp.oauth.flow,
  hildegard.helper.store, hildegard.helper.workspace;

{$ifdef unix}
function c_isatty(Fd: cint): cint; cdecl; external 'c' name 'isatty';
{$endif}

function StdinIsTTY: Boolean;
begin
  {$ifdef unix}
  Result := c_isatty(0) <> 0;
  {$else}
  Result := True;
  {$endif}
end;

function ReadAllStdin: string;
var
  Lines: TStringList;
  Line: string;
begin
  Lines := TStringList.Create;
  try
    while not EOF(Input) do
    begin
      ReadLn(Line);
      Lines.Add(Line);
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function IsExitCommand(const ALine: string): Boolean;
begin
  Result := (ALine = '/exit') or (ALine = '/quit') or (ALine = 'exit') or
    (ALine = 'quit');
end;

function CollectArgs: TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 1 to ParamCount do
    Result.Add(ParamStr(I));
end;

procedure Fatal(const AMessage: string; ACode: Integer);
begin
  WriteLn(AnsiStyled('error: ' + AMessage, AnsiRed));
  Halt(ACode);
end;

type
  { Renders the tool's approval options and reads the operator's choice. }
  TConsoleApprover = class
  public
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

{ Renders a restored conversation tail using the transcript conventions. }
function TConsoleApprover.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
var
  Line, ScopeLine: string;
  N, I: Integer;
  Scope: TApprovalScope;
begin
  Result := Default(TApprovalChoice);
  Result.Allowed := False;
  WriteLn;
  WriteLn(AnsiStyled('[approval needed]', AnsiYellow));
  WriteLn('  command: ', AAsk.Summary);
  for I := 0 to High(AAsk.Options) do
    WriteLn(Format('    %d) %s', [I + 1, AAsk.Options[I].Caption]));
  Write('  choose (0 = deny): ');
  Flush(Output);
  if EOF(Input) then
    Exit;
  ReadLn(Line);
  N := StrToIntDef(Trim(Line), 0);
  if (N < 1) or (N > Length(AAsk.Options)) then
    Exit;

  Scope := asWorkspace;
  if AAsk.Options[N - 1].Persists then
  begin
    Write('  scope [g]lobal / [w]orkspace / [s]ession (default w): ');
    Flush(Output);
    if EOF(Input) then
      Exit;
    ReadLn(ScopeLine);
    ScopeLine := LowerCase(Trim(ScopeLine));
    if ScopeLine = 'g' then
      Scope := asGlobal
    else if ScopeLine = 's' then
      Scope := asSession
    else
      Scope := asWorkspace;
  end;
  Result.Allowed := True;
  Result.OptionKey := AAsk.Options[N - 1].Key;
  Result.Scope := Scope;
end;

type
  { Maps the headless wire events onto the transcript writer. Its callbacks run
    on the client's reader thread; the writer is only touched from there. }
  TSessionObserver = class(TInterfacedObject, ISessionSink)
  private
    FWriter: TTranscriptWriter;
    FDone: TSimpleEvent;
    FTurnOpen: Boolean;
  public
    constructor Create(AWriter: TTranscriptWriter);
    destructor Destroy; override;
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
    property Done: TSimpleEvent read FDone;
  end;

constructor TSessionObserver.Create(AWriter: TTranscriptWriter);
begin
  inherited Create;
  FWriter := AWriter;
  FDone := TSimpleEvent.Create;
  FTurnOpen := False;
end;

destructor TSessionObserver.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TSessionObserver.OnHello(const AHello: TSessionHello);
begin
end;

procedure TSessionObserver.OnAttached(const AAttached: TSessionAttached);
begin
  WriteLn(AnsiDim(Format('attached as %s (driver: %s, last_seq: %d)',
    [SessionRoleToWire(AAttached.Role),
     AAttached.Driver + ' ',
     AAttached.LastSeq])));
end;

procedure TSessionObserver.OnEvent(const AEvent: TSessionEvent);
begin
  case AEvent.Kind of
    ekUserMessage:
      begin
        FWriter.BeginTurn(AEvent.Text);
        FTurnOpen := True;
      end;
    ekAssistantDelta:
      FWriter.OnText(AEvent.Text);
    ekReasoningDelta:
      FWriter.OnReasoning(AEvent.Text);
    ekToolCall:
      FWriter.OnToolCall(AEvent.ToolId, AEvent.ToolName, AEvent.ToolArguments,
        AEvent.ToolReason);
    ekToolResult:
      FWriter.OnToolResult(AEvent.ToolId, AEvent.ToolName, AEvent.Text,
        AEvent.ToolOk);
    ekError:
      FWriter.WriteError(AEvent.Text + ' (' + AEvent.Detail + ')');
    ekTurnFinished:
      begin
        if FTurnOpen then
          FWriter.EndTurn;
        FTurnOpen := False;
      end;
  else
    ;
  end;
end;

procedure TSessionObserver.OnDetached(const AReason: string);
begin
  WriteLn(AnsiDim('detached: ' + AReason));
  FDone.SetEvent;
end;

procedure TSessionObserver.OnError(const ACode, AMessage: string);
begin
  WriteLn(AnsiStyled('error: ' + ACode + ': ' + AMessage, AnsiRed));
end;

{ Attach to a headless session: render its ledger history, then stream the live
  turn. As the driver, read prompts from stdin. }
procedure RunAttach(const ASessionId, AWorkspaceRoot, AStorePath: string;
  ADrive, AShowReasoning, AShowTools: Boolean);
var
  Store: TSqliteStore;
  Conv: TSqliteConversationStore;
  History: TChatMessageArray;
  StoreErr: TStoreError;
  StoreConfig: TStoreConfig;
  OutStream: TStream;
  TOpts: TTranscriptOptions;
  Writer: TTranscriptWriter;
  Observer: TSessionObserver;
  Sink: ISessionSink;
  Client: TSessionClient;
  Cfg: TSessionClientConfig;
  Err, Line: string;
  Cmd: TSessionCommand;
  PromptSeq: Integer;
begin
  StoreConfig := Default(TStoreConfig);
  StoreConfig.DatabasePath := AStorePath;
  StoreConfig.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreConfig);
  try
    if not Store.Open(StoreErr) then
      Fatal('attach: could not open store: ' + StoreErr.Message, 1);
    Conv := TSqliteConversationStore.Create(Store, ASessionId, 0);
    try
      History := Conv.Messages;
    finally
      Conv.Free;
    end;
  finally
    Store.Close;
    Store.Free;
  end;

  OutStream := THandleStream.Create(StdOutputHandle);
  TOpts := Default(TTranscriptOptions);
  TOpts.ShowUser := True;
  TOpts.ShowTools := AShowTools;
  TOpts.ShowReasoning := AShowReasoning;
  Writer := TTranscriptWriter.Create(OutStream, TOpts);
  Observer := TSessionObserver.Create(Writer);
  Sink := Observer;
  try
    if Length(History) > 0 then
    begin
      WriteLn(AnsiDim('--- history (' + IntToStr(Length(History)) +
        ' messages) ---'));
      Writer.RenderHistory(History);
      WriteLn;
    end;

    Cfg := Default(TSessionClientConfig);
    Cfg.SessionId := ASessionId;
    Cfg.WorkspacePath := AWorkspaceRoot;
    Cfg.StorePath := AStorePath;
    if ADrive then
      Cfg.Role := srDrive
    else
      Cfg.Role := srObserve;
    Cfg.Spawn := True;
    Cfg.SpawnTimeoutMs := 5000;
    Cfg.RuntimeCommand := ResolveRuntimeBinary(
      GetEnvironmentVariable('HILDEGARD_RUNTIME_BIN'), ParamStr(0));
    Client := TSessionClient.Open(Cfg, Sink, Err);
    if Client = nil then
      Fatal('attach: ' + Err, 1);
    try
      if ADrive then
      begin
        PromptSeq := 0;
        WriteLn('Attached as driver. Type a message; /exit or Ctrl-D to quit.');
        while True do
        begin
          Write(AnsiBold('> '));
          Flush(Output);
          if EOF(Input) then
            Break;
          ReadLn(Line);
          if IsExitCommand(Trim(Line)) then
            Break;
          if Trim(Line) = '' then
            Continue;
          Inc(PromptSeq);
          Cmd := Default(TSessionCommand);
          Cmd.Kind := scPrompt;
          Cmd.Id := 'p' + IntToStr(PromptSeq);
          Cmd.Text := Line;
          Client.Send(Cmd);
        end;
        Client.Close;
      end
      else
        Observer.Done.WaitFor(INFINITE);
    finally
      Client.Free;
    end;
  finally
    Sink := nil;
    Observer := nil;
    Writer.Free;
    OutStream.Free;
  end;
end;

{ Apply a parsed `mcp` command to the store. Config only: never spawns a
  server. Returns the process exit code. }
function McpScopeName(AScope: TMcpScope): string;
begin
  case AScope of
    msGlobal: Result := 'global';
    msWorkspace: Result := 'workspace';
    msAgent: Result := 'agent';
  end;
end;

{ Connect to one configured server, list its tools, and disconnect. }
function ReadFileText(const APath: string): string;
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.LoadFromFile(APath);
    Result := F.Text;
  finally
    F.Free;
  end;
end;

procedure WriteFileText(const APath, AText: string);
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.Text := AText;
    F.SaveToFile(APath);
  finally
    F.Free;
  end;
end;

{ A browser opener for the OAuth flow: prints the URL for copy/paste, then
  offers to open it (Enter). Uses the platform opener; no GUI dependency. }
type
  TConsoleBrowser = class
  public
    procedure Open(const AUrl: string);
  end;

{ Hand the URL to the platform opener, detached (best effort). }
procedure OpenInBrowser(const AUrl: string);
var
  Proc: TProcess;
begin
  {$ifdef unix}
  Proc := TProcess.Create(nil);
  try
    try
      {$ifdef darwin}
      Proc.Executable := 'open';
      {$else}
      Proc.Executable := 'xdg-open';
      {$endif}
      Proc.Parameters.Add(AUrl);
      Proc.Options := [poDetached];
      Proc.Execute;
    except
      on E: Exception do
        WriteLn('(could not open a browser automatically: ', E.Message, ')');
    end;
  finally
    Proc.Free;
  end;
  {$endif}
end;

procedure TConsoleBrowser.Open(const AUrl: string);
var
  Line: string;
begin
  WriteLn;
  WriteLn('Open this URL in your browser to authorize:');
  WriteLn;
  WriteLn('  ', AUrl);
  WriteLn;
  Write('Press Enter to open it in your browser, or paste the URL yourself ' +
    '(Ctrl-C to cancel): ');
  Flush(Output);
  if not EOF(Input) then
    ReadLn(Line);
  if Line = '' then
    OpenInBrowser(AUrl);
  WriteLn('Waiting for authorization ...');
end;

{ Run the OAuth flow for one configured server and store the token. }
function RunMcpAuth(AStore: TSqliteStore; const ARow: TMcpServerRow): Integer;
var
  PRM: TProtectedResourceMeta;
  ASMeta: TAuthServerMeta;
  Flow: TOAuthFlow;
  Browser: TConsoleBrowser;
  Tokens: TOAuthTokens;
  Row: TOAuthTokenRow;
  StoreErr: TStoreError;
  Err: string;
begin
  if ARow.Transport <> mtHttp then
  begin
    WriteLn('error: server "', ARow.Name, '" is not an HTTP server');
    Exit(1);
  end;
  WriteLn('authorizing "', ARow.Name, '" (', ARow.Url, ')');
  if not DiscoverProtectedResource(ARow.Url, PRM, Err) then
  begin
    WriteLn('error: discovery failed: ', Err);
    Exit(1);
  end;
  if Length(PRM.AuthorizationServers) = 0 then
  begin
    WriteLn('error: no authorization server advertised');
    Exit(1);
  end;
  if not DiscoverAuthServer(PRM.AuthorizationServers[0], ASMeta, Err) then
  begin
    WriteLn('error: authorization-server metadata failed: ', Err);
    Exit(1);
  end;

  Browser := TConsoleBrowser.Create;
  Flow := TOAuthFlow.Create(ASMeta, ARow.Url);
  try
    if not Flow.Run('', '', '', Browser.Open, Tokens, Err) then
    begin
      WriteLn('error: authorization failed: ', Err);
      Exit(1);
    end;
  finally
    Flow.Free;
    Browser.Free;
  end;

  Row := Default(TOAuthTokenRow);
  Row.Scope := ARow.Scope;
  Row.WorkspaceId := ARow.WorkspaceId;
  Row.ServerName := ARow.Name;
  Row.ClientId := Tokens.ClientId;
  Row.ClientSecret := Tokens.ClientSecret;
  Row.AccessToken := Tokens.AccessToken;
  Row.RefreshToken := Tokens.RefreshToken;
  Row.ExpiresAt := Tokens.ExpiresAt;
  Row.TokenScope := Tokens.TokenScope;
  if not AStore.SaveOAuthToken(Row, StoreErr) then
  begin
    WriteLn('error: could not save token: ', StoreErr.Message);
    Exit(1);
  end;
  WriteLn('authorized "', ARow.Name, '"; token stored.');
  Result := 0;
end;

function RunMcpTest(const ARow: TMcpServerRow): Integer;
var
  Cfg: TMcpClientConfig;
  Client: TMcpClient;
  Err: string;
  Tools: TMcpToolArray;
  I: Integer;
begin
  Cfg := Default(TMcpClientConfig);
  Cfg.Server.Name := ARow.Name;
  Cfg.Server.Transport := ARow.Transport;
  Cfg.Server.Command := ARow.Command;
  Cfg.Server.Args := Copy(ARow.Args, 0, Length(ARow.Args));
  Cfg.Server.Url := ARow.Url;
  Cfg.Server.Headers := Copy(ARow.Headers, 0, Length(ARow.Headers));
  Cfg.Server.Env := Copy(ARow.Env, 0, Length(ARow.Env));
  Cfg.Server.WorkingDir := ARow.WorkingDir;
  Cfg.ListTimeoutMs := ARow.ListTimeoutMs;
  Cfg.CallTimeoutMs := ARow.CallTimeoutMs;

  WriteLn('testing "', ARow.Name, '" ...');
  Client := TMcpClient.Create(Cfg, nil, nil);
  try
    if not Client.Open(Err) then
    begin
      WriteLn('FAILED: ', Err);
      Exit(1);
    end;
    Tools := Client.Tools;
    WriteLn(Format('OK: %d tools', [Length(Tools)]));
    for I := 0 to High(Tools) do
      WriteLn('  ', Tools[I].Name, '   [', Tools[I].Ref, ']');
    Result := 0;
  finally
    Client.Free;
  end;
end;

function RunMcpAdmin(const AArgs: array of string): Integer;
var
  Cmd: TMcpCommand;
  StorePath, WSErr, Msg: string;
  Store: TSqliteStore;
  StoreErr: TStoreError;
  Cfg: TStoreConfig;
  Workspace: TWorkspace;
  WorkspaceId: Integer;
  Row: TMcpServerRow;
  Rows: TMcpServerRowArray;
  Ctx: TMcpConfigContext;
  Existing: TMcpServerRowArray;
  I, J: Integer;
  Text: string;
  Added, Updated: Integer;
  WasThere: Boolean;
begin
  Result := 0;
  try
    Cmd := ParseMcpCommand(AArgs);
  except
    on E: EMcpCLIError do
    begin
      WriteLn('error: ', E.Message);
      Halt(2);
    end;
  end;

  if Cmd.Verb = mvHelp then
  begin
    WriteLn(McpUsageText);
    Exit(0);
  end;

  StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
  if StorePath = '' then
    StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
      '.hildegard-helper' + PathDelim + 'store.db';
  ForceDirectories(ExtractFileDir(StorePath));
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := StorePath;
  Cfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(Cfg);
  try
    if not Store.Open(StoreErr) then
    begin
      WriteLn('error: could not open store: ', StoreErr.Message);
      Exit(1);
    end;

    if Cmd.Verb = mvList then
    begin
      if Cmd.Scope = msWorkspace then
      begin
        Workspace := TWorkspace.Open('', WSErr);
        if Workspace = nil then
        begin
          WriteLn('error: workspace: ', WSErr);
          Exit(1);
        end;
        try
          if not Store.EnsureWorkspace(Workspace.Root, WorkspaceId, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := WorkspaceId;
          if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
        finally
          Workspace.Free;
        end;
      end
      else if not Store.ListMcpServers(Rows, StoreErr) then
      begin
        WriteLn('error: ', StoreErr.Message);
        Exit(1);
      end;
      WriteLn(FormatMcpServers(Rows));
      Exit(0);
    end;

    { Resolve the scope's workspace id for writes. }
    Row := Default(TMcpServerRow);
    Row.Name := Cmd.Name;
    Row.Scope := Cmd.Scope;
    if Cmd.Scope = msWorkspace then
    begin
      Workspace := TWorkspace.Open('', WSErr);
      if Workspace = nil then
      begin
        WriteLn('error: workspace: ', WSErr);
        Exit(1);
      end;
      try
        if not Store.EnsureWorkspace(Workspace.Root, WorkspaceId, StoreErr) then
        begin
          WriteLn('error: ', StoreErr.Message);
          Exit(1);
        end;
      finally
        Workspace.Free;
      end;
      Row.WorkspaceId := WorkspaceId;
    end;

    case Cmd.Verb of
      mvTest:
        begin
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          Msg := '';
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
            begin
              Row := Rows[I];
              Msg := 'found';
            end;
          if Msg = '' then
          begin
            WriteLn('error: no such server "', Row.Name, '"');
            Exit(1);
          end;
          Exit(RunMcpTest(Row));
        end;
      mvAuth:
        begin
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          Msg := '';
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
            begin
              Row := Rows[I];
              Msg := 'found';
            end;
          if Msg = '' then
          begin
            WriteLn('error: no such server "', Row.Name, '"');
            Exit(1);
          end;
          Exit(RunMcpAuth(Store, Row));
        end;
      mvAdd:
        begin
          if Cmd.Url <> '' then
          begin
            Row.Transport := mtHttp;
            Row.Url := Cmd.Url;
            Row.Headers := Copy(Cmd.Headers, 0, Length(Cmd.Headers));
          end
          else
          begin
            Row.Transport := mtStdio;
            Row.Command := Cmd.Command;
            Row.Args := Copy(Cmd.Args, 0, Length(Cmd.Args));
          end;
          Row.Env := Copy(Cmd.Env, 0, Length(Cmd.Env));
          Row.WorkingDir := Cmd.WorkingDir;
          Row.Enabled := not Cmd.Disabled;
          if not ValidateMcpServerRow(Row, Msg) then
          begin
            WriteLn('error: ', Msg);
            Exit(2);
          end;
          { Report insert vs update. }
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          Existing := nil;
          if Store.LoadMcpServers(Ctx, Existing, StoreErr) then
            for I := 0 to High(Existing) do
              if (Existing[I].Scope = Row.Scope) and
                (Existing[I].WorkspaceId = Row.WorkspaceId) and
                (Existing[I].Name = Row.Name) then
                Msg := 'updated'
              else
                Msg := '';
          if not Store.SaveMcpServer(Row, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          if Msg = 'updated' then
            WriteLn('mcp: updated server "', Row.Name, '" (', McpScopeName(Row.Scope),
              ')')
          else
            WriteLn('mcp: added server "', Row.Name, '" (', McpScopeName(Row.Scope),
              ')');
        end;
      mvRemove:
        begin
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          Rows := nil;
          if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          Msg := '';
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
              Msg := 'found';
          if Msg = '' then
          begin
            WriteLn('error: no such server "', Row.Name, '"');
            Exit(1);
          end;
          if not Store.RemoveMcpServer(Row, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          WriteLn('mcp: removed server "', Row.Name, '"');
        end;
      mvEnable, mvDisable:
        begin
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          Rows := nil;
          if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          Msg := '';
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
              Msg := Rows[I].Command;
          if Msg = '' then
          begin
            WriteLn('error: no such server "', Row.Name, '"');
            Exit(1);
          end;
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
              Rows[I].Enabled := (Cmd.Verb = mvEnable);
          { Save only the matching row. }
          for I := 0 to High(Rows) do
            if (Rows[I].Scope = Row.Scope) and
              (Rows[I].WorkspaceId = Row.WorkspaceId) and
              (Rows[I].Name = Row.Name) then
              if not Store.SaveMcpServer(Rows[I], StoreErr) then
              begin
                WriteLn('error: ', StoreErr.Message);
                Exit(1);
              end;
          if Cmd.Verb = mvEnable then
            WriteLn('mcp: enabled server "', Row.Name, '"')
          else
            WriteLn('mcp: disabled server "', Row.Name, '"');
        end;
      mvImport:
        begin
          if not FileExists(Cmd.Path) then
          begin
            WriteLn('error: no such file: ', Cmd.Path);
            Exit(1);
          end;
          Text := ReadFileText(Cmd.Path);
          if not ParseMcpServersJson(Text, Row.Scope, Row.WorkspaceId, Rows,
            Msg) then
          begin
            WriteLn('error: ', Msg);
            Exit(2);
          end;
          Added := 0;
          Updated := 0;
          for I := 0 to High(Rows) do
          begin
            Ctx := Default(TMcpConfigContext);
            Ctx.WorkspaceId := Rows[I].WorkspaceId;
            Existing := nil;
            WasThere := False;
            if Store.LoadMcpServers(Ctx, Existing, StoreErr) then
              for J := 0 to High(Existing) do
                if (Existing[J].Scope = Rows[I].Scope) and
                  (Existing[J].WorkspaceId = Rows[I].WorkspaceId) and
                  (Existing[J].Name = Rows[I].Name) then
                  WasThere := True;
            if not Store.SaveMcpServer(Rows[I], StoreErr) then
            begin
              WriteLn('error: ', StoreErr.Message);
              Exit(1);
            end;
            if WasThere then Inc(Updated) else Inc(Added);
          end;
          WriteLn(Format('mcp: imported %d added, %d updated',
            [Added, Updated]));
        end;
      mvExport:
        begin
          if Cmd.Scope = msWorkspace then
          begin
            Ctx := Default(TMcpConfigContext);
            Ctx.WorkspaceId := Row.WorkspaceId;
            if not Store.LoadMcpServers(Ctx, Rows, StoreErr) then
            begin
              WriteLn('error: ', StoreErr.Message);
              Exit(1);
            end;
          end
          else if not Store.ListMcpServers(Rows, StoreErr) then
          begin
            WriteLn('error: ', StoreErr.Message);
            Exit(1);
          end;
          { The JSON format is name-keyed, so collapse to one row per name. }
          Ctx := Default(TMcpConfigContext);
          Ctx.WorkspaceId := Row.WorkspaceId;
          Rows := EffectiveMcpRows(Rows, Ctx);
          Text := FormatMcpServersJson(Rows);
          if Cmd.Path <> '' then
          begin
            WriteFileText(Cmd.Path, Text);
            WriteLn('mcp: exported to ', Cmd.Path);
          end
          else
            WriteLn(Text);
        end;
      mvList, mvHelp:
        ;
    end;
  finally
    Store.Close;
    Store.Free;
  end;
end;

var
  RawArgs: TStringList;
  Args: array of string;
  Opts: TCLIOptions;
  Config: TLLMConfig;
  Client: TLLMClient;
  Store: IConversationStore;
  Tools: TToolRegistry;
  AgentConfig: TAgentConfig;
  Loop: TAgentLoop;
  OutStream: TStream;
  TOpts: TTranscriptOptions;
  Writer: TTranscriptWriter;
  Events: TAgentEvents;
  Interactive: Boolean;
  PromptText, Line,   Answer: string;
  Err: TLLMError;
  I: Integer;
  SqliteStore: TSqliteStore;
  RecallTool: TRecallTool;
  Conv: TSqliteConversationStore;
  ToolResultCap: Integer;
  ApprovalStore: IApprovalStore;
  ApprovalService: IApprovalService;
  Approver: TConsoleApprover;
  ApprovalCtx: TApprovalContext;
  CommandTool: TCommandTool;
  FileTool: TFileTool;
  FileToolConfig: TFileToolConfig;
  StorePath: string;
  StoreErr: TStoreError;
  StoreConfig: TStoreConfig;
  ToolConfig: TCommandToolConfig;
  Workspace: TWorkspace;
  WorkspacePath, WSErr: string;
  WorkspaceId: Integer;
  SessionId: string;
  Summaries: TSessionSummaryArray;
  TailCount, LoadedMessages: Integer;
  SessionResumed: Boolean;
  History: TChatMessageArray;

begin
  RawArgs := CollectArgs;
  { The `mcp` admin subcommand is handled before any LLM setup. }
  if (RawArgs.Count >= 1) and (RawArgs[0] = 'mcp') then
  begin
    SetLength(Args, RawArgs.Count - 1);
    for I := 1 to RawArgs.Count - 1 do
      Args[I - 1] := RawArgs[I];
    RawArgs.Free;
    Halt(RunMcpAdmin(Args));
  end;
  try
    try
      SetLength(Args, RawArgs.Count);
      for I := 0 to RawArgs.Count - 1 do
        Args[I] := RawArgs[I];
      Opts := ParseCLIOptions(Args);
    except
      on E: ECLIError do
      begin
        WriteLn('error: ', E.Message);
        WriteLn;
        WriteLn(UsageText);
        Halt(2);
      end;
    end;
  finally
    RawArgs.Free;
  end;

  if Opts.Help then
  begin
    WriteLn(UsageText);
    Halt(0);
  end;

  LoadDotEnvFile('.env');            // optional; shell env wins

  if Opts.ColorMode = tsOn then
    AnsiSetEnabled(True)
  else if Opts.ColorMode = tsOff then
    AnsiSetEnabled(False);

  WorkspacePath := Opts.Workspace;
  if WorkspacePath = '' then
    WorkspacePath := GetEnvironmentVariable('HILDEGARD_WORKSPACE');
  Workspace := TWorkspace.Open(WorkspacePath, WSErr);
  if Workspace = nil then
    Fatal('workspace: ' + WSErr, 1);

  if Opts.Mode = cmListSessions then
  begin
    StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
    if StorePath = '' then
      StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
        '.hildegard-helper' + PathDelim + 'store.db';
    ForceDirectories(ExtractFileDir(StorePath));
    StoreConfig := Default(TStoreConfig);
    StoreConfig.DatabasePath := StorePath;
    StoreConfig.BusyTimeoutMs := 5000;
    SqliteStore := TSqliteStore.Create(StoreConfig);
    if not SqliteStore.Open(StoreErr) then
      Fatal('could not open store: ' + StoreErr.Message, 1);
    if not SqliteStore.EnsureWorkspace(Workspace.Root, WorkspaceId, StoreErr) then
      Fatal('workspace: ' + StoreErr.Message, 1);
    if not SqliteStore.ListSessions(WorkspaceId, Summaries, StoreErr) then
      Fatal('could not list sessions: ' + StoreErr.Message, 1);
    if Length(Summaries) = 0 then
      WriteLn('no sessions for ', Workspace.Root)
    else
      for I := 0 to High(Summaries) do
        WriteLn(Summaries[I].Id, '  ',
          FormatDateTime('yyyy-mm-dd hh:nn',
            UnixToDateTime(Summaries[I].UpdatedAtMs div 1000)),
          '  ', Summaries[I].MessageCount, ' messages');
    SqliteStore.Close;
    SqliteStore.Free;
    Workspace.Free;
    Halt(0);
  end;

  if Opts.Mode = cmAttach then
  begin
    StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
    if StorePath = '' then
      StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
        '.hildegard-helper' + PathDelim + 'store.db';
    ForceDirectories(ExtractFileDir(StorePath));
    RunAttach(Opts.AttachSession, Workspace.Root, StorePath, Opts.AttachDrive,
      (Opts.Reasoning = tsOn) or (Opts.Reasoning = tsDefault), Opts.ShowTools);
    Workspace.Free;
    Halt(0);
  end;

  Config := Default(TLLMConfig);
  Config := ResolveLLMConfig(Config);
  if Opts.Model <> '' then
    Config.Model := Opts.Model;
  if Opts.Endpoint <> '' then
    Config.Endpoint := Opts.Endpoint;
  if Config.ApiKey = '' then
    Fatal('no API key. Set HILDEGARD_LLM_API_KEY or FIREWORKS_API_KEY.', 1);
  if Config.Model = '' then
    Fatal('no model. Set HILDEGARD_LLM_MODEL or use --model.', 1);

  Interactive := (Opts.Mode = cmInteractive) and StdinIsTTY;

  PromptText := Opts.Prompt;
  if Opts.PromptFromStdin then
    PromptText := ReadAllStdin
  else if not Interactive and (PromptText = '') then
  begin
    if StdinIsTTY then
      Fatal('no prompt given. See --help.', 2);
    PromptText := ReadAllStdin;
  end;

  AgentConfig.SystemPrompt := GetEnvironmentVariable('HILDEGARD_SYSTEM_PROMPT');
  if Opts.SystemPrompt <> '' then
    AgentConfig.SystemPrompt := Opts.SystemPrompt;
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := DefaultSystemPrompt;

  Client := TLLMClient.Create(Config, nil);
  Store := TMemoryConversationStore.Create;
  Tools := TToolRegistry.Create;
  RegisterDefaultTools(Tools);

  { Approvals persist in the SQLite store when it opens; otherwise they are
    session-only (in memory). Either way the shell tool is enabled and nothing
    runs without a matching approval or an explicit prompt. }
  CommandTool := nil;
  Approver := nil;
  ApprovalStore := nil;
  SqliteStore := nil;
  WorkspaceId := 0;
  StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
  if StorePath = '' then
    StorePath := IncludeTrailingPathDelimiter(GetUserDir) + '.hildegard-helper' +
      PathDelim + 'store.db';
  ForceDirectories(ExtractFileDir(StorePath));
  StoreConfig := Default(TStoreConfig);
  StoreConfig.DatabasePath := StorePath;
  StoreConfig.BusyTimeoutMs := 5000;
  SqliteStore := TSqliteStore.Create(StoreConfig);
  if SqliteStore.Open(StoreErr) then
  begin
    SqliteStore.EnsureWorkspace(Workspace.Root, WorkspaceId, StoreErr);
    ApprovalStore := TStoreApprovalStore.Create(SqliteStore);

    { Resume a named or most-recent session, or start a new one. }
    if (Opts.Session <> '') and Opts.ContinueSession then
      Fatal('choose either --session or --continue, not both', 2);
    SessionResumed := (Opts.Session <> '') or Opts.ContinueSession;
    SessionId := Opts.Session;
    if SessionId = '' then
    begin
      if Opts.ContinueSession then
      begin
        if not SqliteStore.MostRecentSessionId(WorkspaceId, SessionId, StoreErr)
        then
          Fatal('no session to continue for ' + Workspace.Root, 1);
      end
      else if not SqliteStore.CreateSession(WorkspaceId, SessionId, StoreErr)
      then
        Fatal('could not create session: ' + StoreErr.Message, 1);
    end
    else if not SqliteStore.SessionExists(SessionId, StoreErr) then
      Fatal('unknown session: ' + SessionId, 1);
    if Opts.SessionTail < 0 then
      TailCount := 5
    else
      TailCount := Opts.SessionTail;
    Store := nil;
    Conv := TSqliteConversationStore.Create(SqliteStore, SessionId, TailCount);
    ToolResultCap := ResolveToolResultCap(0);
    Conv.ToolResultCap := ToolResultCap;
    Store := Conv;
  end
  else
  begin
    WriteLn(AnsiStyled('warning: no store: approvals are session-only (' +
      StoreErr.Message + ')', AnsiYellow));
    SqliteStore.Free;
    SqliteStore := nil;
    ApprovalStore := TMemoryApprovalStore.Create;
  end;

  History := Store.Messages;
  LoadedMessages := Length(History);

  if Interactive then
    Approver := TConsoleApprover.Create;
  ApprovalCtx.WorkspaceId := WorkspaceId;
  ApprovalCtx.SessionId := SessionId;
  if Approver <> nil then
    ApprovalService := TApprovalService.Create(ApprovalStore, Approver.Prompt,
      ApprovalCtx)
  else
    ApprovalService := TApprovalService.Create(ApprovalStore, nil,
      ApprovalCtx);
  ToolConfig := Default(TCommandToolConfig);
  ToolConfig.Shell := DefaultShellProfile;
  ToolConfig.DefaultCwd := Workspace.Root;
  CommandTool := TCommandTool.Create(ToolConfig, ApprovalService);
  CommandTool.Register(Tools);

  FileToolConfig := Default(TFileToolConfig);
  FileToolConfig.Root := Workspace.Root;
  FileTool := TFileTool.Create(FileToolConfig, ApprovalService);
  FileTool.Register(Tools);

  { The recall tool reads stored artifacts; without a store there are none. }
  if SqliteStore <> nil then
  begin
    RecallTool := TRecallTool.Create(SqliteStore, SessionId, ToolResultCap);
    RecallTool.Register(Tools);
  end;

  Loop := TAgentLoop.Create(Client, Store, Tools, AgentConfig);

  OutStream := THandleStream.Create(StdOutputHandle);
  TOpts.ShowUser := Opts.ShowUser and not Interactive;
  TOpts.ShowTools := Opts.ShowTools;
  TOpts.ShowReasoning := (Opts.Reasoning = tsOn) or
    ((Opts.Reasoning = tsDefault) and Interactive);
  TOpts.MaxTokensPerSecond := Opts.MaxTokensPerSecond;
  Writer := TTranscriptWriter.Create(OutStream, TOpts);

  Events := Default(TAgentEvents);
  Events.OnText := Writer.OnText;
  Events.OnReasoning := Writer.OnReasoning;
  Events.OnToolCall := Writer.OnToolCall;
  Events.OnToolResult := Writer.OnToolResult;

  try
    if Interactive then
    begin
      WriteLn('hildegard-helper-agent');
      WriteLn('  workspace: ', Workspace.Root);
      if SessionId = '' then
        WriteLn('  session:   (in memory; no store)')
      else if SessionResumed then
        WriteLn('  session:   ', SessionId, '  (resumed, last ', LoadedMessages,
          ' messages)')
      else
        WriteLn('  session:   ', SessionId, '  (new)');
      WriteLn('  model:     ', Config.Model);
      if SqliteStore <> nil then
        WriteLn('  store:     ', StorePath)
      else
        WriteLn('  store:     (in memory)');
      if SessionResumed and (Length(History) > 0) then
      begin
        WriteLn;
        WriteLn(AnsiDim('--- recent history (' + IntToStr(Length(History)) +
          ' messages) ---'));
        Writer.RenderHistory(History);
        WriteLn;
      end;
      WriteLn('Type a message; /exit or Ctrl-D to quit.');
      while True do
      begin
        Write(AnsiBold('> '));
        Flush(Output);
        if EOF(Input) then
          Break;
        ReadLn(Line);
        if IsExitCommand(Trim(Line)) then
          Break;
        if Trim(Line) = '' then
          Continue;
        Writer.BeginTurn(Line);
        Answer := '';
        Err.Code := leOk;
        if Loop.Send(Line, Events, Answer, Err) then
        begin
          Writer.EndTurn;
          WriteLn;
        end
        else
        begin
          Writer.WriteError(Err.Message + ' (' + Err.Detail + ')');
          Writer.EndTurn;
        end;
      end;
      WriteLn('bye');
    end
    else
    begin
      Writer.BeginTurn(PromptText);
      Answer := '';
      Err.Code := leOk;
      if Loop.Send(PromptText, Events, Answer, Err) then
        Writer.EndTurn
      else
      begin
        Writer.WriteError(Err.Message + ' (' + Err.Detail + ')');
        Writer.EndTurn;
        Halt(1);
      end;
    end;
  finally
    Writer.Free;
    OutStream.Free;
    Loop.Free;
    FileTool.Free;
    RecallTool.Free;
    CommandTool.Free;
    Approver.Free;
    Tools.Free;
    ApprovalService := nil;
    ApprovalStore := nil;
    Store := nil;            // release the conversation adapter before the store
    if SqliteStore <> nil then
    begin
      SqliteStore.Close;
      SqliteStore.Free;
    end;
    Workspace.Free;
    Client.Free;
  end;
end.
