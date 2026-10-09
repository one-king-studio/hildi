program hildegard_helper_tests;
{ Console test runner for the hildegard-helper suite.

  Run all:        ./hildegard-helper-tests --all --format=plain
  List tests:     ./hildegard-helper-tests --list
  Run one suite:  ./hildegard-helper-tests --suite=TCommandRunnerTest --format=plain
  JUnit for CI:   ./hildegard-helper-tests --all --format=xml --file=results.xml }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, fpcunit, testregistry, consoletestrunner,
  hildegard.helper.session.runtime,
  test_hildegard_helper, test_store, test_llm, test_agent, test_ansi, test_env,
  test_cli, test_transcript, test_command_policy, test_command_tool,
  test_workspace, test_approval, test_session, test_tui_surface,
  test_tui_clock,
  test_tui_input, test_tui_layout, test_tui_text, test_tui_scroll,
  test_tui_app, test_tui_perf, test_harness_turn, test_tui_prompt,
  test_tui_approvalmodal, test_harness_session, test_harness_view, test_split,
  test_harness_app, test_file_tool, test_tui_encoder, test_tui_widgets,
  test_tui_animation, test_tui_grapheme, test_tui_edit, test_tui_chat,
  test_tui_compose, test_tui_chatpanel, test_recall_tool, test_harness_stats,
  test_tui_compact, test_markdown, test_markdownview, test_tls,
  test_session_protocol, test_session_runtime, test_session_client,
  test_session_socket,
  test_harness_driver, test_jsonrpc, test_stdio_child, test_mcp_config,
  test_mcp_client, test_subagent, test_subagent_supervisor,
  test_mcp_cli, test_mcp_http, test_mcp_oauth,
  test_mcp_oauth_flow, test_subagent_sidebar, test_tui_sidebar,
  test_subagent_spy, test_tui_palette, test_async_scheduler,
  test_async_future;

var
  Runner: TTestRunner;
  I: Integer;
  Args: array of string;
begin
  { When the client spawns a runtime it re-executes this binary with the
    runtime argv; run the runtime instead of the test suite. }
  if (ParamCount >= 2) and (ParamStr(1) = '--session-runtime') then
  begin
    SetLength(Args, ParamCount);
    for I := 1 to ParamCount do
      Args[I - 1] := ParamStr(I);
    Halt(RunSessionRuntime(Args));
  end;

  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Title := 'hildegard-helper test suite';
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
