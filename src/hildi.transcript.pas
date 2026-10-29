unit hildi.transcript;
{ Renders an agent turn to a stream as a legible transcript: labelled, blank-
  line-separated sections for the user prompt, reasoning, tool calls, and the
  answer. Streaming text is written as it arrives; an optional token-rate limit
  paces deltas so fast models stay readable. Colours are no-ops when ANSI is
  disabled, so piped output stays plain.

  ponytail: pacing sleeps in the event callback, which runs on the thread reading
  the provider stream. Typical responses fit in the socket buffer; if a very low
  rate ever stalls a long response, move rendering to a consumer thread. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, hildi.ansi, hildi.llm;

type
  TTranscriptOptions = record
    ShowUser: Boolean;
    ShowReasoning: Boolean;
    ShowTools: Boolean;
    MaxTokensPerSecond: Integer;   // 0 = unlimited
  end;

  TTranscriptWriter = class
  private
    FOut: TStream;
    FOptions: TTranscriptOptions;
    FAnySection: Boolean;
    FLineOpen: Boolean;
    FHeaders: Boolean;          // labels only needed when colour is off
    FReasoningStarted: Boolean;
    FTextStarted: Boolean;
    FIntervalMs: Integer;
    FNextMs: QWord;
    procedure Put(const AText: string);
    procedure PutLine(const AText: string);
    procedure EnsureNewline;
    procedure BeginSection(const AHeader: string);
    procedure UpdateLineOpen(const AText: string);
    procedure Pace;
  public
    constructor Create(AOutput: TStream; const AOptions: TTranscriptOptions);
    procedure BeginTurn(const AUserText: string);
    procedure OnReasoning(const AText: string);
    procedure OnText(const AText: string);
    procedure OnToolCall(const AId, AName, AArguments, AReason: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    procedure WriteError(const AMessage: string);
    procedure EndTurn;
    { Renders a restored conversation (system skipped) using the same
      conventions, e.g. the tail of a resumed session. }
    procedure RenderHistory(const AMessages: TChatMessageArray);
  end;

implementation

constructor TTranscriptWriter.Create(AOutput: TStream;
  const AOptions: TTranscriptOptions);
begin
  inherited Create;
  FOut := AOutput;
  FOptions := AOptions;
  FAnySection := False;
  FLineOpen := False;
  FReasoningStarted := False;
  FTextStarted := False;
  FHeaders := not AnsiEnabled;   // colour already distinguishes sections
  if FOptions.MaxTokensPerSecond > 0 then
  begin
    FIntervalMs := 1000 div FOptions.MaxTokensPerSecond;
    if FIntervalMs < 1 then
      FIntervalMs := 1;
  end
  else
    FIntervalMs := 0;
  FNextMs := 0;
end;

procedure TTranscriptWriter.Put(const AText: string);
begin
  if AText <> '' then
    FOut.Write(AText[1], Length(AText));
end;

procedure TTranscriptWriter.PutLine(const AText: string);
begin
  Put(AText);
  Put(LineEnding);
  FLineOpen := False;
end;

procedure TTranscriptWriter.UpdateLineOpen(const AText: string);
begin
  if AText <> '' then
    FLineOpen := AText[Length(AText)] <> #10;
end;

procedure TTranscriptWriter.EnsureNewline;
begin
  if FLineOpen then
  begin
    Put(LineEnding);
    FLineOpen := False;
  end;
end;

procedure TTranscriptWriter.BeginSection(const AHeader: string);
begin
  EnsureNewline;
  if FAnySection then
    Put(LineEnding);
  FAnySection := True;
  if FHeaders then
    PutLine(AHeader);
end;

procedure TTranscriptWriter.Pace;
var
  NowMs, WaitMs: QWord;
begin
  if FIntervalMs <= 0 then
    Exit;
  NowMs := GetTickCount64;
  if FNextMs = 0 then
    FNextMs := NowMs;
  if NowMs < FNextMs then
  begin
    WaitMs := FNextMs - NowMs;
    Sleep(WaitMs);
    NowMs := GetTickCount64;
  end;
  FNextMs := NowMs + QWord(FIntervalMs);
end;

procedure TTranscriptWriter.BeginTurn(const AUserText: string);
begin
  FReasoningStarted := False;
  FTextStarted := False;
  if FOptions.ShowUser then
  begin
    EnsureNewline;
    if FAnySection then
      Put(LineEnding);
    FAnySection := True;
    PutLine(AnsiBold('> ') + AUserText);
  end;
end;

procedure TTranscriptWriter.OnReasoning(const AText: string);
begin
  if not FOptions.ShowReasoning then
    Exit;
  if not FReasoningStarted then
  begin
    BeginSection(AnsiBold('[reasoning]'));
    FReasoningStarted := True;
  end;
  Pace;
  Put(AnsiDim(AText));
  UpdateLineOpen(AText);
end;

procedure TTranscriptWriter.OnText(const AText: string);
begin
  if not FTextStarted then
  begin
    BeginSection(AnsiBold('[assistant]'));
    FTextStarted := True;
  end;
  Pace;
  Put(AText);
  UpdateLineOpen(AText);
end;

procedure TTranscriptWriter.OnToolCall(const AId, AName, AArguments,
  AReason: string);
begin
  if not FOptions.ShowTools then
    Exit;
  if FHeaders then
  begin
    BeginSection(AnsiStyled('[tool ' + AName + ']', AnsiCyan));
    PutLine('args: ' + AArguments);
    if AReason <> '' then
      PutLine('reason: ' + AReason);
  end
  else
  begin
    EnsureNewline;
    if FAnySection then
      Put(LineEnding);
    FAnySection := True;
    if AReason <> '' then
      PutLine(AnsiStyled(AName + '(' + AArguments + ') - ' + AReason, AnsiCyan))
    else
      PutLine(AnsiStyled(AName + '(' + AArguments + ')', AnsiCyan));
  end;
end;

procedure TTranscriptWriter.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
var
  Text: string;
begin
  if not FOptions.ShowTools then
    Exit;
  { A tool that produced nothing still ran; show a marker, not a blank line. }
  Text := AResult;
  if Text = '' then
    Text := '(no output)';
  EnsureNewline;
  if FHeaders then
  begin
    if AOk then
      PutLine('result: ' + Text)
    else
      PutLine(AnsiStyled('error: ' + Text, AnsiRed));
  end
  else
  begin
    if AOk then
      PutLine(AnsiStyled('  -> ' + Text, AnsiGreen))
    else
      PutLine(AnsiStyled('  !! ' + Text, AnsiRed));
  end;
end;

procedure TTranscriptWriter.WriteError(const AMessage: string);
begin
  BeginSection(AnsiStyled('[error]', AnsiRed));
  PutLine(AnsiStyled(AMessage, AnsiRed));
end;

procedure TTranscriptWriter.EndTurn;
begin
  EnsureNewline;
end;

procedure TTranscriptWriter.RenderHistory(const AMessages: TChatMessageArray);
var
  I, J: Integer;
  M: TChatMessage;
  SavedShowUser: Boolean;
begin
  { History shows user prompts even in modes that suppress live echoing. }
  SavedShowUser := FOptions.ShowUser;
  FOptions.ShowUser := True;
  try
    for I := 0 to High(AMessages) do
    begin
      M := AMessages[I];
      case M.Role of
        crSystem:
          ;   // configuration, not history
        crUser:
          BeginTurn(M.Content);
        crAssistant:
          begin
            if M.Content <> '' then
              OnText(M.Content);
            for J := 0 to High(M.ToolCalls) do
              OnToolCall(M.ToolCalls[J].Id, M.ToolCalls[J].Name,
                M.ToolCalls[J].Arguments, '');
          end;
        crTool:
          OnToolResult(M.ToolCallId, '', M.Content, True);
      end;
    end;
    EndTurn;
  finally
    FOptions.ShowUser := SavedShowUser;
  end;
end;

end.
