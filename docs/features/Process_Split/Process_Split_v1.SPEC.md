# Component Specification: Process Split

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Separate the headless agent from the TUI client into two programs, and separate
the units they share so the compiler's `uses` closure enforces the boundary. The
headless agent hosts the session runtime and links no TUI unit; the TUI client
renders and drives a runtime and links no agent, tool, conversation-store, or
runtime-server unit. The split also removes the bootstrap work each side does for
the other: the runtime loads history it never reads, and the client builds an LLM
client and the default tools it never uses.

## Requirements

### Functional

- [ ] A `hildegard-helper-agent` program runs `RunSessionRuntime` and links no
      TUI unit.
- [ ] A `hildegard-helper-tui` program drives a runtime and links no `agent`,
      `harness.session` (the loop), `harness.turn.worker`, `command.tool`,
      `files`, `recall.tool`, `session.store`, or `session.runtime` unit.
- [ ] The TUI spawns the headless binary located by `HILDEGARD_RUNTIME_BIN`, else
      a sibling of the TUI executable; a missing binary is a clear error.
- [ ] `agent_cli` is a client: it uses `session.client` and no longer hosts the
      runtime.
- [ ] `TSessionView` opens a session without loading history beyond what a
      caller asks for, and without an LLM client or tools.
- [ ] `THarnessSession` (the loop) does not load `History` unless asked.
- [ ] `TLocalDriver` is retained, in its own unit, for tests and demos.

### Non-Functional

- Performance: the split adds no runtime overhead; the wire schema is unchanged.
- Reliability: leak-clean; `make check` passes.
- Portability: macOS and Linux, FPC 3.3.1.
- Maintainability: the client/server boundary is a unit boundary, asserted by a
  test, not by convention.

## Contracts & Interfaces

> Contracts are Pascal type declarations. Bodies are the implementer's.

### Unit Map

```text
                        ┌───────────────────────────┐
   client (TUI, CLI)    │  session.protocol         │  schema + codec
                        │  session.socket     (new) │  AF_UNIX primitives
                        │  session.client     (new) │  TSessionClient, ISessionSink
                        │  harness.turn             │  TTurnEvent, TTurnQueue, gate
                        │  harness.view       (new) │  TSessionView
                        │  harness.driver           │  ISessionDriver, TRemoteDriver
                        └───────────────────────────┘
   server (agent)       ┌───────────────────────────┐
                        │  session.runtime          │  TSessionRuntime, RunSessionRuntime
                        │  harness.session          │  THarnessSession (the loop)
                        │  harness.turn.worker (new)│  TTurnWorker
                        │  agent, command.tool, files, recall.tool, session.store
                        │  harness.driver.local (new)│ TLocalDriver
                        └───────────────────────────┘
```

### `hildegard.helper.session.socket` (new)

Transport primitives shared by the client and the server. Uses only
`Classes, SysUtils, BaseUnix, Sockets` — no protocol, no agent.

```pascal
function RuntimeDir: string;
function SocketPathFor(const ASessionId: string): string;
function SessionSocketReady(const ASessionId: string): Boolean;
```

The low-level helpers currently private to `session.runtime` (`MakeUnixAddr`,
`ConnectFd`, `ConnectProbe`, `SendAll`, `ReadLineTimeout`, `ExtractLine`,
`WaitReadable`, `SetNonBlocking`, `SetNoSigPipe`, `NowMs`, `ShellQuote`) move
here as unit-level declarations so both halves share one implementation.

### `hildegard.helper.session.client` (new)

The wire client. Uses `session.socket` and `session.protocol`.

```pascal
type
  ISessionSink = interface ... end;          // unchanged, moves here
  TSessionClientConfig = record ... end;     // unchanged, moves here
  TSessionClient = class ... end;            // unchanged, moves here

const
  DefaultRuntimeBinary = 'hildegard-helper-agent';

{ The runtime binary to spawn: AExplicit (from HILDEGARD_RUNTIME_BIN) when it
  names a file, else a sibling of AExecutable named DefaultRuntimeBinary. ''
  when neither exists, so the caller can fail with a clear message. }
function ResolveRuntimeBinary(const AExplicit, AExecutable: string): string;
```

