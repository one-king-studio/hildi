unit test_jsonrpc;
{ fpcunit tests for hildi.jsonrpc. The codec is pure, so every test
  is a direct encode/decode assertion with no I/O. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser, fpcunit, testregistry, hildi.jsonrpc;

type
  TJsonRpcTest = class(TTestCase)
  private
    { JSON-RPC is whitespace-insensitive; fpjson's AsJSON pretty-prints, so
      compare parsed JSON semantically rather than byte-for-byte. }
    procedure AssertJsonEquals(const AMessage, AExpected, AActual: string);
  published
    procedure TestEncodeRequestDecodesAsServerRequest;
    procedure TestEncodeNotificationDecodesAsNotification;
    procedure TestEncodeResultDecodesAsResponse;
    procedure TestEncodeErrorDecodesAsErrorResponse;
    procedure TestEncodeOmitsEmptyParams;
    procedure TestDecodeResponseResult;
    procedure TestDecodeErrorResponse;
    procedure TestDecodeServerRequest;
    procedure TestDecodeMalformedArray;
    procedure TestDecodeMalformedScalar;
    procedure TestDecodeMalformedMissingVersion;
    procedure TestDecodeMalformedNonIntegerId;
    procedure TestDecodeMalformedNeitherResultNorError;
    procedure TestDecodeMalformedMethodWithResult;
    procedure TestIdGenIsMonotonicAndUnique;
    procedure TestEncodeRejectsBadParamsJson;
    procedure TestEncodeNeverContainsNewline;
  end;

implementation

procedure TJsonRpcTest.AssertJsonEquals(const AMessage, AExpected,
  AActual: string);
var
  E, A: TJSONData;
begin
  E := GetJSON(AExpected);
  try
    A := GetJSON(AActual);
    try
      AssertEquals(AMessage, E.AsJSON, A.AsJSON);
    finally
      A.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TJsonRpcTest.TestEncodeRequestDecodesAsServerRequest;
var
  Line: string;
  Incoming: TJsonRpcIncoming;
begin
  Line := TJsonRpcCodec.EncodeRequest(7, 'tools/list', '{"cursor":"x"}');
  Incoming := TJsonRpcCodec.Decode(Line);
  AssertEquals('kind', Ord(ikServerRequest), Ord(Incoming.Kind));
  AssertTrue('has id', Incoming.HasId);
  AssertEquals('id', Int64(7), Incoming.Id);
  AssertEquals('method', 'tools/list', Incoming.Method);
  AssertJsonEquals('params', '{"cursor":"x"}', Incoming.ParamsJson);
end;

procedure TJsonRpcTest.TestEncodeNotificationDecodesAsNotification;
var
  Line: string;
  Incoming: TJsonRpcIncoming;
begin
  Line := TJsonRpcCodec.EncodeNotification('notifications/initialized', '');
  Incoming := TJsonRpcCodec.Decode(Line);
  AssertEquals('kind', Ord(ikNotification), Ord(Incoming.Kind));
  AssertFalse('no id', Incoming.HasId);
  AssertEquals('method', 'notifications/initialized', Incoming.Method);
  AssertEquals('no params', '', Incoming.ParamsJson);
end;

procedure TJsonRpcTest.TestEncodeResultDecodesAsResponse;
var
  Line: string;
  Incoming: TJsonRpcIncoming;
begin
  Line := TJsonRpcCodec.EncodeResult(3, '{"tools":[]}');
  Incoming := TJsonRpcCodec.Decode(Line);
  AssertEquals('kind', Ord(ikResponse), Ord(Incoming.Kind));
  AssertFalse('not error', Incoming.IsError);
  AssertEquals('id', Int64(3), Incoming.Id);
  AssertJsonEquals('result', '{"tools":[]}', Incoming.ResultJson);
end;

procedure TJsonRpcTest.TestEncodeErrorDecodesAsErrorResponse;
var
  Line: string;
  Incoming: TJsonRpcIncoming;
begin
  Line := TJsonRpcCodec.EncodeError(9, JsonRpcMethodNotFound, 'no such method',
    '{"detail":1}');
  Incoming := TJsonRpcCodec.Decode(Line);
  AssertEquals('kind', Ord(ikResponse), Ord(Incoming.Kind));
  AssertTrue('is error', Incoming.IsError);
  AssertEquals('id', Int64(9), Incoming.Id);
  AssertEquals('code', JsonRpcMethodNotFound, Incoming.Error.Code);
  AssertEquals('message', 'no such method', Incoming.Error.Message);
  AssertJsonEquals('data', '{"detail":1}', Incoming.Error.DataJson);
end;

procedure TJsonRpcTest.TestEncodeOmitsEmptyParams;
var
  Line: string;
begin
  Line := TJsonRpcCodec.EncodeRequest(1, 'initialize', '');
  AssertTrue('no params member', Pos('"params"', Line) = 0);
end;

procedure TJsonRpcTest.TestDecodeResponseResult;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode(
    '{"jsonrpc":"2.0","id":1,"result":{"a":1}}');
  AssertEquals('kind', Ord(ikResponse), Ord(Incoming.Kind));
  AssertFalse('not error', Incoming.IsError);
  AssertJsonEquals('result', '{"a":1}', Incoming.ResultJson);
end;

procedure TJsonRpcTest.TestDecodeErrorResponse;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode(
    '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"nope"}}');
  AssertEquals('kind', Ord(ikResponse), Ord(Incoming.Kind));
  AssertTrue('is error', Incoming.IsError);
  AssertEquals('code', -32601, Incoming.Error.Code);
  AssertEquals('message', 'nope', Incoming.Error.Message);
end;

procedure TJsonRpcTest.TestDecodeServerRequest;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode(
    '{"jsonrpc":"2.0","id":7,"method":"sampling/createMessage","params":{}}');
  AssertEquals('kind', Ord(ikServerRequest), Ord(Incoming.Kind));
  AssertTrue('has id', Incoming.HasId);
  AssertEquals('id', Int64(7), Incoming.Id);
  AssertEquals('method', 'sampling/createMessage', Incoming.Method);
end;

procedure TJsonRpcTest.TestDecodeMalformedArray;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode('[1,2,3]');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
  AssertTrue('has reason', Incoming.MalformedReason <> '');
end;

procedure TJsonRpcTest.TestDecodeMalformedScalar;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode('42');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
end;

procedure TJsonRpcTest.TestDecodeMalformedMissingVersion;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode('{"id":1,"result":{}}');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
end;

procedure TJsonRpcTest.TestDecodeMalformedNonIntegerId;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode('{"jsonrpc":"2.0","id":"x","result":{}}');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
end;

procedure TJsonRpcTest.TestDecodeMalformedNeitherResultNorError;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode('{"jsonrpc":"2.0","id":1}');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
end;

procedure TJsonRpcTest.TestDecodeMalformedMethodWithResult;
var
  Incoming: TJsonRpcIncoming;
begin
  Incoming := TJsonRpcCodec.Decode(
    '{"jsonrpc":"2.0","id":1,"method":"x","result":{}}');
  AssertEquals('kind', Ord(ikMalformed), Ord(Incoming.Kind));
end;

procedure TJsonRpcTest.TestIdGenIsMonotonicAndUnique;
var
  Gen: TJsonRpcIdGen;
  A, B, C: TJsonRpcId;
begin
  Gen := TJsonRpcIdGen.Create;
  try
    A := Gen.Next;
    B := Gen.Next;
    C := Gen.Next;
    AssertTrue('increasing', (B = A + 1) and (C = B + 1));
    AssertTrue('distinct', (A <> B) and (B <> C));
  finally
    Gen.Free;
  end;
end;

procedure TJsonRpcTest.TestEncodeRejectsBadParamsJson;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    TJsonRpcCodec.EncodeRequest(1, 'x', '{not json');
  except
    on E: EJsonRpcEncode do
      Raised := True;
  end;
  AssertTrue('raised EJsonRpcEncode', Raised);
end;

procedure TJsonRpcTest.TestEncodeNeverContainsNewline;
var
  Line: string;
begin
  Line := TJsonRpcCodec.EncodeRequest(1, 'x', '{"a":"b\nc"}');
  AssertTrue('no LF', Pos(#10, Line) = 0);
  AssertTrue('no CR', Pos(#13, Line) = 0);
end;

initialization
  RegisterTest(TJsonRpcTest);
end.
