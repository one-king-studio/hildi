program mcp_probe;
{ Phase-level diagnostic for ONE MCP server. Answers a question nothing else
  can: WHEN a server hangs, which step is it stuck in?

  HildiMCPClient.Open does spawn, initialize and tools/list behind one call and
  one timeout, so a failure says only "it failed" - not which phase. This drives
  TStdioChild directly, printing the elapsed time of each phase, so a server that
  hangs on tools/list is visibly different from one that never spawned.

  Usage:
    mcp_probe <command> [-- args...]

  Examples:
    mcp_probe npx -- -y @browsermcp/mcp
    mcp_probe docker -- run -i --rm --init mcr.microsoft.com/playwright/mcp

  Not a test: it spawns a real process and may need the network. It lives in
  examples/ for the same reason mcp-smoke does. }

{$mode delphi}{$H+}

uses
  SysUtils, DateUtils, fpjson, jsonparser,
  HildiStdioChild, HildiJSONRPC;

const
  { Per-phase budget. Shorter than the product's 5s so the probe answers FAST;
    anything near this is already a broken server. }
  PhaseMs = 7000;

var
  Cmd: string;
  Args: TStringArray;
  Child: TStdioChild;
  Cfg: TStdioChildConfig;
  Err, Line: string;
  Reason: TStdioReadResult;
  T0: Int64;
  InitId: TJsonRpcId;

{ Elapsed milliseconds since AStart. GetTickCount64 rather than Now: the
  granularity of TDateTime is coarse enough to report 0 for a phase that really
  took tens of milliseconds, and this probe exists to measure exactly that. }
function Elapsed(const AStart: Int64): Int64;
begin
  Result := Int64(GetTickCount64) - AStart;
end;

procedure Phase(const AName: string; AStart: Int64; AOk: Boolean;
  const ADetail: string);
begin
  if AOk then
    WriteLn(Format('  %-14s %6d ms   ok', [AName, Elapsed(AStart)]))
  else
    WriteLn(Format('  %-14s %6d ms   FAILED: %s',
      [AName, Elapsed(AStart), ADetail]));
end;

{ Send one JSON-RPC request and read until its response arrives. Reports the
  elapsed time either way: a timeout is the interesting case, so it must print
  the duration that was actually spent. }
function RoundTrip(const AMethod, AParams: string; out AResultJson: string;
  out AError: string): Boolean;
var
  Id: TJsonRpcId;
  Incoming: TJsonRpcIncoming;
  E: Integer;
  Data: TJSONData;
begin
  Result := False;
  AResultJson := '';
  AError := '';
  { TJsonRpcId is a plain Int64. }
  Id := 1;
  if not Child.WriteLine(TJsonRpcCodec.EncodeRequest(Id, AMethod, AParams),
    AError) then
  begin
    AError := 'write failed: ' + AError;
    Exit;
  end;
  E := 0;
  repeat
    Inc(E);
    if not Child.ReadLine(Line, PhaseMs, Reason) then
    begin
      case Reason of
        srTimeout: AError := Format('TIMEOUT after %d ms reading a response',
          [PhaseMs]);
        srEof: AError := 'server exited (EOF)';
        srTooLong: AError := 'over-long line';
      else
        AError := 'read error';
      end;
      Exit;
    end;
    { stderr may interleave on some servers; ignore anything that is not JSON. }
    Data := nil;
    try
      try
        Data := GetJSON(Line);
      except
        Continue;
      end;
      if not (Data is TJSONObject) then
        Continue;
      Incoming := TJsonRpcCodec.Decode(Line);
      if Incoming.Kind = ikResponse then
      begin
        if Incoming.IsError then
        begin
          AError := Format('JSON-RPC error %d: %s',
            [Incoming.Error.Code, Incoming.Error.Message]);
          Exit;
        end;
        AResultJson := Incoming.ResultJson;
        Exit(True);
      end;
    finally
      Data.Free;
    end;
  until E > 64;
  AError := 'no response after 64 lines';
end;

var
  I: Integer;
  P: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: mcp_probe <command> [-- args...]');
    Halt(2);
  end;
  Cmd := ParamStr(1);
  Args := nil;
  P := 0;
  for I := 1 to ParamCount do
    if (P = 0) and (ParamStr(I) = '--') then
      P := I
    else if P > 0 then
    begin
      SetLength(Args, Length(Args) + 1);
      Args[High(Args)] := ParamStr(I);
    end;

  WriteLn('MCP phase probe: ', Cmd, ' ', String.Join(' ', Args));
  WriteLn;

  Cfg := Default(TStdioChildConfig);
  Cfg.Executable := Cmd;
  Cfg.Args := Args;
  Cfg.ReadTimeoutMs := PhaseMs;

  Child := TStdioChild.Create(Cfg);
  try
    { PHASE 1: spawn. A failure here is "the command is wrong or not on PATH",
      which is a completely different problem from a server that runs but never
      answers. }
    T0 := Int64(GetTickCount64);
    if not Child.Start(Err) then
    begin
      Phase('spawn', T0, False, Err);
      Halt(1);
    end;
    Phase('spawn', T0, True, '');
    WriteLn(Format('  %-14s %6d   pid', ['', Child.ExitCode]));

    { PHASE 2: initialize. The handshake every MCP server must answer. }
    T0 := Int64(GetTickCount64);
    if not RoundTrip('initialize',
      '{"protocolVersion":"2024-11-05","capabilities":{},' +
      '"clientInfo":{"name":"hildi-probe","version":"0.1"}}', Line, Err) then
    begin
      Phase('initialize', T0, False, Err);
      WriteLn;
      WriteLn('STDERR TAIL:');
      WriteLn(Child.StderrTail);
      Halt(1);
    end;
    Phase('initialize', T0, True, '');

    { Some servers wait for the initialized notification before answering
      anything else. Send it, but do not wait for a reply (it has none). }
    Child.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}', Err);

    { PHASE 3: tools/list. THE ONE THAT HANGS. A server that opens and
      initializes but never lists is usually blocked on a browser download or a
      network fetch it does not report progress for. }
    T0 := Int64(GetTickCount64);
    if not RoundTrip('tools/list', '{}', Line, Err) then
    begin
      Phase('tools/list', T0, False, Err);
      WriteLn;
      WriteLn('STDERR TAIL (the server''s own explanation, if any):');
      WriteLn(Child.StderrTail);
      Halt(1);
    end;
    Phase('tools/list', T0, True, '');

    WriteLn;
    WriteLn('ALL PHASES OK. tools/list responded with ',
      Length(Line), ' bytes.');
    WriteLn(Copy(Line, 1, 400));
  finally
    Child.Close;
    Child.Free;
  end;
end.
