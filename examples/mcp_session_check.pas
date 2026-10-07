program mcp_session_check;
{ Verification: open a real THarnessSession against a store (a copy, so the
  real one is not mutated), trigger the turn boundary, and confirm a configured
  MCP server's tools resolve through the provider seam. Run by hand:

    ./build/bin/mcp-session-check <store-path> <workspace-path> }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first: sync primitives
  SysUtils,
  hildegard.helper.llm, hildegard.helper.agent,
  hildegard.helper.harness.session, hildegard.helper.harness.view;

var
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err: string;
  Tool: TRegisteredTool;
  Names: array[0..2] of string;
  I: Integer;
  Found: Integer;
begin
  if ParamCount < 2 then
  begin
    WriteLn('usage: mcp-session-check <store-path> <workspace-path>');
    Halt(2);
  end;
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
    { Fire the turn boundary so providers reconcile from the store. }
    Session.Loop.PrepareProviders;

    Names[0] := 'mcp_playwright_browser_navigate';
    Names[1] := 'mcp_playwright_browser_close';
    Names[2] := 'mcp_playwright_browser_snapshot';
    Found := 0;
    for I := Low(Names) to High(Names) do
      if Session.Loop.ResolveTool(Names[I], Tool) then
      begin
        Inc(Found);
        WriteLn('resolved: ', Names[I]);
      end
      else
        WriteLn('MISSING:  ', Names[I]);
    WriteLn('MCP tools resolved: ', Found, ' of ', Length(Names));
  finally
    Session.Free;
  end;
end.
