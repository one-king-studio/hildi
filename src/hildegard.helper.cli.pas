unit hildegard.helper.cli;
{ Pure command-line parsing for the agent CLI. No terminal or I/O side effects,
  so it is fully unit-testable. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TTriState = (tsDefault, tsOn, tsOff);
  TCLIMode = (cmInteractive, cmOnce, cmListSessions);

  TCLIOptions = record
    Mode: TCLIMode;
    Prompt: string;
    PromptFromStdin: Boolean;
    SystemPrompt: string;
    Model: string;
    Endpoint: string;
    Workspace: string;
    Session: string;
    ContinueSession: Boolean;
    SessionTail: Integer;       // -1 = unset (5 on resume); 0 = all messages
    ShowUser: Boolean;
    ShowTools: Boolean;
    Reasoning: TTriState;        // tsDefault => on for interactive, off for once
    MaxTokensPerSecond: Integer;
    ColorMode: TTriState;
    Help: Boolean;
  end;

  ECLIError = class(Exception);

function ParseCLIOptions(const AArgs: array of string): TCLIOptions;
function UsageText: string;

implementation

function DefaultOptions: TCLIOptions;
begin
  Result := Default(TCLIOptions);
  Result.Mode := cmInteractive;
  Result.SessionTail := -1;
  Result.ShowUser := True;
  Result.ShowTools := True;
  Result.Reasoning := tsDefault;
  Result.ColorMode := tsDefault;
end;

function ValueOf(const AArgs: array of string; var AIndex: Integer;
  const AOption, AInline: string): string;
begin
  if AInline <> '' then
    Exit(AInline);
  Inc(AIndex);
  if AIndex > High(AArgs) then
    raise ECLIError.Create('option ' + AOption + ' requires a value');
  Result := AArgs[AIndex];
end;

function ParseCLIOptions(const AArgs: array of string): TCLIOptions;
var
  I: Integer;
  Arg, Key, Inline: string;
  Eq: Integer;
begin
  Result := DefaultOptions;
  I := 0;
  while I <= High(AArgs) do
  begin
    Arg := AArgs[I];
    Key := Arg;
    Inline := '';
    if (Copy(Arg, 1, 2) = '--') and (Pos('=', Arg) > 0) then
    begin
      Eq := Pos('=', Arg);
      Key := Copy(Arg, 1, Eq - 1);
      Inline := Copy(Arg, Eq + 1, MaxInt);
    end;

    if (Key = '-h') or (Key = '--help') then
      Result.Help := True
    else if (Key = '-i') or (Key = '--interactive') then
      Result.Mode := cmInteractive
    else if (Key = '-p') or (Key = '--prompt') then
    begin
      Result.Prompt := ValueOf(AArgs, I, Key, Inline);
      Result.Mode := cmOnce;
      if Result.Prompt = '-' then
      begin
        Result.Prompt := '';
        Result.PromptFromStdin := True;
      end;
    end
    else if Key = '--reasoning' then
      Result.Reasoning := tsOn
    else if Key = '--no-reasoning' then
      Result.Reasoning := tsOff
    else if Key = '--tools' then
      Result.ShowTools := True
    else if Key = '--no-tools' then
      Result.ShowTools := False
    else if Key = '--no-user' then
      Result.ShowUser := False
    else if Key = '--user' then
      Result.ShowUser := True
    else if (Key = '--max-tps') or (Key = '--tps') then
    begin
      Result.MaxTokensPerSecond :=
        StrToIntDef(ValueOf(AArgs, I, Key, Inline), -1);
      if Result.MaxTokensPerSecond < 0 then
        raise ECLIError.Create('--max-tps requires a non-negative integer');
    end
    else if Key = '--color' then
      Result.ColorMode := tsOn
    else if Key = '--no-color' then
      Result.ColorMode := tsOff
    else if (Key = '-s') or (Key = '--system') then
      Result.SystemPrompt := ValueOf(AArgs, I, Key, Inline)
    else if (Key = '-m') or (Key = '--model') then
      Result.Model := ValueOf(AArgs, I, Key, Inline)
    else if Key = '--endpoint' then
      Result.Endpoint := ValueOf(AArgs, I, Key, Inline)
    else if (Key = '-w') or (Key = '--workspace') then
      Result.Workspace := ValueOf(AArgs, I, Key, Inline)
    else if Key = '--session' then
      Result.Session := ValueOf(AArgs, I, Key, Inline)
    else if (Key = '-c') or (Key = '--continue') then
      Result.ContinueSession := True
    else if Key = '--tail' then
    begin
      Result.SessionTail := StrToIntDef(ValueOf(AArgs, I, Key, Inline), -1);
      if Result.SessionTail < 0 then
        raise ECLIError.Create('--tail requires a non-negative integer');
    end
    else if (Arg = '-') then
    begin
      Result.PromptFromStdin := True;
      Result.Mode := cmOnce;
    end
    else if (Arg <> '') and (Arg[1] = '-') then
      raise ECLIError.Create('unknown option: ' + Arg)
    else
    begin
      if (Result.Prompt <> '') or Result.PromptFromStdin or
        (Result.Mode = cmListSessions) then
        raise ECLIError.Create('prompt given more than once');
      if Arg = 'sessions' then
        Result.Mode := cmListSessions
      else
      begin
        Result.Prompt := Arg;
        Result.Mode := cmOnce;
      end;
    end;
    Inc(I);
  end;
end;

function UsageText: string;
begin
  Result :=
    'hildegard-helper-agent - a shell agent that turns instructions into work' +
    LineEnding + LineEnding +
    'Usage:' + LineEnding +
    '  hildegard-helper-agent                 interactive session' + LineEnding +
    '  hildegard-helper-agent -p "PROMPT"     run one prompt and exit' + LineEnding +
    '  echo "PROMPT" | hildegard-helper-agent  prompt from stdin' + LineEnding +
    '  hildegard-helper-agent sessions        list this workspace''s sessions' +
    LineEnding +
    LineEnding +
    'Options:' + LineEnding +
    '  -p, --prompt TEXT   run a single prompt (use - to read stdin)' +
    LineEnding +
    '  -i, --interactive   force interactive mode' + LineEnding +
    '      --reasoning     show model reasoning (default: interactive only)' +
    LineEnding +
    '      --no-reasoning  hide model reasoning' + LineEnding +
    '      --tools         show tool calls (default)' + LineEnding +
    '      --no-tools      hide tool calls' + LineEnding +
    '      --no-user       hide the echoed user prompt' + LineEnding +
    '      --max-tps N     cap streamed output to N tokens/second (0=off)' +
    LineEnding +
    '      --color         force colour on' + LineEnding +
    '      --no-color      force colour off' + LineEnding +
    '  -s, --system TEXT   system prompt' + LineEnding +
    '  -m, --model NAME    model name (overrides environment)' + LineEnding +
    '      --endpoint URL  provider endpoint (overrides environment)' +
    LineEnding +
    '  -w, --workspace DIR working directory for the agent (default: cwd)' +
    LineEnding +
    '      --session ID    resume a stored session (default: a new one)' +
    LineEnding +
    '  -c, --continue      resume the most recent session for the workspace' +
    LineEnding +
    '      --tail N        on resume, load the last N messages (default 5,' +
    LineEnding +
    '                      0 = all)' + LineEnding +
    '  -h, --help          show this help' + LineEnding +
    LineEnding +
    'Environment: HILDEGARD_LLM_ENDPOINT, HILDEGARD_LLM_MODEL,' +
    LineEnding +
    '  HILDEGARD_LLM_API_KEY (or FIREWORKS_API_KEY), HILDEGARD_WORKSPACE,' +
    LineEnding +
    '  HILDEGARD_STORE_PATH, and ./.env';
end;

end.
