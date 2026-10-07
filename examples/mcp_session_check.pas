program mcp_session_check;
{ Verification: open a real THarnessSession against a store (a copy, so the
  real one is not mutated) and confirm a configured MCP server's tools register
  alongside the native tools. Run by hand:

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
  I, McpCount: Integer;
  Specs: TToolSpecArray;
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
    Specs := Session.Tools.Specs;
    WriteLn('session tools: ', Length(Specs));
    McpCount := 0;
    for I := 0 to High(Specs) do
    begin
      if Pos('mcp_', Specs[I].Name) = 1 then
      begin
        Inc(McpCount);
        if McpCount <= 5 then
          WriteLn('  ', Specs[I].Name);
      end;
    end;
    WriteLn('MCP tools registered: ', McpCount);
  finally
    Session.Free;
  end;
end.
