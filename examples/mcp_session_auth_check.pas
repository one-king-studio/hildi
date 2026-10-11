program mcp_session_auth_check;
{ Open a real THarnessSession against the store and reconcile MCP, so the
  session's OAuth token wiring is exercised (not just the CLI's).

  Usage: mcp_session_auth_check <store> <workspace> <tool-name>
  The tool name is namespaced by the server, e.g. server "acme" exposing a
  "list" tool -> mcp_acme_list. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}
  SysUtils,
  hildegard.helper.harness.session, hildegard.helper.harness.view,
  hildegard.helper.agent;

var
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err, ToolName: string;
  Tool: TRegisteredTool;
begin
  Cfg := Default(THarnessSessionConfig);
  Cfg.StorePath := ParamStr(1);
  Cfg.WorkspacePath := ParamStr(2);
  ToolName := ParamStr(3);
  if ToolName = '' then
  begin
    WriteLn('usage: mcp_session_auth_check <store> <workspace> <tool-name>');
    Halt(2);
  end;
  Session := THarnessSession.Open(Cfg, Err);
  if Session = nil then
  begin
    WriteLn('OPEN FAILED: ', Err);
    Halt(1);
  end;
  try
    { Open already reconciles; fire the boundary too. }
    Session.Loop.PrepareProviders;
    if Session.Loop.ResolveTool(ToolName, Tool) then
      WriteLn(ToolName, ' present in the session')
    else
      WriteLn(ToolName, ' MISSING in the session');
  finally
    Session.Free;
  end;
end.
