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
  test_hildegard_helper, test_store, test_llm, test_agent, test_ansi, test_env,
  test_cli, test_transcript, test_command_policy, test_command_tool,
  test_workspace, test_approval, test_session, test_tui_surface,
  test_tui_input, test_tui_layout, test_tui_text, test_tui_scroll,
  test_tui_app, test_tui_perf, test_harness_turn, test_tui_prompt,
  test_tui_approvalmodal, test_harness_session,
  test_harness_app, test_file_tool, test_tui_encoder, test_tui_widgets,
  test_tui_animation, test_tui_grapheme, test_tui_edit, test_tui_chat,
  test_tui_compose, test_tui_chatpanel, test_recall_tool;

var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Title := 'hildegard-helper test suite';
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
