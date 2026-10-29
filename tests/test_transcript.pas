unit test_transcript;
{ fpcunit tests for hildi.transcript. Rendering is asserted against a
  TStringStream; colour is forced off so output is deterministic. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.ansi, hildi.transcript, hildi.llm;

type
  TTranscriptTest = class(TTestCase)
  private
    FSavedColor: Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestUserSectionRendered;
    procedure TestAssistantSectionRendered;
    procedure TestReasoningSectionRenderedWhenEnabled;
    procedure TestReasoningSuppressedWhenDisabled;
    procedure TestToolSectionsRendered;
    procedure TestEmptyToolResultShowsPlaceholder;
    procedure TestTranscriptShowsToolCallReason;
    procedure TestToolsSuppressedWhenDisabled;
    procedure TestSectionsSeparatedByBlankLine;
    procedure TestErrorRendered;
    procedure TestNoEscapesWhenColorDisabled;
    procedure TestPacingDelaysOutput;
    procedure TestHeadersHiddenWhenColorEnabled;
    procedure TestRenderHistoryRestoresMessages;
  end;

implementation

type
  TWriterProc = procedure(W: TTranscriptWriter);

procedure TTranscriptTest.SetUp;
begin
  FSavedColor := AnsiEnabled;
  AnsiSetEnabled(False);
end;

procedure TTranscriptTest.TearDown;
begin
  AnsiSetEnabled(FSavedColor);
end;

function MakeOptions(AUser, AReasoning, ATools: Boolean;
  ARate: Integer): TTranscriptOptions;
begin
  Result.ShowUser := AUser;
  Result.ShowReasoning := AReasoning;
  Result.ShowTools := ATools;
  Result.MaxTokensPerSecond := ARate;
end;

{ Helper to run a scenario and return the rendered text. }
function RenderScenario(const AOptions: TTranscriptOptions;
  ARun: TWriterProc): string;
var
  Out_: TStringStream;
  W: TTranscriptWriter;
begin
  Out_ := TStringStream.Create('');
  W := TTranscriptWriter.Create(Out_, AOptions);
  try
    ARun(W);
    Result := Out_.DataString;
  finally
    W.Free;
    Out_.Free;
  end;
end;

procedure TurnUser(W: TTranscriptWriter);
begin
  W.BeginTurn('hello');
end;
procedure TurnText(W: TTranscriptWriter);
begin
  W.OnText('hi there');
  W.EndTurn;
end;
procedure TurnReasoning(W: TTranscriptWriter);
begin
  W.OnReasoning('thinking');
  W.EndTurn;
end;
procedure TurnTool(W: TTranscriptWriter);
begin
  W.OnToolCall('id1', 'get_system_time', '{}', 'why');
  W.OnToolResult('id1', 'get_system_time', '2026-01-01T00:00:00Z', True);
  W.EndTurn;
end;
procedure TurnError(W: TTranscriptWriter);
begin
  W.WriteError('boom');
  W.EndTurn;
end;

procedure TurnEmptyTool(W: TTranscriptWriter);
begin
  W.OnToolCall('id1', 'file_glob', '{"reason":"find"}', 'find');
  W.OnToolResult('id1', 'file_glob', '', True);
  W.EndTurn;
end;

procedure TTranscriptTest.TestUserSectionRendered;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(True, False, False, 0), TurnUser);
  AssertTrue('shell-style marker', Pos('> hello', S) > 0);
  AssertTrue('no [user] block', Pos('[user]', S) = 0);
end;

procedure TTranscriptTest.TestAssistantSectionRendered;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, False, 0), TurnText);
  AssertTrue('has assistant header', Pos('[assistant]', S) > 0);
  AssertTrue('has answer', Pos('hi there', S) > 0);
end;

procedure TTranscriptTest.TestReasoningSectionRenderedWhenEnabled;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, True, False, 0), TurnReasoning);
  AssertTrue('has reasoning header', Pos('[reasoning]', S) > 0);
  AssertTrue('has reasoning text', Pos('thinking', S) > 0);
end;

procedure TTranscriptTest.TestReasoningSuppressedWhenDisabled;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, False, 0), TurnReasoning);
  AssertTrue('no reasoning header', Pos('[reasoning]', S) = 0);
  AssertTrue('no reasoning text', Pos('thinking', S) = 0);
end;

procedure TTranscriptTest.TestToolSectionsRendered;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, True, 0), TurnTool);
  AssertTrue('tool header', Pos('[tool get_system_time]', S) > 0);
  AssertTrue('args', Pos('args: {}', S) > 0);
  AssertTrue('result', Pos('result: 2026-01-01T00:00:00Z', S) > 0);
end;

procedure TTranscriptTest.TestTranscriptShowsToolCallReason;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, True, 0), TurnTool);
  AssertTrue('reason line', Pos('reason: why', S) > 0);
end;