`SpawnDetached` and the connect-or-spawn loop move here; the client owns
spawning the server.

### `hildegard.helper.session.runtime` (trimmed)

The server. Uses `session.socket`, `session.protocol`, `harness.session`,
`harness.turn`, `harness.turn.worker`.

```pascal
type
  TSessionRuntimeConfig = record ... end;    // unchanged
  TSessionRuntime = class ... end;           // unchanged
function RunSessionRuntime(const AArgs: array of string): Integer;
```

`TSessionClient`, `ISessionSink`, and the transport helpers leave this unit.

### `hildegard.helper.harness.turn` (trimmed to types) and `.worker` (new)

`harness.turn` keeps the pure thread-boundary types and drops `agent` from its
`uses`; the worker, which needs `TAgentLoop`, moves out.

```pascal
{ hildegard.helper.harness.turn — uses llm, approval only. }
type
  TTurnEventKind = (...);   // unchanged
  TTurnEvent = record ... end;
  TTurnQueue = class ... end;
  TApprovalGate = class ... end;

{ hildegard.helper.harness.turn.worker — uses harness.turn, agent, llm. }
type
  TTurnWorker = class(TThread) ... end;
```

Keeping the types in `harness.turn` means existing `uses harness.turn` call
sites are unchanged.

### `hildegard.helper.harness.view` (new)

The client-side session handle: workspace, store, identity, history, metrics. No
loop, no LLM client, no tools. Uses `llm, workspace, store, session`.

```pascal
type
  THarnessSessionConfig = record
    WorkspacePath: string;
    StorePath: string;
    SessionId: string;
    Resume: Boolean;
    Model: string;
    Endpoint: string;
    SystemPrompt: string;        // loop only; the view ignores it
    ToolResultCap: Integer;      // loop only
    MaxContextTokens: Integer;
    Transport: TLLMTransport;    // loop only; test seam
  end;

  TSessionView = class
  public
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): TSessionView;
    destructor Destroy; override;
    property SessionId: string read;
    property WorkspaceRoot: string read;
    property Model: string read;
    property MaxContextTokens: Integer read;
    property Store: TSqliteStore read;
    function History: TMessageRecordArray;
    function LastTurn: TTurnRecord;
    function SessionTotals: TTurnRecord;
    function Turns: TTurnRecordArray;
    procedure Close;
  end;
```

`NoLoop` is deleted from the config: the view never builds a loop, and
`THarnessSession` always does.

### `hildegard.helper.harness.session` (trimmed)

The loop side, used only by the runtime. Owns a `TSessionView`; exposes the loop
seam. Uses `harness.view`, `harness.turn`, `harness.turn.worker`, `agent`, `llm`,
`approval`, `approval.store`, `command.tool`, `files`, `recall.tool`, `workspace`,
`store`, `session`, `session.store`.

```pascal
type
  THarnessSession = class
  public
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): THarnessSession;
    destructor Destroy; override;
    property View: TSessionView read;   // identity, store, history, metrics
    property Loop: TAgentLoop read;
    property Tools: TToolRegistry read;
    property Queue: TTurnQueue read;
    property Gate: TApprovalGate read;
    procedure Close;
  end;
```

The runtime reaches the view through `FSession.View` (`View.Store`,
`View.SessionId`, `View.LastTurn`).

### `hildegard.helper.harness.driver` (trimmed) and `.local` (new)

```pascal
{ harness.driver — uses harness.turn, session.client, approval. }
type
  ISessionDriver = interface ... end;   // unchanged
function RemoteDriver(const AConfig: TSessionClientConfig;
  out AError: string): ISessionDriver;

{ harness.driver.local — uses harness.driver, harness.session,
  harness.turn.worker. }
function LocalDriver(ASession: THarnessSession): ISessionDriver;
```

### `hildegard.helper.harness.app` (trimmed)

The app takes a `TSessionView` and an `ISessionDriver`; it no longer uses
`harness.session`. Its `agent`/`llm` uses are dropped if unused (verify).

```pascal
constructor THarnessApp.Create(ASurface: ISurface; AInput: IInputSource;
  ASession: TSessionView; ADriver: ISessionDriver;
  AThemeMode: TThemeMode; ALight: Boolean);
```

