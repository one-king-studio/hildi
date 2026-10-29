unit SmokeProvider;
{ A loopback OpenAI-compatible SSE provider for the live smoke.

  Why not fphttpserver: TFPHTTPConnectionResponse buffers Content and writes it
  at the end of the request, so a scenario could not observe INCREMENTAL deltas —
  the streaming path would look exactly like the buffered path the unit tests
  already cover, which is the one thing this smoke exists to distinguish. So
  this is a small raw-socket server that flushes each frame as it goes.

  ponytail: a hand-rolled HTTP/1.1 request reader. Ceiling: one request per
  connection, Content-Length requests only, no chunked input, no keep-alive.
  Upgrade path: fphttpserver, the day it can flush. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  {$ifdef unix}BaseUnix, Sockets,{$endif}
  fpjson;

type
  { One request's script: the SSE frames to replay, in order. }
  TFakeScript = record
    Frames: array of RawByteString;
    StatusCode: Integer;      // 0 => 200
    FrameDelayMs: Integer;    // 0 => DefaultFrameDelayMs
    { The body to send when StatusCode is not 2xx. }
    ErrorBody: string;
  end;

  TFakeProviderThread = class;

  TFakeProvider = class
  private
    FListenFd: Integer;
    FPort: Word;
    FScripts: array of TFakeScript;
    FScriptIndex: Integer;
    FBodies: TStringList;
    FLock: TCriticalSection;
    FThread: TFakeProviderThread;
    FLastError: string;
    function NextScript: TFakeScript;
    procedure RecordBody(const ABody: string);
  public
    constructor Create;
    destructor Destroy; override;
    { Bind 127.0.0.1:0 and start accepting. Idempotent: a second call on a
      started provider returns True and changes nothing. }
    function Start(out AError: string): Boolean;
    { Queue the next request's script. The last one repeats for later requests,
      so a tool round trip needs two. }
    procedure Script(const AScript: TFakeScript);
    function Port: Word;
    function EndpointUrl: string;
    function RequestCount: Integer;
    function RequestBodyAt(AIndex: Integer): string;
    function LastError: string;
    { Close the listener and join the worker. Safe to call twice. }
    procedure Stop;
  end;

  TFakeProviderThread = class(TThread)
  private
    FOwner: TFakeProvider;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TFakeProvider);
  end;

const
  DefaultFrameDelayMs = 15;
  { A client that stops sending mid-request is dropped rather than blocking the
    accept loop forever. }
  ClientReadTimeoutMs = 5000;

{ Frame builders. These mirror tests/LLMFakes.pas exactly, so a change to the
  SSE shape breaks the smoke and the unit tests together rather than silently
  drifting. }
function SSE(const AJson: string): RawByteString;
function TextDelta(const AText: string): RawByteString;
function ReasoningDelta(const AText: string): RawByteString;
function FinishFrame(const AReason: string): RawByteString;
function ToolNameFrame(AIndex: Integer; const AId, AName: string): RawByteString;
function ToolArgsFrame(AIndex: Integer; const AArgs: string): RawByteString;
function DoneFrame: RawByteString;

{ Build a script from frames. }
function MakeScript(const AFrames: array of RawByteString;
  ADelayMs: Integer = 0): TFakeScript;

implementation

const
  SSEBlank = #10#10;

{ --- frame builders ----------------------------------------------------- }

function SSE(const AJson: string): RawByteString;
begin
  Result := 'data: ' + AJson + SSEBlank;
end;

function ChoiceDelta(const AJsonDelta: string): RawByteString;
var
  Root, Choice, Delta: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Choices := TJSONArray.Create;
    Choice := TJSONObject.Create;
    Delta := TJSONObject.Create;
    Delta.Add('content', AJsonDelta);
    Choice.Add('delta', Delta);
    Choices.Add(Choice);
    Root.Add('choices', Choices);
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function TextDelta(const AText: string): RawByteString;
begin
  Result := ChoiceDelta(AText);
end;

function ReasoningDelta(const AText: string): RawByteString;
var
  Root, Choice, Delta: TJSONObject;
  Choices: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Choices := TJSONArray.Create;
    Choice := TJSONObject.Create;
    Delta := TJSONObject.Create;
    Delta.Add('reasoning_content', AText);
    Choice.Add('delta', Delta);
    Choices.Add(Choice);
    Root.Add('choices', Choices);
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
  try
    Choices := TJSONArray.Create;
    Choice := TJSONObject.Create;
    Choice.Add('finish_reason', AReason);
    Choices.Add(Choice);
    Root.Add('choices', Choices);
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function ToolDelta(const AIndex: Integer; const AId, AName, AArgs: string;
  AHasName: Boolean): RawByteString;
var
  Root, Choice, Delta, Item, Fn: TJSONObject;
  Choices, Tcs: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Choices := TJSONArray.Create;
    Choice := TJSONObject.Create;
    Delta := TJSONObject.Create;
    Tcs := TJSONArray.Create;
    Item := TJSONObject.Create;
    Item.Add('index', AIndex);
    if AHasName then
    begin
      Item.Add('id', AId);
      Fn := TJSONObject.Create;
      Fn.Add('name', AName);
      Item.Add('function', Fn);
    end
    else
    begin
      Fn := TJSONObject.Create;
      Fn.Add('arguments', AArgs);
      Item.Add('function', Fn);
    end;
    Tcs.Add(Item);
    Delta.Add('tool_calls', Tcs);
    Choice.Add('delta', Delta);
    Choices.Add(Choice);
    Root.Add('choices', Choices);
    Result := SSE(Root.AsJSON);
  finally
    Root.Free;
  end;
end;

function ToolNameFrame(AIndex: Integer; const AId, AName: string): RawByteString;
begin
  Result := ToolDelta(AIndex, AId, AName, '', True);
end;

function ToolArgsFrame(AIndex: Integer; const AArgs: string): RawByteString;
begin
  Result := ToolDelta(AIndex, '', '', AArgs, False);
end;

function DoneFrame: RawByteString;
begin
  Result := SSE('[DONE]');
end;

function MakeScript(const AFrames: array of RawByteString;
  ADelayMs: Integer): TFakeScript;
var
  I: Integer;
begin
  Result := Default(TFakeScript);
  SetLength(Result.Frames, Length(AFrames));
  for I := 0 to High(AFrames) do
    Result.Frames[I] := AFrames[I];
  Result.FrameDelayMs := ADelayMs;
end;

{ --- TFakeProvider ------------------------------------------------------ }

constructor TFakeProvider.Create;
begin
  inherited Create;
  FListenFd := -1;
  FPort := 0;
  FScriptIndex := 0;
  FBodies := TStringList.Create;
  FLock := TCriticalSection.Create;
end;

destructor TFakeProvider.Destroy;
begin
  Stop;
  FBodies.Free;
  FLock.Free;
  inherited Destroy;
end;

function TFakeProvider.Start(out AError: string): Boolean;
var
  Addr: TInetSockAddr;
  Opt: LongInt;
  Len: TSockLen;
begin
  AError := '';
  if FListenFd >= 0 then
    Exit(True);                    // already listening
  FListenFd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenFd < 0 then
  begin
    AError := 'could not create the provider socket';
    Exit(False);
  end;
  Opt := 1;
  fpSetSockOpt(FListenFd, SOL_SOCKET, SO_REUSEADDR, @Opt, SizeOf(Opt));
  FillChar(Addr, SizeOf(Addr), 0);
  {$ifdef darwin}
  Addr.sin_len := SizeOf(Addr);
  {$endif}
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;                       // ephemeral
  Addr.sin_addr.s_addr := htonl($7F000001); // 127.0.0.1
  if fpBind(FListenFd, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
  begin
    AError := 'could not bind the provider socket';
    CloseSocket(FListenFd);
    FListenFd := -1;
    Exit(False);
  end;
  if fpListen(FListenFd, 8) <> 0 then
  begin
    AError := 'could not listen on the provider socket';
    CloseSocket(FListenFd);
    FListenFd := -1;
    Exit(False);
  end;
  Len := SizeOf(Addr);
  if fpGetsockname(FListenFd, PSockAddr(@Addr), @Len) <> 0 then
  begin
    AError := 'could not read the provider port';
    CloseSocket(FListenFd);
    FListenFd := -1;
    Exit(False);
  end;
  FPort := ntohs(Addr.sin_port);
  FThread := TFakeProviderThread.Create(Self);
  FThread.Start;
  Result := True;
end;

procedure TFakeProvider.Stop;
begin
  if FThread <> nil then
  begin
    FThread.Terminate;
    { The worker polls a short select, so this joins promptly without needing the
      accept to be interrupted by a close (which is not portable). }
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  if FListenFd >= 0 then
  begin
    CloseSocket(FListenFd);
    FListenFd := -1;
  end;
end;

procedure TFakeProvider.Script(const AScript: TFakeScript);
begin
  FLock.Enter;
  try
    SetLength(FScripts, Length(FScripts) + 1);
    FScripts[High(FScripts)] := AScript;
  finally
    FLock.Leave;
  end;
end;

function TFakeProvider.NextScript: TFakeScript;
begin
  FLock.Enter;
  try
    if Length(FScripts) = 0 then
      Result := MakeScript([])
    else
    begin
      if FScriptIndex > High(FScripts) then
        FScriptIndex := High(FScripts);   // the last one repeats
      Result := FScripts[FScriptIndex];
      Inc(FScriptIndex);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TFakeProvider.RecordBody(const ABody: string);
begin
  FLock.Enter;
  try
    FBodies.Add(ABody);
  finally
    FLock.Leave;
  end;
end;

function TFakeProvider.Port: Word;
begin
  Result := FPort;
end;

function TFakeProvider.EndpointUrl: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FPort) + '/v1/chat/completions';
end;

function TFakeProvider.RequestCount: Integer;
begin
  FLock.Enter;
  try
    Result := FBodies.Count;
  finally
    FLock.Leave;
  end;
end;

function TFakeProvider.RequestBodyAt(AIndex: Integer): string;
begin
  FLock.Enter;
  try
    if (AIndex >= 0) and (AIndex < FBodies.Count) then
      Result := FBodies[AIndex]
    else
      Result := '';
  finally
    FLock.Leave;
  end;
end;

function TFakeProvider.LastError: string;
begin
  FLock.Enter;
  try
    Result := FLastError;
  finally
    FLock.Leave;
  end;
end;

{ --- the worker --------------------------------------------------------- }

constructor TFakeProviderThread.Create(AOwner: TFakeProvider);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TFakeProviderThread.Execute;

  { Read until the header terminator; returns the raw request head. }
  function ReadHead(Sock: Integer; out AHead: string): Boolean;
  var
    Buf: array[0..1023] of Byte;
    N: Integer;
  begin
    AHead := '';
    while Pos(#13#10#13#10, AHead) = 0 do
    begin
      N := fpRecv(Sock, @Buf[0], SizeOf(Buf), 0);
      if N <= 0 then
        Exit(False);
      SetLength(AHead, Length(AHead) + N);
      Move(Buf[0], AHead[Length(AHead) - N + 1], N);
      if Length(AHead) > 65536 then
        Exit(False);                       // a sane ceiling on a header block
    end;
    Result := True;
  end;

  function HeaderValue(const AHead, AName: string): string;
  var
    Lines: TStringList;
    I: Integer;
    Prefix: string;
  begin
    Result := '';
    Prefix := LowerCase(AName) + ':';
    Lines := TStringList.Create;
    try
      Lines.Text := StringReplace(AHead, #13#10, #10, [rfReplaceAll]);
      for I := 0 to Lines.Count - 1 do
        if LowerCase(Copy(Trim(Lines[I]), 1, Length(Prefix))) = Prefix then
          Exit(Trim(Copy(Trim(Lines[I]), Length(Prefix) + 1, MaxInt)));
    finally
      Lines.Free;
    end;
  end;

  function ReadBody(Sock: Integer; const AHead: string): string;
  var
    Want, Got, N: Integer;
    Buf: array[0..4095] of Byte;
    Head: string;
  begin
    Result := '';
    Want := StrToIntDef(HeaderValue(AHead, 'Content-Length'), 0);
    if Want <= 0 then
      Exit;
    { Anything after the header terminator already belongs to the body. }
    Head := AHead;
    Got := Length(Head) - (Pos(#13#10#13#10, Head) + 3);
    if Got > 0 then
    begin
      Result := Copy(Head, Pos(#13#10#13#10, Head) + 4, Got);
      if Length(Result) > Want then
        SetLength(Result, Want);
    end;
    while Length(Result) < Want do
    begin
      N := fpRecv(Sock, @Buf[0], SizeOf(Buf), 0);
      if N <= 0 then
        Break;
      SetLength(Result, Length(Result) + N);
      Move(Buf[0], Result[Length(Result) - N + 1], N);
    end;
  end;

  procedure SendAll(Sock: Integer; const AData: RawByteString);
  var
    Sent, N: Integer;
  begin
    Sent := 0;
    while Sent < Length(AData) do
    begin
      N := fpSend(Sock, @AData[Sent + 1], Length(AData) - Sent, 0);
      if N <= 0 then
        Exit;
      Inc(Sent, N);
    end;
  end;

  procedure ServeOne(Sock: Integer);
  var
    Head, Body: string;
    S: TFakeScript;
    I: Integer;
    Resp: RawByteString;
    Tv: TTimeVal;
  begin
    { A client that dies mid-request must not block the loop. }
    Tv.tv_sec := ClientReadTimeoutMs div 1000;
    Tv.tv_usec := 0;
    fpSetSockOpt(Sock, SOL_SOCKET, SO_RCVTIMEO, @Tv, SizeOf(Tv));

    if not ReadHead(Sock, Head) then
      Exit;
    { The head we read may already contain body bytes; ReadBody takes the full
      buffer so it can account for them. }
    Body := ReadBody(Sock, Head);
    FOwner.RecordBody(Body);

    S := FOwner.NextScript;
    if (S.StatusCode = 0) or ((S.StatusCode >= 200) and (S.StatusCode < 300)) then
    begin
      { No Content-Length and Connection: close, so the client reads until EOF
        and therefore sees each frame as it arrives. That is the property under
        test; a Content-Length response would be buffered and prove nothing. }
      SendAll(Sock, 'HTTP/1.1 200 OK'#13#10 +
        'Content-Type: text/event-stream'#13#10 +
        'Cache-Control: no-cache'#13#10 +
        'Connection: close'#13#10#13#10);
      for I := 0 to High(S.Frames) do
      begin
        SendAll(Sock, S.Frames[I]);
        if S.FrameDelayMs > 0 then
          Sleep(S.FrameDelayMs)
        else
          Sleep(DefaultFrameDelayMs);
      end;
    end
    else
    begin
      Resp := S.ErrorBody;
      if Resp = '' then
        Resp := '{"error":{"message":"simulated provider error"}}';
      SendAll(Sock, 'HTTP/1.1 ' + IntToStr(S.StatusCode) + ' Error'#13#10 +
        'Content-Type: application/json'#13#10 +
        'Content-Length: ' + IntToStr(Length(Resp)) + #13#10 +
        'Connection: close'#13#10#13#10 + Resp);
    end;
    { Half-close so the client's read-until-EOF terminates promptly. }
    fpShutdown(Sock, 1);
  end;

var
  ReadSet: TFDSet;
  Tv: TTimeVal;
  C: Integer;
begin
  while not Terminated do
  begin
    if FOwner.FListenFd < 0 then
      Break;
    Tv.tv_sec := 0;
    Tv.tv_usec := 100000;                 // 100 ms: a responsive Terminate
    fpFD_ZERO(ReadSet);
    fpFD_SET(FOwner.FListenFd, ReadSet);
    if fpSelect(FOwner.FListenFd + 1, @ReadSet, nil, nil, @Tv) <= 0 then
      Continue;
    C := fpAccept(FOwner.FListenFd, nil, nil);
    if C < 0 then
      Continue;
    try
      ServeOne(C);
    except
      on E: Exception do
      begin
        FOwner.FLock.Enter;
        try
          FOwner.FLastError := E.ClassName + ': ' + E.Message;
        finally
          FOwner.FLock.Leave;
        end;
      end;
    end;
    CloseSocket(C);
  end;
end;

end.
