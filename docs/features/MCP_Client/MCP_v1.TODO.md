# Implementation Plan: MCP Client v1

**Related Specifications:** `JsonRpc_v1.SPEC.md`,
`Stdio_Child_Manager_v1.SPEC.md`, `Config_v1.SPEC.md`, `Mcp_Client_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Implement MCP v1 (stdio): the helper connects to configured MCP servers, adopts
their tools into the existing `TToolRegistry`, and dispatches calls through the
existing reason gate, approval engine, and ledger — **no loop changes**. Four
new units plus a store migration. Tasks are checkboxes; update them in real time.
Each implementation task starts with a failing test (TDD).

**Ordering is dependency-driven:** JSON-RPC (pure) → stdio child (I/O) → config
(pure + store) → client (integration). The client is last because it composes
all three.

## Implementation Tasks

### Phase 0: Setup & Foundation

- [ ] **Branch**: already on `agent/mcp` (repurposed onto main; integrator-owned
      files are ours this round).
- [ ] **Add test units** to the `uses` clause of
      `tests/hildegard_helper_tests.pas`: `test_jsonrpc`, `test_stdio_child`,
      `test_mcp_config`, `test_mcp_client` (added as each unit lands).
- [ ] **Confirm conventions** against `docs/guidelines/testing.md`:
      `{$mode delphi}{$H+}`, `-Sew` (warnings are errors), managed locals via
      `Default(T)`, `{$codepage utf8}` if any non-ASCII literal.

### Phase 1: JSON-RPC codec (`hildegard.helper.jsonrpc`) — DONE

Pure, no I/O — the easiest red/green, and the base of everything.

- [x] **Test**: `TestEncodeRequestDecodesAsServerRequest`,
      `TestEncodeNotificationDecodesAsNotification`,
      `TestEncodeResultDecodesAsResponse`, `TestEncodeErrorDecodesAsErrorResponse`,
      `TestEncodeOmitsEmptyParams`, `TestEncodeNeverContainsNewline` — red.
- [x] **Implement**: `TJsonRpcCodec` encode functions — green.
- [x] **Test**: `TestDecodeResponseResult`, `TestDecodeErrorResponse`,
      `TestDecodeServerRequest`, `TestDecodeMalformed*` (array, scalar, missing
      `jsonrpc`, non-integer id, neither result nor error, method+result).
- [x] **Implement**: `TJsonRpcCodec.Decode` classification.
- [x] **Test**: `TestIdGenIsMonotonicAndUnique`.
- [x] **Implement**: the id generator.
- [x] **Test**: `TestEncodeRejectsBadParamsJson` (raises `EJsonRpcEncode`).
- [x] **Refactor**; `make check` — 834 tests, 0 failures; leak-clean.

  Note: `fpjson`'s `AsJSON` pretty-prints, so tests compare JSON **semantically**
  (a `TJsonRpcTest.AssertJsonEquals` helper), not byte-for-byte. The codec keeps
  the parsed node as-is; JSON-RPC is whitespace-insensitive.

### Phase 2: Stdio child manager (`hildegard.helper.stdio.child`)

- [ ] **Promote `NormalizeExit`**: move its declaration to the interface of
      `hildegard.helper.process` (Decision A). Add a regression test asserting
      the existing runner's exit codes are unchanged.
- [ ] **Test**: `TestSpawnEchoRoundTrip` (a scripted fake child echoes a line) —
      red.
- [ ] **Implement**: `TStdioChild.Start`/`WriteLine`/`ReadLine` over pipes
      (`fpRead`/`fpWrite` + `ExtractLine`/`WaitReadable`).
- [ ] **Test**: `TestReadTimeout`, `TestEofOnExit`, `TestBrokenPipeOnWrite`,
      `TestTooLongLine`, `TestStderrDoesNotBlockStdout`, `TestStderrTail`.
- [ ] **Implement**: the remaining read/err paths and the stderr ring.
- [ ] **Test**: `TestCloseKillsNonCooperativeChild` (bounded close-then-kill,
      reaped, no zombie).
- [ ] **Implement**: `Close`.
- [ ] **Refactor**; `make test-leak SUITE=TStdioChildTest`.

### Phase 3: Config (`hildegard.helper.mcp.config` + store v3)

- [ ] **Test**: `TestResolveGlobalOnly`, `TestResolveWorkspaceOverridesGlobal`,
      `TestResolveUnionsDistinctNames`, `TestResolveExcludesDisabled`,
      `TestResolveAgentOverridesAll` (hand-built row) in
      `tests/test_mcp_config.pas` — red.
- [ ] **Implement**: `ResolveMcpConfig`.
- [ ] **Test**: `TestValidateRow*` (empty/illegal name, empty command, non-string
      args, bad env entry, over `MaxMcpServers`).
- [ ] **Implement**: `ValidateMcpServerRow`.
- [ ] **Test (store)**: `TestMigrationV3Applies` (`StoreSchemaVersion` = 3; a v2
      DB upgrades additively) in `tests/test_store.pas` — red.
- [ ] **Implement**: migration v3 (`mcp_servers` table + index) in
      `hildegard.helper.store`.
- [ ] **Test (store)**: `TestSaveMcpServerUpserts`, `TestLoadMcpServersScoped`,
      `TestRemoveMcpServer`, `TestArgsEnvRoundTrip`.
- [ ] **Implement**: `LoadMcpServers`/`SaveMcpServer`/`RemoveMcpServer`/
      `ListMcpServers`.
- [ ] **Refactor**; `make check`.

### Phase 4: MCP client (`hildegard.helper.mcp.client`)

- [ ] **Test**: `TestMcpRefIsStable`, `TestMcpToolNameIsProviderSafe`,
      `TestMcpToolNameNeverCollidesWithNative`, `TestToolNameCollisionResolved`
      — red.
- [ ] **Implement**: `McpRef`, `McpToolName` (+ collision suffixing).
- [ ] **Test**: `TestSchemaAcceptsValid`, `TestSchemaStripsServerReason`,
      `TestSchemaRejectsNonObject`, `TestSchemaRejectsOverWide`.
- [ ] **Implement**: `McpSchemaToParams`.
- [ ] **Test**: `TestResultConcatenatesText`, `TestResultMarksNonText`,
      `TestResultStructuredNote`, `TestResultIsError`.
- [ ] **Implement**: `McpResultToText`.
- [ ] **Test (fake server over real pipes)**: `TestOpenRegistersTools`
      (initialize + list) — the core lifecycle test.
- [ ] **Implement**: `TMcpClient.Open` (handshake, initialized, list, register).
- [ ] **Test**: `TestUnsupportedProtocolRefused`, `TestListTimeoutDropsServer`.
- [ ] **Implement**: protocol negotiation and bounded listing.
- [ ] **Test**: `TestNotificationsConsumed`, `TestServerRequestAnsweredWithError`
      (sampling/roots/elicitation → `-32601`).
- [ ] **Implement**: the read loop's notification/request handling.
- [ ] **Test**: `TestCallDispatchesThroughApproval` (allow rule → proceeds; none
      → asks; deny → blocked), `TestCallStripsReason`.
- [ ] **Implement**: the `tools/call` handler + `IApprovalService` ask.
- [ ] **Test**: `TestServerDeathMidSession` (clean tool failure),
      `TestCloseTerminatesChildren` (leak-clean).
- [ ] **Implement**: `TMcpManager`, per-server isolation, `Close`.
- [ ] **Refactor**; `make test-leak SUITE=TMcpClientTest`.

### Phase 5: Integration & Docs

- [ ] **Wire `THarnessSession`**: build the effective list
      (`LoadMcpServers` → `ResolveMcpConfig`), construct `TMcpManager`, `Open`
      into `FTools`, `Close` in `Close`. (Existing file — the one core edit.)
- [ ] **Test**: `TestSessionRegistersMcpTools` alongside native tools.
- [ ] **Example**: extend `examples/` (or add one) to open a session with a
      local fake server configured.
- [ ] **Doc comments**: `{** ... }` on the new public interfaces (fpdoc style).
- [ ] **Update SPECs** if behaviour diverged; record deviations below.

### Phase 6: Validation

- [ ] **Run**: `make test SUITE=...` for each new suite (green).
- [ ] **Run**: `make test` (whole suite).
- [ ] **Run**: `make test-leak` (no leaks).
- [ ] **Run**: `make check` (all gates).

## Dependencies & Ordering

### Must Complete Before Starting

- Phase 1 before Phase 4 (client encodes/decodes).
- Phase 2 before Phase 4 (client reads/writes lines).
- Phase 3 before Phase 5 (session needs the resolved list).
- `NormalizeExit` export (Phase 2) before the child manager's `ExitCode`.

### Can Be Done in Parallel

- Phase 1 and Phase 3 (both pure; disjoint).
- Phase 2's fake-child fixture is independent of Phases 1/3.

### Critical Path

1. JSON-RPC codec
2. Stdio child manager
3. Config + store v3
4. MCP client
5. `THarnessSession` wiring
6. `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.jsonrpc.pas
src/hildegard.helper.stdio.child.pas
src/hildegard.helper.mcp.config.pas
src/hildegard.helper.mcp.client.pas
tests/test_jsonrpc.pas
tests/test_stdio_child.pas
tests/test_mcp_config.pas
tests/test_mcp_client.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas        (register the four new test units)
src/hildegard.helper.process.pas        (export NormalizeExit — Decision A)
src/hildegard.helper.store.pas          (migration v3 + 4 mcp_servers methods)
src/hildegard.helper.harness.session.pas (own the TMcpManager)
examples/...                            (demonstrate an MCP session)
docs/features/FEATURES.md               (status) — integrator-owned
docs/features/MCP_Client/*.SPEC.md      (if behaviour diverges)
HANDOFF.md                              (state) — integrator-owned
```

## Success Criteria

- [ ] All tasks above checked.
- [ ] Every acceptance criterion in `FEATURE.md` (v1) maps to a passing test.
- [ ] MCP calls are approval-gated, ledgered, and reason-validated with **no
      loop change** (the only core edit is `THarnessSession` wiring + store).
- [ ] A dead server costs the session only its own tools.
- [ ] `make check` passes (tests + leak gate), including child teardown.
- [ ] Implementation matches the four SPECs.

## Notes & Considerations

- **Playground `.env` (lesson).** The worktree is a separate checkout and `.env`
  is gitignored, so the playground starts with **no** `.env`. The runtime/driver
  tests re-exec `ParamStr(0)` as a session runtime, which loads `.env` from cwd
  (`TSessionView.Open`); without it, 25 runtime-dependent tests fail. A new
  playground needs its own `.env` (copy the main one) — this is the "own store"
  idea from `source-control.md` applied to config.
- **Deferred deliberately (v1):** operator UI (operator writes SQL directly);
  agent self-configuration (schema reserved); file config sources (JSON/JSONC/
  TOML); param-scoped MCP approvals; MCP server auto-restart; JSON-RPC batch.
- **Ceiling:** the child manager is synchronous/single-threaded (Ponytail — no
  reader thread); a slow call blocks the turn, bounded by the call timeout.
- **Risk:** child-process teardown under the leak gate is the fiddliest part;
  budget time for Phase 2's kill/reap tests.
- Record deviations from the SPECs here, with the reason.
