# Implementation Plan: Process Split

**Specs:** [Process_Split_v1.SPEC.md](Process_Split_v1.SPEC.md),
[Chat_Window_v1.SPEC.md](Chat_Window_v1.SPEC.md)

The split is mechanical (declarations move between units) but wide. Land it in
the order below so each step compiles and `make check` stays green; the chat
window is last so the memory win can be measured on a settled split.

## Phase 1 — Split the transport and the wire client

- [x] **New** `src/hildi.session.socket.pas`: move the AF_UNIX
      helpers (`MakeUnixAddr`, `ConnectFd`, `ConnectProbe`, `SendAll`,
      `ReadLineTimeout`, `ExtractLine`, `WaitReadable`, `SetNonBlocking`,
      `SetNoSigPipe`, `NowMs`, `ShellQuote`) and `RuntimeDir`, `SocketPathFor`,
      `SessionSocketReady` out of `session.runtime`.
- [x] **New** `src/hildi.session.client.pas`: move `ISessionSink`,
      `TSessionClientConfig`, `TSessionClient`, `TClientReader`, `SpawnDetached`;
      add `ResolveRuntimeBinary` and `DefaultRuntimeBinary`.
- [x] **Trim** `src/hildi.session.runtime.pas` to the server
      (`TSessionRuntime`, `TClientConn`, `RunSessionRuntime`).
- [x] **Test** `tests/test_session_client.pas`: `ResolveRuntimeBinary` (explicit
      wins, sibling fallback, `''` when neither exists); add the unit to
      `tests/hildi_tests.pas`.
- [x] **Verify** the existing `test_session_runtime.pas` and
      `test_harness_driver.pas` still pass.

## Phase 2 — Split the turn types from the worker

- [x] **Trim** `src/hildi.harness.turn.pas` to the types
      (`TTurnEventKind`, `TTurnEvent`, `TTurnQueue`, `TApprovalGate`); drop
      `agent` from its `uses`.
- [x] **New** `src/hildi.harness.turn.worker.pas` with `TTurnWorker`.
- [x] **Update** `uses` in `harness.session`, `harness.driver`, and the tests
      that construct a worker.
- [x] **Verify** `test_harness_turn.pas`, `test_harness_session.pas`,
      `test_harness_app.pas` pass.

## Phase 3 — Split the session view from the loop

- [x] **New** `src/hildi.harness.view.pas`: move
      `THarnessSessionConfig` (drop `NoLoop`) and add `TSessionView` (workspace,
      store, identity, history, metrics; no client, no tools).
- [x] **Trim** `src/hildi.harness.session.pas` to `THarnessSession`,
      owning a `TSessionView` and exposing `Loop`/`Tools`/`Queue`/`Gate`.
- [x] **Update** `session.runtime` to reach the view (`FSession.View.…`).
- [x] **Update** `harness.app` to take a `TSessionView`; drop its `agent`/`llm`
      uses if unused.
- [x] **Test** `tests/test_harness_view.pas`: open a session, read
      history/turns/totals, and assert no LLM client or tool registry is built.
- [x] **Retarget** `tests/test_harness_session.pas` through `View`.
- [x] **Verify** `test_session_runtime.pas`, `test_harness_app.pas` pass.

## Phase 4 — Split the driver

- [x] **Trim** `src/hildi.harness.driver.pas` to `ISessionDriver` and
      `TRemoteDriver`.
- [x] **New** `src/hildi.harness.driver.local.pas` with
      `TLocalDriver`.
- [x] **Update** `harness.app`, the tests, and any demo that uses `LocalDriver`.
- [x] **Verify** `test_harness_driver.pas` passes.

## Phase 5 — Two programs

- [x] **New** `examples/headless_agent.pas`: parse argv and call
      `RunSessionRuntime`.
- [x] **Trim** `examples/tui_agent.pas`: drop `session.runtime` and the
      `--session-runtime` dispatch; set `RuntimeCommand` from
      `ResolveRuntimeBinary`.
- [x] **Trim** `examples/agent_cli.pas`: drop `--session-runtime` and the server
      unit; use `session.client`.
- [x] **Makefile**: build `build/bin/hildi-agent` (`headless-agent`)
      and `build/bin/hildi` (`tui-agent`); update `help`.
- [x] **Verify**: both binaries build; `nm` shows the TUI links no
      agent/loop/tool symbols and the headless agent links no TUI symbols; the
      headless binary reports clear errors. (The spawn path is covered by
      `test_session_runtime` / `test_harness_driver`, which use the test binary
      as the runtime host.)

## Phase 6 — Bootstrap trims

- [x] **Implement** `TSessionView.Open`: load history only when asked; never
      build a client or tools.
- [x] **Implement** `THarnessSession.Open`: do not load `History`.
- [x] **Test**: `TSessionView.History` reads the store on demand
      (`TestHistoryReadsOnDemand`); no history is loaded at `Open` by
      construction (there is no cache).

## Phase 7 — Split boundary test

- [x] **Test** `tests/test_split.pas`: walk the transitive `uses` closure of the
      client roots (`harness.app`, `harness.driver`, `harness.view`) over
      `src/*.pas` and assert it contains none of `agent`, `harness.session`,
      `harness.turn.worker`, `command.tool`, `files`, `recall.tool`,
      `session.store`, `session.runtime`.

## Phase 8 — Chat window

- [x] **Implement** `TChatItem.Materialize`/`Dematerialize`/`Materialized` (the
      height memo survives a release).
- [x] **Implement** the `TChatStack` window: materialize the visible range plus
      an overscan, dematerialize the rest, and let `Measure` build a body only
      when it must recompute the height.
- [x] **Test** `tests/test_tui_chat.pas`:
      `TestStackMaterializesOnlyTheWindow` (bounded materialization, exact
      `Measure`, no growth with the block count). Existing chat/perf tests cover
      scrolling, expansion, the live tail, and a width change.
- [x] **Test** `tests/test_tui_chatpanel.pas` / `test_harness_app.pas`: rendered
      output unchanged.
- [x] **Verify** `make perf` budgets unchanged.

## Phase 9 — Documentation and completion

- [x] Update `docs/features/FEATURES.md`, `HANDOFF.md`, and the Makefile help;
      add `HILDI_RUNTIME_BIN` to `.env.example`.
- [x] Measure the heap on a large transcript: 70 / 700 / 3500 blocks allocate
      622 KB / 753 KB / 1.34 MB — flat as the block count grows, versus the
      56.6 MB baseline that retained every block's layout.
- [x] Rename this file to `Process_Split_v1.DONE.md`.

## Ordering Notes

- Phases 1–4 are independent unit moves and can land as separate commits; each
  must keep `make check` green.
- Phase 5 depends on Phases 1–4.
- Phase 8 is independent of Phases 1–7 and can be done first if the memory win
  is the priority.
