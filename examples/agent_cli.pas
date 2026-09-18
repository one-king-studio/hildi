program agent_cli;
{ Interactive multi-turn CLI over the agent loop, with coloured output:
  reasoning is dimmed, tool calls are cyan, tool results are green (red on
  failure), and errors are red.

  Configure via environment (no secrets on disk):
    HILDEGARD_LLM_ENDPOINT   default: Fireworks chat-completions URL
    HILDEGARD_LLM_MODEL      e.g. accounts/fireworks/models/<model>
    HILDEGARD_LLM_API_KEY    or FIREWORKS_API_KEY
    HILDEGARD_SYSTEM_PROMPT  optional

  Flags: --no-color, --color

  Run:  make agent-cli && ./build/bin/hildegard-helper-agent-cli
  Exit: /exit, /quit, or Ctrl-D }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, hildegard.helper.ansi, hildegard.helper.env,
  hildegard.helper.llm, hildegard.helper.agent;

const
  DefaultSystemPrompt =
    'You are a helpful assistant running inside hildegard-helper. ' +
    'Use the provided tools when they help answer the user.';

type
  { Renders agent events: reasoning dim, tool calls cyan, results green. }
  TConsoleSink = class
  public
    procedure OnText(const AText: string);
    procedure OnReasoning(const AText: string);
    procedure OnToolCall(const AId, AName, AArguments: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
  end;

procedure TConsoleSink.OnText(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

procedure TConsoleSink.OnReasoning(const AText: string);
begin
  Write(AnsiDim(AText));
  Flush(Output);
end;

procedure TConsoleSink.OnToolCall(const AId, AName, AArguments: string);
begin
  Write(LineEnding + AnsiStyled('[tool] ' + AName + '(' + AArguments + ')',
    AnsiCyan) + LineEnding);
  Flush(Output);
end;

procedure TConsoleSink.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
var
  Line: string;
begin
  Line := '  -> ' + AResult;
  if AOk then
    Write(AnsiStyled(Line, AnsiGreen))
  else
    Write(AnsiStyled('  !! ' + AResult, AnsiRed));
  Write(LineEnding);
  Flush(Output);
end;

function IsExitCommand(const ALine: string): Boolean;
begin
  Result := (ALine = '/exit') or (ALine = '/quit') or (ALine = 'exit') or
    (ALine = 'quit');
end;

procedure ApplyColorFlags;
var
  I: Integer;
  Arg: string;
begin
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg = '--no-color' then
      AnsiSetEnabled(False)
    else if Arg = '--color' then
      AnsiSetEnabled(True);
  end;
end;

var
  Config: TLLMConfig;
  Client: TLLMClient;
  Store: IConversationStore;
  Tools: TToolRegistry;
  AgentConfig: TAgentConfig;
  Loop: TAgentLoop;
  Sink: TConsoleSink;
  Events: TAgentEvents;
  Line, Answer: string;
  Err: TLLMError;

begin
  LoadDotEnvFile('.env');           // optional local config; shell env wins
  ApplyColorFlags;

  Config := Default(TLLMConfig);
  Config := ResolveLLMConfig(Config);
  if Config.ApiKey = '' then
  begin
    WriteLn('error: no API key. Set HILDEGARD_LLM_API_KEY or FIREWORKS_API_KEY.');
    Halt(1);
  end;
  if Config.Model = '' then
  begin
    WriteLn('error: no model. Set HILDEGARD_LLM_MODEL.');
    Halt(1);
  end;

  AgentConfig.SystemPrompt := GetEnvironmentVariable('HILDEGARD_SYSTEM_PROMPT');
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := DefaultSystemPrompt;
  AgentConfig.MaxToolIterations := 8;

  Client := TLLMClient.Create(Config, nil);
  Store := TMemoryConversationStore.Create;
  Tools := TToolRegistry.Create;
  RegisterDefaultTools(Tools);
  Sink := TConsoleSink.Create;
  Loop := TAgentLoop.Create(Client, Store, Tools, AgentConfig);

  Events := Default(TAgentEvents);
  Events.OnText := Sink.OnText;
  Events.OnReasoning := Sink.OnReasoning;
  Events.OnToolCall := Sink.OnToolCall;
  Events.OnToolResult := Sink.OnToolResult;

  try
    WriteLn('hildegard-helper agent (model: ', Config.Model, ')');
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

      Answer := '';
      Err.Code := leOk;
      if Loop.Send(Line, Events, Answer, Err) then
      begin
        if Answer = '' then
          WriteLn('(no text response)');
        WriteLn;
      end
      else
        WriteLn(AnsiStyled('[error] ' + Err.Message + ' (' + Err.Detail + ')',
          AnsiRed));
    end;
    WriteLn('bye');
  finally
    Loop.Free;
    Sink.Free;
    Tools.Free;
    Store := nil;
    Client.Free;
  end;
end.
