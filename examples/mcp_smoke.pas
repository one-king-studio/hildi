program mcp_smoke;
{ Live calibration smoke: drives hildegard.helper.mcp.client against a REAL MCP
  server (the Playwright container over stdio). Not a test — it needs Docker and
  the network, so it lives outside the hermetic suite. Run it by hand:

    docker run -i --rm --init mcr.microsoft.com/playwright/mcp

  is the server this configures. See docs/features/MCP_Client/. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.mcp.client, hildegard.helper.mcp.config;

type
  { Allows every ask, so the smoke isolates the transport, not the approval UI. }
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
  Approval: IApprovalService;
  Cfg: TMcpClientConfig;
  Client: TMcpClient;
  Reg: TToolRegistry;
  Err, Res: string;
  I: Integer;
  Tools: TMcpToolArray;
  Tool: TRegisteredTool;
begin
  Approval := TAllowAll.Create;
  Cfg := Default(TMcpClientConfig);
  Cfg.Server.Name := 'playwright';
  Cfg.Server.Command := 'docker';
  Cfg.Server.Args := ['run', '-i', '--rm', '--init',
    'mcr.microsoft.com/playwright/mcp'];
  Cfg.Server.Enabled := True;
  Cfg.ListTimeoutMs := 60000;
  Cfg.CallTimeoutMs := 180000;

  Client := TMcpClient.Create(Cfg, Approval, nil);
  Reg := TToolRegistry.Create;
  try
    WriteLn('opening playwright MCP server over docker stdio...');
    if not Client.Open(Reg, Err) then
    begin
      WriteLn('OPEN FAILED: ', Err);
      Halt(1);
    end;
    Tools := Client.Tools;
    WriteLn('discovered ', Length(Tools), ' tools:');
    for I := 0 to High(Tools) do
      WriteLn('  ', Tools[I].Name, '   [', Tools[I].Ref, ']');

    if Reg.Find('mcp_playwright_browser_navigate', Tool) then
    begin
      WriteLn('calling browser_navigate -> https://example.com ...');
      if Tool.Handler('{"url":"https://example.com","reason":"smoke test"}',
        Res, Err) then
        WriteLn('  OK: ', Copy(Res, 1, 200))
      else
        WriteLn('  FAILED: ', Err);
    end
    else
      WriteLn('browser_navigate not found');

    if Reg.Find('mcp_playwright_browser_close', Tool) then
    begin
      WriteLn('calling browser_close ...');
      if Tool.Handler('{"reason":"smoke test"}', Res, Err) then
        WriteLn('  OK: ', Copy(Res, 1, 200))
      else
        WriteLn('  FAILED: ', Err);
    end;
  finally
    Reg.Free;
    Client.Free;
  end;
  WriteLn('smoke done');
end.
