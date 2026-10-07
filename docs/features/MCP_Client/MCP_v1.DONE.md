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

### Phase 2: Stdio child manager (`hildegard.helper.stdio.child`) — DONE

- [x] **Promote `NormalizeExit`**: exported in place from
      `hildegard.helper.process` (Decision A), with `TestNormalizeExitMapping`.
- [x] **Test**: `TestSpawnEchoRoundTrip` (a `/bin/sh` fake echoes a line).
- [x] **Implement**: `TStdioChild.Start`/`WriteLine`/`ReadLine` over pipes
      (`fpRead`/`fpWrite` + `ExtractLine` + `fpSelect`).
- [x] **Test**: `TestReadTimeout`, `TestEofOnExit`, `TestBrokenPipeOnWrite`,
      `TestTooLongLine`, `TestStderrDoesNotBlockStdout`, `TestStderrTail`
      (stderr tail asserted inside `TestStderrDoesNotBlockStdout`).
- [x] **Implement**: the read/err paths and the bounded stderr tail.
- [x] **Test**: `TestCloseKillsNonCooperativeChild` (bounded close-then-kill,
      reaped, no zombie), `TestCloseIsIdempotent`.
- [x] **Implement**: `Close`.
- [x] **Refactor**; `make check` — 843 tests, 0 failures; leak-clean.

  Notes: `fpFD_ISSET` returns an integer, not Boolean (compare `<> 0`).
  `TProcess.Running` only reflects an exit after a wait, so `Close` polls the
  non-blocking `WaitOnExit(timeout)`. `CloseInput` does not always deliver EOF
  (see the `ponytail:` note in `Close`) — bounded, leak-clean, acceptable for
  v1.

### Phase 3: Config (`hildegard.helper.mcp.config` + store v3) — DONE

- [x] **Test**: `TestResolveGlobalOnly`, `TestResolveWorkspaceOverridesGlobal`,
      `TestResolveUnionsDistinctNames`, `TestResolveExcludesDisabled`,
      `TestResolveAgentOverridesAll`, `TestResolveSkipsOtherWorkspaceRows`,
      `TestResolveIsNameSorted` — red.
- [x] **Implement**: `ResolveMcpConfig`.
- [x] **Test**: `TestValidateAcceptsValidRow`, `TestValidateRejectsBadName`,
      `TestValidateRejectsEmptyCommand`, `TestValidateRejectsBadEnvEntry`,
      `TestValidateRejectsTooManyServers`, `TestIsValidMcpName`.
- [x] **Implement**: `ValidateMcpServerRow`, `ValidateMcpConfig`, `IsValidMcpName`.
- [x] **Test (store)**: `TestMcpServerMigrationIsAdditive` (a v2 DB upgrades to
      v3; earlier data intact).
- [x] **Implement**: migration v3 (`mcp_servers` table + index) in
      `hildegard.helper.store`.
- [x] **Test (store)**: `TestSaveMcpServerUpserts`, `TestLoadMcpServersScoped`,
      `TestRemoveMcpServer`, `TestMcpArgsEnvRoundTrip`,
      `TestSaveMcpServerRejectsInvalid`.
- [x] **Implement**: `LoadMcpServers`/`SaveMcpServer`/`RemoveMcpServer`/
      `ListMcpServers` (upsert via `ON CONFLICT`).
- [x] **Refactor**; `make check` — 862 tests, 0 failures; leak-clean.

  Notes: `out` open-array params cannot be assigned, so the JSON (de)coders take
  a named `TStringArray` (`Types`). A `case` over a full enum needs no `else`
  (`-Sew` flags unreachable code). The `DefaultMigrations` array length had to
  grow to 3 — writing `Result[2]` past a 2-length array corrupted memory (a
  range-check error cascaded to every store test).

### Phase 4: MCP client (`hildegard.helper.mcp.client`) — DONE

- [x] **Test**: `TestMcpRefIsStable`, `TestMcpToolNameIsProviderSafe`,
      `TestMcpToolNameNeverCollidesWithNative` (covered by the `mcp_` prefix +
      `TestMcpUniqueToolNameResolvesCollision`), `TestToolNameCollisionResolved`.
