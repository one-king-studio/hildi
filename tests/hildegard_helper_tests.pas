program hildegard_helper_tests;
{ Console test runner for the hildegard-helper suite.

  Run all:        ./hildegard-helper-tests --all --format=plain
  List tests:     ./hildegard-helper-tests --list
  Run one suite:  ./hildegard-helper-tests --suite=TCommandRunnerTest --format=plain
  JUnit for CI:   ./hildegard-helper-tests --all --format=xml --file=results.xml }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring, BaseUnix,{$endif}   // cthreads first; cwstring for Unicode
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
  test_dashboard_panel,
  test_session_protocol, test_session_runtime, test_session_client,
  test_session_socket,
  test_harness_driver, test_jsonrpc, test_stdio_child, test_mcp_config,
  test_mcp_client, test_subagent, test_subagent_supervisor,
  test_mcp_cli, test_mcp_http, test_mcp_oauth,
  test_mcp_oauth_flow, test_subagent_sidebar, test_tui_sidebar,
  test_subagent_spy, test_tui_palette, test_async_scheduler,
  test_async_future, test_async_queue, test_async_timers,
  test_async_observable, test_async_subject, test_async_operators,
  test_async_time, test_async_context, test_async_concurrency,
  test_async_parity, test_skills, test_wrap, test_replymeta, test_handoff,
  test_tui_sessionsmodal, test_tui_diffviewer, test_tui_historymodal, test_fuzzy, test_tui_actions, test_patch, test_yaml,
  test_command_paths,
  smoke_provider, test_smoke_provider,
  test_shell_parser, test_shell_isolation, test_shell_interpreter,
  test_shell_corpus, test_shell_differential, test_shell_harness_fs,
  test_htmlentities, test_gitignore, test_shell_textlines, test_shell_effects,
  test_workspace_snapshot,
  test_utf8,
  test_shell_commands, test_shell_tier, test_shell_executor, test_shell_commands_diff,
  test_shell_tier_corpus,
  changes.types, changes.text, changes.store, changes.log, test_changes,
  test_changes_isolation, fileignore.rules, test_fileignore,
  hildegard.helper.changes.store, test_changes_store, test_changes_summary,
  hildegard.helper.changes.revert, test_changes_revert,
  hildegard.helper.board, hildegard.helper.board.store, test_board_store,
  hildegard.helper.board.tools, test_board_tools,
  hildegard.helper.tasks, hildegard.helper.tasks.store, test_tasks_store,
  hildegard.helper.tasks.tools, test_tasks_tools, test_features_index,
  hildegard.helper.coordination, test_coordination,
  hildegard.helper.changes.recorder, test_changes_recorder;

var
  Runner: TTestRunner;
  I: Integer;
  Args: array of string;
begin
  {$ifdef unix}
  { A child that closes a pipe must not kill the suite with SIGPIPE. The leak
    test binary writes far more (heaptrc walks every allocation), so a spawned
    runtime whose pipe has already gone away terminated the whole process with
    signal 13 - and only when the suites ran in isolation, which is the shape
    scripts/test-parallel.sh uses. Ignoring it turns a dead process into an EPIPE
    the writing call can report, like the sockets already do via SO_NOSIGPIPE. }
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$endif}

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
