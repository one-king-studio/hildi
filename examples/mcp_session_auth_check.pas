program mcp_session_auth_check;
{ Open a real THarnessSession against the store and reconcile MCP, so the
  session's OAuth token wiring is exercised (not just the CLI's). }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}
  SysUtils,
  hildegard.helper.harness.session, hildegard.helper.harness.view,
  hildegard.helper.agent;

var
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err: string;
  Tool: TRegisteredTool;
begin
  Cfg := Default(THarnessSessionConfig);
  Cfg.StorePath := ParamStr(1);
  Cfg.WorkspacePath := ParamStr(2);
  Session := THarnessSession.Open(Cfg, Err);
  if Session = nil then
  begin
    WriteLn('OPEN FAILED: ', Err);
    Halt(1);
  end;
  try
    { Open already reconciles; fire the boundary too. }
    Session.Loop.PrepareProviders;
    if Session.Loop.ResolveTool('mcp_example_company_list', Tool) then
      WriteLn('example tools present in the session')
    else
      WriteLn('example tools MISSING in the session');
  finally
    Session.Free;
  end;
end.
