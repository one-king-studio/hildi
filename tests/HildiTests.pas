program HildiTests;
{ Console test runner for the hildi suite.

  Run all:        ./hildi-tests --all --format=plain
  List tests:     ./hildi-tests --list
  Run one suite:  ./hildi-tests --suite=TCommandRunnerTest --format=plain
  JUnit for CI:   ./hildi-tests --all --format=xml --file=results.xml }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring, BaseUnix,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, fpcunit, testregistry, consoletestrunner,
  HildiSessionRuntime,
  TestHildi, TestStore, TestLLM, TestAgent, TestANSI, TestEnv,
  TestCLI, TestTranscript, TestCommandPolicy, TestCommandTool,
  TestWorkspace, TestApproval, TestSession, TestTUISurface,
  TestTUIClock,
  TestTUIInput, TestTUILayout, TestTUIText, TestTUIScroll,
  TestTUIApp, TestTUIPerf, TestHarnessTurn, TestTUIPrompt,
  TestTUIApprovalModal, TestHarnessSession, TestHarnessView, TestSplit,
  TestHarnessApp, TestFileTool, TestTUIEncoder, TestTUIWidgets,
  TestTUIAnimation, TestTUIGrapheme, TestTUIEdit, TestTUIChat,
  TestTUICompose, TestTUIChatPanel, TestRecallTool, TestHarnessStats,
  TestTUICompact, TestMarkdownView, TestTUIFileviewer,
  TestMarkdownTree, TestMarkdownStream,
  TestMarkdownInline, TestTLS,
  TestDashboardPanel,
  TestSessionProtocol, TestSessionRuntime, TestSessionClient,
  TestSessionSocket,
  TestHarnessDriver, TestJSONRPC, TestStdioChild, TestMCPConfig,
  TestMCPClient, TestSubagent, TestSubagentSupervisor,
  TestMCPCLI, TestMCPHTTP, TestMCPOAUTH,
  TestMCPOAUTHFlow, TestSubagentSidebar, TestTUISidebar,
  TestSubagentSpy, TestTUIPalette, TestAsyncScheduler,
  TestAsyncFuture, TestAsyncQueue, TestAsyncTimers,
  TestAsyncObservable, TestAsyncSubject, TestAsyncOperators,
  TestAsyncTime, TestAsyncContext, TestAsyncConcurrency,
  TestAsyncParity, TestSkills, TestWrap, TestReplyMeta, TestHandoff,
  TestTUISessionsModal, TestTUIDiffviewer, TestTUIHistorymodal, TestFuzzy, TestTUIActions, TestPatch, TestYAML,
  TestCommandPaths,
  SmokeProvider, TestSmokeProvider,
  TestShellParser, TestShellIsolation, TestShellInterpreter,
  TestShellCorpus, TestShellDifferential, TestShellHarnessFs,
  TestHtmlentities, TestGitIgnore, TestShellTextLines, TestShellEffects,
  TestWorkspaceSnapshot,
  TestUTF8,
  TestShellCommands, TestShellTier, TestShellExecutor, TestShellCommandsDiff,
  TestShellTierCorpus,
  ChangesTypes, ChangesText, ChangesStore, ChangesLog, TestChanges,
  TestChangesIsolation, FileIgnoreRules, TestFileIgnore,
  HildiChangesStore, TestChangesStore, TestChangesSummary,
  HildiChangesRevert, TestChangesRevert,
  HildiBoard, HildiBoardStore, TestBoardStore,
  HildiBoardTools, TestBoardTools,
  HildiTasks, HildiTasksStore, TestTasksStore,
  HildiTasksTools, TestTasksTools, TestFeaturesIndex,
  HildiCoordination, TestCoordination,
  HildiChangesRecorder, TestChangesRecorder;

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
    Runner.Title := 'hildi test suite';
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