### Programs

```pascal
{ examples/headless_agent.pas — the headless agent. }
uses cthreads, cwstring, SysUtils, hildegard.helper.session.runtime;
begin
  Halt(RunSessionRuntime(Args));
end.

{ examples/tui_agent.pas — drops session.runtime and the --session-runtime
  dispatch; sets ClientCfg.RuntimeCommand := ResolveRuntimeBinary(
    GetEnvironmentVariable('HILDEGARD_RUNTIME_BIN'), ParamStr(0)); }
```

## Architecture

### Prior Art & Reuse

Everything exists; the split moves declarations between units. The protocol
(`session.protocol`), the runtime loop, the client, the driver, the app, and the
process spawner are reused unchanged. The only new code is `ResolveRuntimeBinary`
and the two program entry points.

### Component Boundaries

- **Responsibilities:** `session.socket` owns transport; `session.client` owns
  connecting, spawning, and the wire client; `session.runtime` owns serving;
  `harness.view` owns the client's session data; `harness.session` owns the loop.
- **Dependencies:** the client half depends only on the protocol, the socket,
  the store, and `llm`/`approval` types. The server half adds the agent stack.
- **Side effects:** unchanged — the runtime binds a socket and writes the store;
  the client connects and spawns.

### Data Flow

1. **Spawn:** the TUI resolves the runtime binary, the client spawns it detached,
   and connects to the session socket.
2. **Serve:** the runtime binds, registers its row, and serves the wire.
3. **Split:** no data crosses differently than today; only the unit graph
   changes.

### Integration Patterns

- Unchanged: the client reader thread, the runtime's single-threaded `select`
  loop, and the turn worker's queue boundary all stay.
- The `TLocalDriver` path stays in-process for tests and demos.

## Validation Rules

### Input

- `ResolveRuntimeBinary` returns `''` when neither the explicit path nor the
  sibling exists; the caller reports `no runtime binary at <path>`.

### Output Guarantees

- The wire schema and its version are unchanged.
- `TSessionView` and `THarnessSession` open the same store, workspace, and
  session the current `THarnessSession` does.

## Error Handling

- **Missing runtime binary:** the TUI prints a clear error and exits non-zero
  rather than spawning itself.
- **Runtime already live:** unchanged — `bind` fails, the runtime exits 0.
- **Protocol mismatch:** unchanged — the `hello` version check.

## Testing Requirements

### Unit Tests

- [ ] `ResolveRuntimeBinary`: explicit path wins; sibling fallback; `''` when
      neither exists.
- [ ] `TSessionView.Open`: opens store/workspace/session; `History`, `Turns`,
      `LastTurn`, `SessionTotals` return the same as the current
      `THarnessSession`; no LLM client or tool registry is built.
- [ ] `THarnessSession.Open`: builds the loop; `View` is populated; a turn runs
      end to end (the existing harness-session tests, retargeted through
      `View`).
- [ ] `TLocalDriver`: unchanged behaviour from its own unit.

### Integration Tests

- [ ] **Split boundary:** the transitive `uses` closure of the client roots
      (`harness.app`, `harness.driver`, `harness.view`) contains none of
      `agent`, `harness.session`, `harness.turn.worker`, `command.tool`,
      `files`, `recall.tool`, `session.store`, `session.runtime`.
- [ ] The existing runtime/client tests still pass against the split units.
- [ ] The runtime opens a session without calling `History` (no history load).

## Performance Targets

- No change to turn latency or protocol throughput.
- The TUI binary's link closure excludes the agent/tool/runtime units.

## Security Considerations

- The headless agent no longer links terminal input decoding or OSC queries,
  reducing the surface a remote deployment exposes.
- Socket permissions and the runtime directory are unchanged.

## Success Criteria

### Functional

- [ ] All contracts implemented.
- [ ] All tests passing (`make check`), leak-clean.

### Quality

- [ ] The split boundary test fails if a client unit gains a server dependency.
- [ ] Documentation updated (`FEATURES.md`, `HANDOFF.md`).

## Future Considerations

- A `make` target that asserts the boundary as part of `check`.
- Streaming history over the wire, letting the TUI drop its store dependency.