procedure TTranscriptTest.TestEmptyToolResultShowsPlaceholder;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, True, 0), TurnEmptyTool);
  AssertTrue('placeholder shown', Pos('result: (no output)', S) > 0);
end;

procedure TTranscriptTest.TestToolsSuppressedWhenDisabled;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, False, 0), TurnTool);
  AssertTrue('no tool header', Pos('[tool', S) = 0);
  AssertTrue('no result', Pos('result:', S) = 0);
end;

procedure TTranscriptTest.TestSectionsSeparatedByBlankLine;
var
  S: string;
  W: TTranscriptWriter;
  Out_: TStringStream;
begin
  Out_ := TStringStream.Create('');
  W := TTranscriptWriter.Create(Out_, MakeOptions(True, False, False, 0));
  try
    W.BeginTurn('q');
    W.OnText('a');
    W.EndTurn;
    S := Out_.DataString;
  finally
    W.Free;
    Out_.Free;
  end;
  AssertTrue('blank line before assistant',
    Pos(LineEnding + LineEnding + '[assistant]', S) > 0);
end;

procedure TTranscriptTest.TestErrorRendered;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(False, False, False, 0), TurnError);
  AssertTrue('error header', Pos('[error]', S) > 0);
  AssertTrue('error text', Pos('boom', S) > 0);
end;

procedure TTranscriptTest.TestNoEscapesWhenColorDisabled;
var
  S: string;
begin
  S := RenderScenario(MakeOptions(True, True, True, 0), TurnTool);
  AssertTrue('no escape sequences', Pos(#27, S) = 0);
end;

procedure TTranscriptTest.TestPacingDelaysOutput;
var
  S: string;
  Started: QWord;
  I: Integer;
  Out_: TStringStream;
  W: TTranscriptWriter;
  Opts: TTranscriptOptions;
begin
  Opts := MakeOptions(False, False, False, 100);   // 100/s => 10ms per delta
  Out_ := TStringStream.Create('');
  W := TTranscriptWriter.Create(Out_, Opts);
  try
    Started := GetTickCount64;
    for I := 1 to 5 do
      W.OnText('x');
    S := Out_.DataString;
    Started := GetTickCount64 - Started;
  finally
    W.Free;
    Out_.Free;
  end;
  AssertEquals('all deltas rendered', 5, Length(S) - Length('[assistant]' +
    LineEnding));
  AssertTrue('paced (>= 30ms for 5 at 100/s)', Started >= 30);
end;

procedure TTranscriptTest.TestHeadersHiddenWhenColorEnabled;
var
  S: string;
  Out_: TStringStream;
  W: TTranscriptWriter;
begin
  AnsiSetEnabled(True);
  Out_ := TStringStream.Create('');
  W := TTranscriptWriter.Create(Out_, MakeOptions(True, True, True, 0));
  try
    W.BeginTurn('hi');
    W.OnReasoning('think');
    W.OnToolCall('id', 'get_system_time', '{}', 'why');
    W.OnToolResult('id', 'get_system_time', '2026', True);
    W.OnText('answer');
    W.EndTurn;
    S := Out_.DataString;
  finally
    W.Free;
    Out_.Free;
    AnsiSetEnabled(False);
  end;
  AssertTrue('no section labels',
    (Pos('[assistant]', S) = 0) and (Pos('[reasoning]', S) = 0) and
    (Pos('[tool', S) = 0));
  AssertTrue('has colour escapes', Pos(#27, S) > 0);
  AssertTrue('tool call inlined', Pos('get_system_time({})', S) > 0);
  AssertTrue('prompt marker kept', Pos(AnsiBold('> '), S) > 0);
end;

procedure TTranscriptTest.TestRenderHistoryRestoresMessages;
var
  S: string;
  Out_: TStringStream;
  W: TTranscriptWriter;
  Msgs: TChatMessageArray;
  M: TChatMessage;
begin
  SetLength(Msgs, 3);
  M := Default(TChatMessage);
  M.Role := crSystem;
  M.Content := 'sys';
  Msgs[0] := M;
  M := Default(TChatMessage);
  M.Role := crUser;
  M.Content := 'what time?';
  Msgs[1] := M;
  M := Default(TChatMessage);
  M.Role := crAssistant;
  M.Content := 'noon';
  Msgs[2] := M;

  Out_ := TStringStream.Create('');
  { ShowUser is False in interactive mode; history must still show prompts. }
  W := TTranscriptWriter.Create(Out_, MakeOptions(False, False, True, 0));
  try
    W.RenderHistory(Msgs);
    S := Out_.DataString;
  finally
    W.Free;
    Out_.Free;
  end;
  AssertTrue('user shown', Pos('> what time?', S) > 0);
  AssertTrue('assistant shown', Pos('noon', S) > 0);
  AssertFalse('system hidden', Pos('sys', S) > 0);
end;

initialization
  RegisterTest(TTranscriptTest);
end.
