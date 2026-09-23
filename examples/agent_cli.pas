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
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, Classes, ctypes, DateUtils,
  hildegard.helper.ansi, hildegard.helper.env, hildegard.helper.cli,
  hildegard.helper.transcript, hildegard.helper.llm, hildegard.helper.agent,
  hildegard.helper.command.policy, hildegard.helper.command.tool,
  hildegard.helper.approval, hildegard.helper.approval.store,
  hildegard.helper.session, hildegard.helper.session.store,
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
  ApprovalStore: IApprovalStore;
  ApprovalService: IApprovalService;
  Approver: TConsoleApprover;
  ApprovalCtx: TApprovalContext;
  CommandTool: TCommandTool;
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
          '  ', Summaries[I].RecordCount, ' records');
    SqliteStore.Close;
    SqliteStore.Free;
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
  AgentConfig.MaxToolIterations := 8;

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
    Store := TSqliteConversationStore.Create(SqliteStore, SessionId, TailCount);
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