- [x] **Implement**: `McpRef`, `McpToolName`, `McpUniqueToolName`.
- [x] **Test**: `TestSchemaStripsReasonAndRejectsNonObject`.
- [x] **Implement**: `McpSchemaToParams`.
- [x] **Test**: `TestResultMapsTextNonTextAndStructured`.
- [x] **Implement**: `McpResultToText`, `McpResultIsError`.
- [x] **Test (fake server over real pipes)**: `TestOpenRegistersToolsAndCallSucceeds`.
- [x] **Implement**: `TMcpClient.Open` (handshake, initialized, list, register).
- [x] **Test**: `TestUnsupportedProtocolRefused`, `TestListTimeoutDropsServer`.
- [x] **Implement**: protocol negotiation and bounded listing.
- [x] **Test**: `TestServerRequestAnsweredAndIgnored` (sampling → `-32601`).
- [x] **Implement**: the read loop's notification/request handling.
- [x] **Test**: `TestCallDeniedByApproval`.
- [x] **Implement**: the `tools/call` handler + `IApprovalService` ask.
- [x] **Implement**: `TMcpManager`, per-server isolation, `Close`.
- [x] **Refactor**; `make check` — 872 tests, 0 failures; leak-clean.

  Notes: `fpjson`'s `AsJSON` is single-line (`foSingleLineObject`), so it is
  safe as a line-framed JSON-RPC payload. A `{ }` comment containing a literal
  brace closes early — watch JSON snippets in comments.

### Phase 5: Integration & Docs — DONE

- [x] **Wire `THarnessSession`**: build the effective list
      (`LoadMcpServers` → `ResolveMcpConfig`), construct `TMcpManager`, `Open`
      into `FTools`, `Close` in `Close`; MCP events recorded via
      `IConversationStore.AppendError`.
- [x] **Test**: `TestMcpServerToolsRegistered` alongside native tools.
- [x] **Doc comments**: house style (`{ ... }`) on the new public interfaces.
- [x] **Update SPECs**: the client API was reconciled with the implementation
      (`TMcpToolHandler`, `CallTool`, `Refresh(ATools)`).

  Notes: no separate example binary — the session integration test exercises a
  configured fake server end to end, which is the same coverage without a new
  Makefile target. `Refresh` was made real (not the "may be a no-op" of the
  SPEC): it re-lists and registers only tools whose ref is not already
  registered, tracked in `FRegisteredRefs` (a re-list would otherwise collide
  and suffix duplicates).

### Phase 6: Validation — DONE

- [x] **Run**: per-suite runs green (`TJsonRpcTest` 17, `TStdioChildTest` 9,
      `TMcpConfigTest` 13, `TMcpClientTest` 10, `THarnessSessionTest` 11).
- [x] **Run**: `make test` (whole suite) — 873 tests, 0 failures.
- [x] **Run**: `make test-leak` (no leaks) — 0 failures.
- [x] **Run**: `make check` (all gates) — green.

  Caveat: everything is tested against fakes and `/bin/sh` scripts (hermetic,
  per `testing.md`). No real MCP server has been run — that is calibration, and
  it is out of scope for the automated suite.

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

## Live calibration (real MCP server)

Beyond the hermetic suite, the client was driven against a **real** MCP server:
the Playwright container (`mcr.microsoft.com/playwright/mcp`) over docker stdio,
via `examples/mcp_smoke.pas` (`make mcp-smoke`, needs Docker; not part of
`make check`).

Results (Docker 29.8.2, macOS aarch64):

- The handshake succeeded: the server answered `initialize` with
  `protocolVersion 2024-11-05` (in our supported set) and
  `capabilities.tools.listChanged: true`.
- **25 tools** were discovered and namespaced (`mcp_playwright_browser_navigate`,
  ref `mcp/playwright/browser_navigate`, …).
- A real call worked: `browser_navigate` → `https://example.com` returned
  "Page Title: Example Domain"; `browser_close` succeeded.
- **Teardown was clean on real hardware:** after the smoke exited,
  `docker ps` showed **no orphan container** — our bounded close-then-kill
  terminated the real `docker run` child. This is the part fakes cannot prove.

Observations (no action needed):

- The Playwright schemas use `$schema`, `anyOf`, `enum`, and `default`, which
  `McpSchemaToParams` passes through untouched; the registry accepted all 25, so
  the mapper is permissive enough for a real server.
- The server writes a `.playwright-mcp/` directory into its cwd — relevant when
  a `cwd` is chosen for it.
