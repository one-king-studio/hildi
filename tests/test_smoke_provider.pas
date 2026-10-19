unit test_smoke_provider;
{ fpcunit tests for the live smoke's fake provider. Hermetic: loopback only, an
  ephemeral port, no external network. Proves the provider streams incrementally
  (the property the smoke exists to observe), replays scripts in order, and
  records what it was sent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  fphttpclient,
  smoke_provider;

type
  TSmokeProviderTest = class(TTestCase)
  private
    function Post(const AUrl, ABody: string; out AStatus: Integer): string;
  published
    procedure TestBindsAnEphemeralPort;
    procedure TestStartIsIdempotent;
    procedure TestOneRequestReplaysItsScript;
    procedure TestRecordsTheRequestBody;
    procedure TestScriptsRunInOrderAndTheLastRepeats;
    procedure TestErrorStatusIsReturned;
    procedure TestFramesArriveIncrementally;
    procedure TestStopIsSafeTwice;
  end;

implementation

function TSmokeProviderTest.Post(const AUrl, ABody: string;
  out AStatus: Integer): string;
var
  Client: TFPHTTPClient;
  Body: TStringStream;
begin
  Result := '';
  AStatus := 0;
  Client := TFPHTTPClient.Create(nil);
  Body := TStringStream.Create(ABody);
  try
    Client.RequestBody := Body;
    Client.AddHeader('Content-Type', 'application/json');
    try
      Result := Client.Post(AUrl);
      AStatus := Client.ResponseStatusCode;
    except
      on E: EHTTPClient do
        AStatus := Client.ResponseStatusCode;   // non-2xx raises; status is set
    end;
  finally
    Body.Free;
    Client.Free;
  end;
end;

procedure TSmokeProviderTest.TestBindsAnEphemeralPort;
var
  P: TFakeProvider;
  Err: string;
begin
  Err := '';                       // read in the message before Start sets it
  P := TFakeProvider.Create;
  try
    AssertTrue('starts: ' + Err, P.Start(Err));
    AssertTrue('a port was assigned', P.Port > 0);
    AssertEquals('endpoint shape',
      'http://127.0.0.1:' + IntToStr(P.Port) + '/v1/chat/completions',
      P.EndpointUrl);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestStartIsIdempotent;
var
  P: TFakeProvider;
  Err: string;
  Port: Word;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('first start', P.Start(Err));
    Port := P.Port;
    AssertTrue('second start is a no-op', P.Start(Err));
    AssertEquals('the port did not change', Port, P.Port);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestOneRequestReplaysItsScript;
var
  P: TFakeProvider;
  Err, Body: string;
  Status: Integer;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    P.Script(MakeScript([TextDelta('hello '), TextDelta('world'),
      FinishFrame('stop'), DoneFrame]));
    Body := Post(P.EndpointUrl, '{"model":"m"}', Status);
    AssertEquals('status', 200, Status);
    AssertTrue('first delta', Pos('hello ', Body) > 0);
    AssertTrue('second delta', Pos('world', Body) > 0);
    { fpjson's AsJSON puts spaces around the colon, so match on the parts. }
    AssertTrue('finish', (Pos('finish_reason', Body) > 0) and
      (Pos('"stop"', Body) > 0));
    AssertTrue('done marker', Pos('[DONE]', Body) > 0);
    AssertTrue('deltas are in order',
      Pos('hello ', Body) < Pos('world', Body));
    AssertEquals('no error was recorded', '', P.LastError);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestRecordsTheRequestBody;
var
  P: TFakeProvider;
  Err, Sent: string;
  Status: Integer;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    P.Script(MakeScript([DoneFrame]));
    Sent := '{"model":"probe","messages":[{"role":"user","content":"hi"}]}';
    Post(P.EndpointUrl, Sent, Status);
    AssertEquals('one request recorded', 1, P.RequestCount);
    AssertEquals('the body round-tripped', Sent, P.RequestBodyAt(0));
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestScriptsRunInOrderAndTheLastRepeats;
var
  P: TFakeProvider;
  Err, Body: string;
  Status: Integer;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    P.Script(MakeScript([TextDelta('first')]));
    P.Script(MakeScript([TextDelta('second')]));
    Body := Post(P.EndpointUrl, '{}', Status);
    AssertTrue('first script ran', Pos('first', Body) > 0);
    AssertTrue('second script did not', Pos('second', Body) = 0);
    Body := Post(P.EndpointUrl, '{}', Status);
    AssertTrue('second script ran', Pos('second', Body) > 0);
    { A third request repeats the last script, so a tool round trip that makes
      more calls than expected still terminates instead of hanging. }
    Body := Post(P.EndpointUrl, '{}', Status);
    AssertTrue('the last script repeats', Pos('second', Body) > 0);
    AssertEquals('three requests', 3, P.RequestCount);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestErrorStatusIsReturned;
var
  P: TFakeProvider;
  Err: string;
  S: TFakeScript;
  Status: Integer;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    S := Default(TFakeScript);
    S.StatusCode := 400;
    S.ErrorBody := '{"error":{"message":"bad request"}}';
    P.Script(S);
    Post(P.EndpointUrl, '{}', Status);
    AssertEquals('the scripted status is returned', 400, Status);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestFramesArriveIncrementally;
{ The reason this provider is not fphttpserver: a buffered response would show
  every frame at the same instant. Timing is measured, not asserted exactly, so
  the test is robust on a loaded machine: five frames with a 60 ms delay cannot
  legitimately arrive inside 90 ms. }
var
  P: TFakeProvider;
  Err, Body: string;
  S: TFakeScript;
  Status: Integer;
  Started, Elapsed: QWord;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    S := MakeScript([TextDelta('a'), TextDelta('b'), TextDelta('c'),
      FinishFrame('stop'), DoneFrame], 60);
    P.Script(S);
    Started := GetTickCount64;
    Body := Post(P.EndpointUrl, '{}', Status);
    Elapsed := GetTickCount64 - Started;
    AssertEquals('status', 200, Status);
    AssertTrue('all frames arrived', Pos('[DONE]', Body) > 0);
    AssertTrue('the frames were paced, not flushed at once (elapsed ' +
      IntToStr(Elapsed) + ' ms)', Elapsed >= 90);
  finally
    P.Free;
  end;
end;

procedure TSmokeProviderTest.TestStopIsSafeTwice;
var
  P: TFakeProvider;
  Err: string;
begin
  P := TFakeProvider.Create;
  try
    AssertTrue('start', P.Start(Err));
    P.Stop;
    P.Stop;                       // a double stop must not raise or block
    AssertTrue('still constructed', P.RequestCount = 0);
  finally
    P.Free;                       // Destroy stops again: three times, no crash
  end;
end;

initialization
  RegisterTest(TSmokeProviderTest);
end.
