unit hildegard.helper.transcript;
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
  Classes, SysUtils, hildegard.helper.ansi;

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
    procedure OnToolCall(const AId, AName, AArguments: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    procedure WriteError(const AMessage: string);
    procedure EndTurn;
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
    BeginSection(AnsiBold('[user]'));
    PutLine(AUserText);
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

procedure TTranscriptWriter.OnToolCall(const AId, AName, AArguments: string);
begin
  if not FOptions.ShowTools then
    Exit;
  BeginSection(AnsiStyled('[tool ' + AName + ']', AnsiCyan));
  PutLine('args: ' + AArguments);
end;

procedure TTranscriptWriter.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
begin
  if not FOptions.ShowTools then
    Exit;
  EnsureNewline;
  if AOk then
    PutLine('result: ' + AResult)
  else
    PutLine(AnsiStyled('error: ' + AResult, AnsiRed));
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

end.
