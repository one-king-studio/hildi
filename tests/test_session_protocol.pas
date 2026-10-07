unit test_session_protocol;
{ fpcunit tests for hildegard.helper.session.protocol: the pure NDJSON codec.
  Every message type and event kind must round-trip; malformed, unknown, and
  oversize lines must be rejected. No socket is involved. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.approval, hildegard.helper.llm,
  hildegard.helper.session.protocol;

type
  TSessionProtocolTest = class(TTestCase)
  private
    procedure AssertRoundTrip(const AMessage: TSessionMessage);
    procedure FillEvent(AKind: TSessionEventKind; out AEvent: TSessionEvent);
  published
    procedure TestRoundTripHello;
    procedure TestRoundTripAttachedCarriesStoreHwm;
    procedure TestRoundTripEveryEventKind;
    procedure TestReasoningDoneRoundTrip;
    procedure TestRoundTripReply;
    procedure TestRoundTripReplyError;
    procedure TestRoundTripDetached;
    procedure TestRoundTripError;
    procedure TestRoundTripAttach;
    procedure TestRoundTripDetach;
    procedure TestRoundTripPromptCommand;
    procedure TestRoundTripApproveCommand;
    procedure TestRoundTripPingPong;
    procedure TestRoundTripUnicodeText;
    procedure TestRoundTripAmbient;
    procedure TestRoundTripSubagent;
    procedure TestRoundTripSubagentAsk;
    procedure TestRoundTripAbortReleaseCommands;
    procedure TestRejectsBadJson;
    procedure TestRejectsUnknownType;
    procedure TestRejectsUnknownEventKind;
    procedure TestRejectsMissingVersion;
    procedure TestRejectsOversizeLine;
  end;

implementation

procedure TSessionProtocolTest.AssertRoundTrip(const AMessage: TSessionMessage);
var
  Line1, Line2: string;
  Decoded: TSessionMessage;
begin
  Line1 := TSessionCodec.Encode(AMessage);
  AssertTrue('decode failed for ' + Line1, TSessionCodec.Decode(Line1, Decoded));
  Line2 := TSessionCodec.Encode(Decoded);
  AssertEquals('round trip: ' + Line1, Line1, Line2);
end;

procedure TSessionProtocolTest.FillEvent(AKind: TSessionEventKind;
  out AEvent: TSessionEvent);
begin
  AEvent := Default(TSessionEvent);
  AEvent.Kind := AKind;
  AEvent.Seq := 7;
  AEvent.Ts := 1700000000000;
  case AKind of
    ekLoopStarted:
      begin
        AEvent.LoopId := 'loop-1';
        AEvent.SessionId := 'sess-1';
      end;
    ekTurnStarted:
      AEvent.TurnSeq := 3;
    ekUserMessage, ekAssistantDelta, ekAssistantBlock, ekReasoningDelta:
      AEvent.Text := 'some text';
    ekToolCall:
      begin
        AEvent.ToolId := 'call_1';
        AEvent.ToolName := 'run_command';
        AEvent.ToolArguments := '{"reason":"why"}';
        AEvent.ToolReason := 'why';
      end;
    ekToolResult:
      begin
        AEvent.ToolId := 'call_1';
        AEvent.ToolName := 'run_command';
        AEvent.ToolOk := True;
        AEvent.Text := 'output';
      end;
    ekApprovalRequest:
      begin
        AEvent.AskId := 'ask_1';
        AEvent.Ask.Summary := 'rm -rf /tmp/x';
        AEvent.Ask.Reason := 'cleanup';
        SetLength(AEvent.Ask.Options, 2);
        AEvent.Ask.Options[0].Key := 'once';
        AEvent.Ask.Options[0].Caption := 'Allow once';
        AEvent.Ask.Options[1].Key := 'always';
        AEvent.Ask.Options[1].Caption := 'Always allow';
      end;
    ekApprovalResolved:
      begin
        AEvent.AskId := 'ask_1';
        AEvent.Choice.Allowed := True;
        AEvent.Choice.OptionKey := 'once';
        AEvent.Choice.Scope := asSession;
      end;
    ekDriveRequested, ekDriveGranted, ekDriveReleased:
      AEvent.Client := 'client-9';
    ekTurnFinished:
      begin
        AEvent.FinishReason := 'stop';
        AEvent.Usage.PromptTokens := 10;
        AEvent.Usage.CompletionTokens := 20;
        AEvent.Usage.TotalTokens := 30;
        AEvent.Usage.CachedTokens := 4;
        AEvent.Usage.ReasoningTokens := 2;
        AEvent.ElapsedMs := 1234;
      end;
    ekError:
      begin
        AEvent.ErrorCode := 'provider';
        AEvent.Text := 'boom';
        AEvent.Detail := 'the detail';
        AEvent.Dropped := True;
      end;
    ekGap:
      begin
        AEvent.FromSeq := 5;
        AEvent.ToSeq := 9;
      end;
    ekLoopExited:
      AEvent.Reason := 'idle';
    ekReasoningDone:
      AEvent.ElapsedMs := 2300;
    ekToolOutput:
      begin
        AEvent.ToolId := 'call_1';
        AEvent.ToolName := 'run_command';
        AEvent.Text := 'chunk';
      end;
    ekAmbient:
      begin
        AEvent.SubSessionId := 'child-1';
        AEvent.Text := 'the delegated result';
        AEvent.ElapsedMs := 4200;
      end;
    ekSubagent:
      begin
        AEvent.SubSessionId := 'child-1';
        AEvent.Text := 'research';
        AEvent.SubStatus := 'completed';
      end;
    ekSubagentAsk:
      begin
        AEvent.SubSessionId := 'child-1';
        AEvent.AskId := 'ask_1';
        AEvent.Ask.Summary := 'subagent wants to run a command';
        AEvent.Ask.Reason := 'delegated work';
        SetLength(AEvent.Ask.Options, 1);
        AEvent.Ask.Options[0].Key := 'once';
        AEvent.Ask.Options[0].Caption := 'Allow once';
      end;
  end;
end;

procedure TSessionProtocolTest.TestRoundTripHello;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkHello;
  M.Hello.Protocol := SessionProtocolName;
  M.Hello.Version := SessionProtocolVersion;
  M.Hello.SessionId := 'sess-1';
  M.Hello.LoopId := 'loop-1';
  M.Hello.Caps := [srObserve, srDrive];
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('hello protocol', SessionProtocolName, D.Hello.Protocol);
  AssertEquals('hello version', SessionProtocolVersion, D.Hello.Version);
  AssertEquals('hello session', 'sess-1', D.Hello.SessionId);
  AssertEquals('hello loop', 'loop-1', D.Hello.LoopId);
  AssertTrue('caps observe', srObserve in D.Hello.Caps);
  AssertTrue('caps drive', srDrive in D.Hello.Caps);
end;

procedure TSessionProtocolTest.TestRoundTripAttachedCarriesStoreHwm;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkAttached;
  M.Attached.Role := srDrive;
  M.Attached.Driver := 'client-1';
  M.Attached.LastSeq := 42;
  M.Attached.StoreHwm := 99;
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('granted role', Ord(srDrive), Ord(D.Attached.Role));
  AssertEquals('driver', 'client-1', D.Attached.Driver);
  AssertEquals('last_seq', 42, D.Attached.LastSeq);
  AssertEquals('store_hwm', 99, D.Attached.StoreHwm);
end;

procedure TSessionProtocolTest.TestRoundTripEveryEventKind;
var
  K: TSessionEventKind;
  E: TSessionEvent;
  M, D: TSessionMessage;
begin
  for K := Low(TSessionEventKind) to High(TSessionEventKind) do
  begin
    FillEvent(K, E);
    M := Default(TSessionMessage);
    M.Kind := mkEvent;
    M.Event := E;
    AssertRoundTrip(M);

    AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
    AssertEquals('kind preserved for ' + SessionEventKindToWire(K),
      Ord(K), Ord(D.Event.Kind));
    AssertEquals('seq preserved for ' + SessionEventKindToWire(K), 7,
      D.Event.Seq);
  end;
end;

procedure TSessionProtocolTest.TestReasoningDoneRoundTrip;
var
  E: TSessionEvent;
  M, D: TSessionMessage;
begin
  FillEvent(ekReasoningDone, E);
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event := E;
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('kind', Ord(ekReasoningDone), Ord(D.Event.Kind));
  AssertEquals('elapsed', 2300, D.Event.ElapsedMs);
end;

procedure TSessionProtocolTest.TestRoundTripReply;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkReply;
  M.ReplyId := 'c1';
  M.Ok := True;
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('reply id', 'c1', D.ReplyId);
  AssertTrue('reply ok', D.Ok);
  AssertEquals('reply error', '', D.ErrorCode);
end;

procedure TSessionProtocolTest.TestRoundTripReplyError;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkReply;
  M.ReplyId := 'c1';
  M.Ok := False;
  M.ErrorCode := 'not_driver';
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertFalse('reply not ok', D.Ok);
  AssertEquals('reply error', 'not_driver', D.ErrorCode);
end;

procedure TSessionProtocolTest.TestRoundTripDetached;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkDetached;
  M.Reason := 'loop exited';
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('detached reason', 'loop exited', D.Reason);
end;

procedure TSessionProtocolTest.TestRoundTripError;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkError;
  M.ErrorCode := 'bad_version';
  M.ErrorMessage := 'unsupported protocol version';
  M.Detail := 'v9';
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('error code', 'bad_version', D.ErrorCode);
  AssertEquals('error message', 'unsupported protocol version',
    D.ErrorMessage);
  AssertEquals('error detail', 'v9', D.Detail);
end;

procedure TSessionProtocolTest.TestRoundTripAttach;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkAttach;
  M.Command.Kind := scAttach;
  M.Command.FromSeq := 12;
  M.Command.Role := srDrive;
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('attach from_seq', 12, D.Command.FromSeq);
  AssertEquals('attach role', Ord(srDrive), Ord(D.Command.Role));
end;

procedure TSessionProtocolTest.TestRoundTripDetach;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkDetach;
  M.Command.Kind := scDetach;
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('detach kind', Ord(mkDetach), Ord(D.Kind));
end;

procedure TSessionProtocolTest.TestRoundTripPromptCommand;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkCmd;
  M.Command.Kind := scPrompt;
  M.Command.Id := 'c7';
  M.Command.Text := 'list the files';
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('cmd id', 'c7', D.Command.Id);
  AssertEquals('cmd kind', Ord(scPrompt), Ord(D.Command.Kind));
  AssertEquals('cmd text', 'list the files', D.Command.Text);
end;

procedure TSessionProtocolTest.TestRoundTripApproveCommand;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkCmd;
  M.Command.Kind := scApprove;
  M.Command.Id := 'c8';
  M.Command.AskId := 'ask_2';
  M.Command.Choice.Allowed := True;
  M.Command.Choice.OptionKey := 'always';
  M.Command.Choice.Scope := asWorkspace;
  AssertRoundTrip(M);

  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('approve ask_id', 'ask_2', D.Command.AskId);
  AssertTrue('approve allowed', D.Command.Choice.Allowed);
  AssertEquals('approve option', 'always', D.Command.Choice.OptionKey);
  AssertEquals('approve scope', Ord(asWorkspace), Ord(D.Command.Choice.Scope));
end;

procedure TSessionProtocolTest.TestRoundTripPingPong;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkPing;
  M.Command.Kind := scPing;
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('ping kind', Ord(mkPing), Ord(D.Kind));

  M := Default(TSessionMessage);
  M.Kind := mkPong;
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('pong kind', Ord(mkPong), Ord(D.Kind));
end;

procedure TSessionProtocolTest.TestRoundTripUnicodeText;
var
  M, D: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  FillEvent(ekAssistantDelta, M.Event);
  M.Event.Text := 'héllo — 世界 🌍';
  AssertRoundTrip(M);
  AssertTrue(TSessionCodec.Decode(TSessionCodec.Encode(M), D));
  AssertEquals('unicode text', 'héllo — 世界 🌍', D.Event.Text);
end;

procedure TSessionProtocolTest.TestRejectsBadJson;
var
  M: TSessionMessage;
begin
  AssertFalse('truncated object', TSessionCodec.Decode('{"v":1,"type"', M));
  AssertFalse('not an object', TSessionCodec.Decode('[1,2,3]', M));
  AssertFalse('empty line', TSessionCodec.Decode('', M));
end;

procedure TSessionProtocolTest.TestRejectsUnknownType;
var
  M: TSessionMessage;
begin
  AssertFalse('unknown type', TSessionCodec.Decode('{"v":1,"type":"nope"}', M));
  AssertFalse('missing type', TSessionCodec.Decode('{"v":1}', M));
end;

procedure TSessionProtocolTest.TestRejectsUnknownEventKind;
var
  M: TSessionMessage;
begin
  AssertFalse('unknown kind', TSessionCodec.Decode(
    '{"v":1,"type":"event","seq":1,"ts":1,"kind":"nope"}', M));
end;

procedure TSessionProtocolTest.TestRejectsMissingVersion;
var
  M: TSessionMessage;
begin
  AssertFalse('no v', TSessionCodec.Decode('{"type":"ping"}', M));
  AssertFalse('v not a number', TSessionCodec.Decode(
    '{"v":"1","type":"ping"}', M));
end;

procedure TSessionProtocolTest.TestRejectsOversizeLine;
var
  M: TSessionMessage;
  Line: string;
begin
  Line := '{"v":1,"type":"event","seq":1,"ts":1,"kind":"user_message",' +
    '"text":"' + StringOfChar('x', DefaultMaxLineBytes) + '"}';
  AssertTrue('the fixture is oversize', Length(Line) > DefaultMaxLineBytes);
  AssertFalse('oversize line', TSessionCodec.Decode(Line, M));
end;

procedure TSessionProtocolTest.TestRoundTripAmbient;
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event.Kind := ekAmbient;
  M.Event.SubSessionId := 'child-1';
  M.Event.Text := 'result text';
  M.Event.ElapsedMs := 4200;
  AssertRoundTrip(M);
end;

procedure TSessionProtocolTest.TestRoundTripSubagent;
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event.Kind := ekSubagent;
  M.Event.SubSessionId := 'child-1';
  M.Event.Text := 'research';
  M.Event.SubStatus := 'running';
  AssertRoundTrip(M);
end;

procedure TSessionProtocolTest.TestRoundTripSubagentAsk;
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkEvent;
  M.Event.Kind := ekSubagentAsk;
  M.Event.SubSessionId := 'child-1';
  M.Event.AskId := 'ask_7';
  M.Event.Ask.Summary := 'subagent wants to run a command';
  M.Event.Ask.Reason := 'delegated work';
  AssertRoundTrip(M);
end;

procedure TSessionProtocolTest.TestRoundTripAbortReleaseCommands;
var
  M: TSessionMessage;
begin
  M := Default(TSessionMessage);
  M.Kind := mkCmd;
  M.Command.Kind := scAbortSubagent;
  M.Command.Id := 'c1';
  M.Command.SessionId := 'child-1';
  AssertRoundTrip(M);

  M := Default(TSessionMessage);
  M.Kind := mkCmd;
  M.Command.Kind := scReleaseSubagent;
  M.Command.Id := 'c2';
  M.Command.SessionId := 'child-2';
  AssertRoundTrip(M);
end;

initialization
  RegisterTest(TSessionProtocolTest);

end.
