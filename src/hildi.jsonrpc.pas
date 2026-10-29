unit hildi.jsonrpc;
{ JSON-RPC 2.0 codec: envelope encoding/decoding, message classification, and
  request-id allocation. Pure: no I/O, no globals (the id generator is a
  caller-owned object). This is the transport-agnostic protocol core; framing
  and transport live elsewhere (see the stdio child manager and, later, HTTP).
  See docs/features/MCP_Client/JsonRpc_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TJsonRpcId = Int64;

  { A decoded JSON-RPC error member. DataJson is the raw `data` member, or ''
    when absent; the codec does not interpret it. }
  TJsonRpcError = record
    Code: Integer;
    Message: string;
    DataJson: string;
  end;

  { The four shapes one incoming line can have. Exactly one applies. }
  TJsonRpcIncomingKind =
    (ikResponse, ikNotification, ikServerRequest, ikMalformed);

  TJsonRpcIncoming = record
    Kind: TJsonRpcIncomingKind;
    { ikResponse / ikServerRequest }
    Id: TJsonRpcId;
    HasId: Boolean;
    { ikNotification / ikServerRequest }
    Method: string;
    ParamsJson: string;      // raw `params`; '' when absent
    { ikResponse }
    ResultJson: string;      // raw `result`; '' when the response is an error
    Error: TJsonRpcError;
    IsError: Boolean;        // ikResponse: True when `error` is present
    { diagnostics }
    Raw: string;             // the original line, verbatim
    MalformedReason: string; // ikMalformed only
  end;

  { Raised only when a caller hands the encoder non-JSON params/result (a
    programming error on our side). Server input never raises: Decode classifies
    it as ikMalformed. }
  EJsonRpcEncode = class(Exception);

  { Pure codec. Every Encode* returns a complete, LF-free line; the caller owns
    framing. }
  TJsonRpcCodec = class
  public
    class function EncodeRequest(AId: TJsonRpcId; const AMethod: string;
      const AParamsJson: string): string;
    class function EncodeNotification(const AMethod: string;
      const AParamsJson: string): string;
    class function EncodeResult(AId: TJsonRpcId;
      const AResultJson: string): string;
    class function EncodeError(AId: TJsonRpcId; ACode: Integer;
      const AMessage: string; const ADataJson: string = ''): string;
    class function Decode(const ALine: string): TJsonRpcIncoming;
  end;

  { Monotonic request-id allocator. Ids are unique for the life of a client. }
  TJsonRpcIdGen = class
  private
    FNext: TJsonRpcId;
  public
    constructor Create(AStart: TJsonRpcId = 1);
    function Next: TJsonRpcId;
  end;

const
  { Standard JSON-RPC 2.0 error codes; MCP uses these for its own refusals. }
  JsonRpcParseError     = -32700;
  JsonRpcInvalidRequest = -32600;
  JsonRpcMethodNotFound = -32601;
  JsonRpcInvalidParams  = -32602;
  JsonRpcInternalError  = -32603;

  { The version string carried in every envelope. }
  JsonRpcVersion = '2.0';

implementation

uses
  fpjson, jsonparser;

{ Parses AParamsJson into a TJSONData, or raises EJsonRpcEncode. }
function ParseJsonOrRaise(const AJson: string): TJSONData;
begin
  try
    Result := GetJSON(AJson);
  except
    on E: Exception do
      raise EJsonRpcEncode.Create('invalid JSON: ' + E.Message);
  end;
end;

{ --- TJsonRpcCodec ------------------------------------------------------ }

class function TJsonRpcCodec.EncodeRequest(AId: TJsonRpcId;
  const AMethod: string; const AParamsJson: string): string;
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', JsonRpcVersion);
    Root.Add('id', Int64(AId));
    Root.Add('method', AMethod);
    if AParamsJson <> '' then
      Root.Add('params', ParseJsonOrRaise(AParamsJson));
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

class function TJsonRpcCodec.EncodeNotification(const AMethod: string;
  const AParamsJson: string): string;
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', JsonRpcVersion);
    Root.Add('method', AMethod);
    if AParamsJson <> '' then
      Root.Add('params', ParseJsonOrRaise(AParamsJson));
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

class function TJsonRpcCodec.EncodeResult(AId: TJsonRpcId;
  const AResultJson: string): string;
var
  Root: TJSONObject;
begin
  if AResultJson = '' then
    raise EJsonRpcEncode.Create('result payload is required');
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', JsonRpcVersion);
    Root.Add('id', Int64(AId));
    Root.Add('result', ParseJsonOrRaise(AResultJson));
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

class function TJsonRpcCodec.EncodeError(AId: TJsonRpcId; ACode: Integer;
  const AMessage: string; const ADataJson: string): string;
var
  Root, ErrObj: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', JsonRpcVersion);
    Root.Add('id', Int64(AId));
    ErrObj := TJSONObject.Create;
    ErrObj.Add('code', ACode);
    ErrObj.Add('message', AMessage);
    if ADataJson <> '' then
      ErrObj.Add('data', ParseJsonOrRaise(ADataJson));
    Root.Add('error', ErrObj);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

{ Builds the malformed result. }
function Malformed(const ARaw, AReason: string): TJsonRpcIncoming;
begin
  Result := Default(TJsonRpcIncoming);
  Result.Kind := ikMalformed;
  Result.Raw := ARaw;
  Result.MalformedReason := AReason;
end;

class function TJsonRpcCodec.Decode(const ALine: string): TJsonRpcIncoming;
var
  Data: TJSONData;
  Root: TJSONObject;
  MethodVal, IdVal, ErrVal, DataVal: TJSONData;
  ErrObj: TJSONObject;
  HasMethod, HasId, HasResult, HasError: Boolean;
begin
  Result := Default(TJsonRpcIncoming);
  Result.Raw := ALine;

  Data := nil;
  try
    try
      Data := GetJSON(ALine);
    except
      on E: Exception do
        Exit(Malformed(ALine, 'not valid JSON'));
    end;

    if not (Data is TJSONObject) then
      Exit(Malformed(ALine, 'not a JSON object'));
    Root := TJSONObject(Data);

    DataVal := Root.Find('jsonrpc');
    if (DataVal = nil) or (DataVal.JSONType <> jtString) or
      (DataVal.AsString <> JsonRpcVersion) then
      Exit(Malformed(ALine, 'missing or wrong jsonrpc version'));

    MethodVal := Root.Find('method');
    HasMethod := (MethodVal <> nil) and (MethodVal.JSONType = jtString);
    if (MethodVal <> nil) and not HasMethod then
      Exit(Malformed(ALine, 'method must be a string'));

    IdVal := Root.Find('id');
    HasId := IdVal <> nil;
    if HasId and (IdVal.JSONType <> jtNumber) then
      Exit(Malformed(ALine, 'id must be an integer'));

    HasResult := Root.Find('result') <> nil;
    ErrVal := Root.Find('error');
    HasError := ErrVal <> nil;

    if HasMethod then
    begin
      if HasResult or HasError then
        Exit(Malformed(ALine, 'method with result or error'));
      Result.Method := MethodVal.AsString;
      DataVal := Root.Find('params');
      if DataVal <> nil then
        Result.ParamsJson := DataVal.AsJSON;
      if HasId then
      begin
        Result.Kind := ikServerRequest;
        Result.Id := IdVal.AsInt64;
        Result.HasId := True;
      end
      else
        Result.Kind := ikNotification;
      Exit(Result);
    end;

    { Response shape: no method, so it must carry an id and exactly one of
      result/error. }
    if not HasId then
      Exit(Malformed(ALine, 'response without id'));
    if HasResult and HasError then
      Exit(Malformed(ALine, 'both result and error'));
    if not (HasResult or HasError) then
      Exit(Malformed(ALine, 'neither result nor error'));

    Result.Kind := ikResponse;
    Result.Id := IdVal.AsInt64;
    Result.HasId := True;

    if HasResult then
    begin
      Result.ResultJson := Root.Find('result').AsJSON;
      Exit(Result);
    end;

    if not (ErrVal is TJSONObject) then
      Exit(Malformed(ALine, 'error must be an object'));
    ErrObj := TJSONObject(ErrVal);
    DataVal := ErrObj.Find('code');
    if (DataVal = nil) or (DataVal.JSONType <> jtNumber) then
      Exit(Malformed(ALine, 'error without an integer code'));
    Result.Error.Code := DataVal.AsInt64;
    DataVal := ErrObj.Find('message');
    if (DataVal <> nil) and (DataVal.JSONType = jtString) then
      Result.Error.Message := DataVal.AsString;
    DataVal := ErrObj.Find('data');
    if DataVal <> nil then
      Result.Error.DataJson := DataVal.AsJSON;
    Result.IsError := True;
    Result.ResultJson := '';
  finally
    Data.Free;
  end;
end;

{ --- TJsonRpcIdGen ------------------------------------------------------ }

constructor TJsonRpcIdGen.Create(AStart: TJsonRpcId);
begin
  inherited Create;
  FNext := AStart;
end;

function TJsonRpcIdGen.Next: TJsonRpcId;
begin
  Result := FNext;
  Inc(FNext);
end;

end.
