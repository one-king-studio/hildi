unit llm_fakes;
{ Shared test doubles for the LLM client and the agent loop: a transport that
  replays canned SSE chunks and builders for OpenAI-compatible frames. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections, fpjson, hildegard.helper.llm;

type
  { Replays canned SSE chunks to the client. Either a flat chunk list reused for
    every call, or per-call responses consumed in order (the last one repeats).
    Records the last request so tests can assert serialization. }
  TFakeTransport = class(TLLMTransport)
  private
    FChunks: TStringList;
    FResponses: TObjectList<TStringList>;
  public
    StatusCode: Integer;
    FailNetwork: Boolean;
    Calls: Integer;
    LastURL: string;
    LastBody: string;
    LastHeaders: TStringList;
    AfterChunk: TNotifyEvent;
    constructor Create;
    destructor Destroy; override;
    procedure AddChunk(const AData: RawByteString);
    procedure AddResponse(const AChunks: array of RawByteString);
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
function ReasoningDelta(const AText: string): RawByteString;
function AlsoReasoningDelta(const AText: string): RawByteString;
function FinishFrame(const AReason: string): RawByteString;
function UsageFrame(const AUsageJson: string): RawByteString;
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
  FResponses := TObjectList<TStringList>.Create(True);
  LastHeaders := TStringList.Create;
  StatusCode := 200;
  FailNetwork := False;
  Calls := 0;
end;

destructor TFakeTransport.Destroy;
begin
  LastHeaders.Free;
  FResponses.Free;
  FChunks.Free;
  inherited Destroy;
end;

procedure TFakeTransport.AddChunk(const AData: RawByteString);
begin
  FChunks.Add(AData);
end;

procedure TFakeTransport.AddResponse(const AChunks: array of RawByteString);
var
  Response: TStringList;
  I: Integer;
begin
  Response := TStringList.Create;
  for I := Low(AChunks) to High(AChunks) do
    Response.Add(AChunks[I]);
  FResponses.Add(Response);
end;

function TFakeTransport.PostStream(const AURL: string; const ABody: string;
  const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
  out AStatusCode: Integer; out AError: string): Boolean;
var
  I, Idx: Integer;
  Chunks: TStringList;
begin
  Inc(Calls);
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

  if FResponses.Count > 0 then
  begin
    Idx := Calls - 1;
    if Idx >= FResponses.Count then
      Idx := FResponses.Count - 1;
    Chunks := FResponses[Idx];
  end
  else
    Chunks := FChunks;

  for I := 0 to Chunks.Count - 1 do
  begin
    if Assigned(AOnChunk) then
      AOnChunk(RawByteString(Chunks[I]));
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

function ReasoningDelta(const AText: string): RawByteString;
var
  Root, Choice, Delta: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Delta := TJSONObject.Create;
  Delta.Add('reasoning_content', AText);
  Choice.Add('delta', Delta);
  Choices.Add(Choice);
  Root.Add('choices', Choices);
  try
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function AlsoReasoningDelta(const AText: string): RawByteString;
var
  Root, Choice, Delta: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;
  Choice := TJSONObject.Create;
  Delta := TJSONObject.Create;
  Delta.Add('reasoning', AText);
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

function UsageFrame(const AUsageJson: string): RawByteString;
var
  Root: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  Choices := TJSONArray.Create;      // the usage-only chunk has no choices
  Root.Add('choices', Choices);
  Root.Add('usage', GetJSON(AUsageJson));
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
