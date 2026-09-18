program agent_cli;
{ Interactive multi-turn CLI over the agent loop.

  Configure via environment (no secrets on disk):
    HILDEGARD_LLM_ENDPOINT   default: Fireworks chat-completions URL
    HILDEGARD_LLM_MODEL      e.g. accounts/fireworks/models/<model>
    HILDEGARD_LLM_API_KEY    or FIREWORKS_API_KEY
    HILDEGARD_SYSTEM_PROMPT  optional

  Run:  make agent-cli && ./build/bin/hildegard-helper-agent-cli
  Exit: /exit, /quit, or Ctrl-D }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, hildegard.helper.llm, hildegard.helper.agent;

const
  DefaultSystemPrompt =
    'You are a helpful assistant running inside hildegard-helper. ' +
    'Use the provided tools when they help answer the user.';

type
  { Streams assistant text to stdout as it arrives. }
  TConsoleSink = class
  public
    procedure OnText(const AText: string);
  end;

procedure TConsoleSink.OnText(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

function IsExitCommand(const ALine: string): Boolean;
begin
  Result := (ALine = '/exit') or (ALine = '/quit') or (ALine = 'exit') or
    (ALine = 'quit');
end;

var
  Config: TLLMConfig;
  Client: TLLMClient;
  Store: IConversationStore;
  Tools: TToolRegistry;
  AgentConfig: TAgentConfig;
  Loop: TAgentLoop;
  Sink: TConsoleSink;
  Line, Answer: string;
  Err: TLLMError;

begin
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
  try
    WriteLn('hildegard-helper agent (model: ', Config.Model, ')');
    WriteLn('Type a message; /exit or Ctrl-D to quit.');
    while True do
    begin
      Write('> ');
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
      if Loop.Send(Line, Sink.OnText, Answer, Err) then
      begin
        if Answer = '' then
          WriteLn('(no text response)');
        WriteLn;
      end
      else
        WriteLn('[error] ', Err.Message, ' (', Err.Detail, ')');
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
