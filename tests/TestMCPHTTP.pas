unit TestMCPHTTP;
{ fpcunit tests for HildiMCPHTTP. Pure body parsing (JSON and SSE);
  no network. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, HildiMCPHTTP;

type
  TMcpHttpTest = class(TTestCase)
  published
    procedure TestPlainJsonBodyIsOneMessage;
    procedure TestSseBodyYieldsMessages;
    procedure TestEmptyBodyYieldsNothing;
  end;

implementation

procedure TMcpHttpTest.TestPlainJsonBodyIsOneMessage;
var
  Msgs: TStringArray;
begin
  Msgs := ParseHttpMessages('{"jsonrpc":"2.0","id":1,"result":{}}',
    'application/json');
  AssertEquals('one message', 1, Length(Msgs));
  AssertEquals('payload', '{"jsonrpc":"2.0","id":1,"result":{}}', Msgs[0]);
end;

procedure TMcpHttpTest.TestSseBodyYieldsMessages;
var
  Msgs: TStringArray;
  Body: string;
begin
  Body := 'event: message' + #10 + 'data: {"jsonrpc":"2.0","id":1}' + #10 + #10 +
    'data: {"jsonrpc":"2.0","id":2}' + #10 + #10;
  Msgs := ParseHttpMessages(Body, 'text/event-stream; charset=utf-8');
  AssertEquals('two messages', 2, Length(Msgs));
  AssertEquals('first', '{"jsonrpc":"2.0","id":1}', Msgs[0]);
  AssertEquals('second', '{"jsonrpc":"2.0","id":2}', Msgs[1]);
end;

procedure TMcpHttpTest.TestEmptyBodyYieldsNothing;
begin
  AssertEquals('empty json', 0, Length(ParseHttpMessages('', 'application/json')));
  AssertEquals('empty sse', 0, Length(ParseHttpMessages('', 'text/event-stream')));
end;

initialization
  RegisterTest(TMcpHttpTest);
end.
