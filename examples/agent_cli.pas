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
  SysUtils, Classes, ctypes,
  hildegard.helper.ansi, hildegard.helper.env, hildegard.helper.cli,
  hildegard.helper.transcript, hildegard.helper.llm, hildegard.helper.agent;

const
  DefaultSystemPrompt =
    'You are a helpful assistant running inside hildegard-helper. ' +
    'Use the provided tools when they help answer the user.';

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
  PromptText, Line, Answer: string;
  Err: TLLMError;
  I: Integer;

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
      WriteLn('hildegard-helper-agent (model: ', Config.Model, ')');
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
    Tools.Free;
    Store := nil;
    Client.Free;
  end;
end.
