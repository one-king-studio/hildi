unit llm_fakes;
{ Shared test doubles for the LLM client and the agent loop: a transport that
  replays canned SSE chunks and builders for OpenAI-compatible frames. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, hildegard.helper.llm;

type
  { Replays a fixed list of raw chunks to the client. Records the last request
    so tests can assert serialization at the boundary. }
  TFakeTransport = class(TLLMTransport)
  private
    FChunks: TStringList;
  public
    StatusCode: Integer;
    FailNetwork: Boolean;
    LastURL: string;
    LastBody: string;
    LastHeaders: TStringList;
    AfterChunk: TNotifyEvent;
    constructor Create;
    destructor Destroy; override;
    procedure AddChunk(const AData: RawByteString);
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string): Boolean; override;
  end;

const
  SSEBlank = #10#10;

{ data: <json> followed by a blank line (a complete SSE event). }
function SSE(const AJson: string): RawByteString;
function DataOnly(const AJson: string): RawByteString;   // no trailing blank

function TextDelta(const AText: string): RawByteString;
function FinishFrame(const AReason: string): RawByteString;
function ToolNameFrame(AIndex: Integer; const AId, AName: string): RawByteString;
function ToolArgsFrame(AIndex: Integer; const AArgs: string): RawByteString;
function DoneFrame: RawByteString;
function ProviderErrorFrame(const AMessage: string): RawByteString;

implementation

{ TFakeTransport }

constructor TFakeTransport.Create;
begin
  inherited Create;
  FChunks := TStringList.Create;
  LastHeaders := TStringList.Create;
  StatusCode := 200;
  FailNetwork := False;
end;

destructor TFakeTransport.Destroy;
begin
  LastHeaders.Free;
  FChunks.Free;
  inherited Destroy;
end;

procedure TFakeTransport.AddChunk(const AData: RawByteString);
begin
  FChunks.Add(AData);
end;

function TFakeTransport.PostStream(const AURL: string; const ABody: string;
  const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
  out AStatusCode: Integer; out AError: string): Boolean;
var
  I: Integer;
begin
  LastURL := AURL;
  LastBody := ABody;
  LastHeaders.Assign(AHeaders);
  AError := '';
  if FailNetwork then
  begin
    AStatusCode := 0;
    AError := 'simulated network failure';
    Exit(False);
  end;
  for I := 0 to FChunks.Count - 1 do
  begin
    if Assigned(AOnChunk) then
      AOnChunk(FChunks[I]);
    if Assigned(AfterChunk) then
      AfterChunk(Self);
  end;
  AStatusCode := StatusCode;
  if (StatusCode < 200) or (StatusCode >= 300) then
    AError := '{"error":{"message":"simulated","type":"x"}}';
  Result := True;
end;

{ frame builders }

function SSE(const AJson: string): RawByteString;
begin
  Result := 'data: ' + AJson + SSEBlank;
end;

function DataOnly(const AJson: string): RawByteString;
begin
  Result := 'data: ' + AJson;
end;

function TextDelta(const AText: string): RawByteString;
var
  Root, Choice, Delta: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Delta := TJSONObject.Create;
  Delta.Add('content', AText);
  Choice.Add('delta', Delta);
  Choices.Add(Choice);
  Root.Add('choices', Choices);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function FinishFrame(const AReason: string): RawByteString;
var
  Root, Choice: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Choice.Add('finish_reason', AReason);
  Choices.Add(Choice);
  Root.Add('choices', Choices);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function ToolNameFrame(AIndex: Integer; const AId, AName: string): RawByteString;
var
  Root, Choice, Delta, Item, Fn: TJSONObject;
  Choices, Tcs: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Delta := TJSONObject.Create;
  Tcs := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('index', AIndex);
  Item.Add('id', AId);
  Fn := TJSONObject.Create;
  Fn.Add('name', AName);
  Item.Add('function', Fn);
  Tcs.Add(Item);
  Delta.Add('tool_calls', Tcs);
  Choice.Add('delta', Delta);
  Choices.Add(Choice);
  Root.Add('choices', Choices);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function ToolArgsFrame(AIndex: Integer; const AArgs: string): RawByteString;
var
  Root, Choice, Delta, Item, Fn: TJSONObject;
  Choices, Tcs: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Delta := TJSONObject.Create;
  Tcs := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('index', AIndex);
  Fn := TJSONObject.Create;
  Fn.Add('arguments', AArgs);
  Item.Add('function', Fn);
  Tcs.Add(Item);
  Delta.Add('tool_calls', Tcs);
  Choice.Add('delta', Delta);
  Choices.Add(Choice);
  Root.Add('choices', Choices);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function DoneFrame: RawByteString;
begin
  Result := SSE('[DONE]');
end;

function ProviderErrorFrame(const AMessage: string): RawByteString;
var
  Root, Err: TJSONObject;
begin
  Root := TJSONObject.Create;
  Err := TJSONObject.Create;
  Err.Add('message', AMessage);
  Root.Add('error', Err);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

end.
