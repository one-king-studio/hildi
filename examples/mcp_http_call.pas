program mcp_http_call;
{ Call one tool on a remote MCP server over HTTP, end to end, through the real
  client. Run by hand:

    ./build/bin/mcp-http-call <url> <tool-name> <arguments-json>

  Prints the mapped result text. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}
  SysUtils,
  hildegard.helper.agent, hildegard.helper.llm, hildegard.helper.approval,
  hildegard.helper.mcp.client, hildegard.helper.mcp.config;

type
  TAllowAll = class(TInterfacedObject, IApprovalService)
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

function TAllowAll.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  AResult := Default(TApprovalBatchResult);
  AResult.Allowed := True;
  Result := True;
end;

var
  Cfg: TMcpClientConfig;
  Client: TMcpClient;
  Approval: IApprovalService;
  Err, Res: string;
  Tools: TMcpToolArray;
  I: Integer;
  Target: string;
begin
  if ParamCount < 3 then
  begin
    WriteLn('usage: mcp-http-call <url> <tool-name> <arguments-json>');
    Halt(2);
  end;
  Cfg := Default(TMcpClientConfig);
  Cfg.Server.Name := 'remote';
  Cfg.Server.Transport := mtHttp;
  Cfg.Server.Url := ParamStr(1);
  Cfg.Server.Enabled := True;
  Cfg.ListTimeoutMs := 30000;
  Cfg.CallTimeoutMs := 60000;

  Approval := TAllowAll.Create;
  Client := TMcpClient.Create(Cfg, Approval, nil);
  try
    if not Client.Open(Err) then
    begin
      WriteLn('OPEN FAILED: ', Err);
      Halt(1);
    end;
    Tools := Client.Tools;
    WriteLn('tools: ', Length(Tools));
    for I := 0 to High(Tools) do
      WriteLn('  ', Tools[I].Name);

    { Find the tool whose server-name matches the requested suffix. }
    Target := ParamStr(2);
    for I := 0 to High(Tools) do
      if (Tools[I].Name = Target) or (Tools[I].ToolName = Target) then
      begin
        WriteLn('calling ', Tools[I].Name, ' ...');
        if Client.CallTool(Tools[I], ParamStr(3), Res, Err) then
          WriteLn('RESULT: ', Res)
        else
          WriteLn('CALL FAILED: ', Err);
        Halt(0);
      end;
    WriteLn('tool not found: ', Target);
    Halt(1);
  finally
    Client.Free;
  end;
end.
