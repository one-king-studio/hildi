# Component Specification: Live Smoke v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.session.runtime` (the spawned program),
`hildi.session.client`, `hildi.session.protocol`,
`hildi.store`.

**Depended on by:** nothing (a verification harness).

## Purpose

Two programs: a **fake provider** (a tiny loopback SSE server) and a **scenario
runner** that spawns the real headless runtime against it, attaches a real socket
client, drives a turn, and asserts on both the wire and the disk.

The point is not to test more code. It is to test the *seams the unit suite
injects away*: real HTTP, a real `exec`, a real detached process, a real socket,
a real store written by another process.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| An OpenAI-compatible SSE frame builder | `tests/llm_fakes.pas` (`TextDelta`, `ToolNameFrame`, `ToolArgsFrame`, `FinishFrame`, `UsageFrame`, `DoneFrame`) | **reuse** — the fake provider replays the same bytes over a socket |
| A loopback server | `tests/tls_test_server.c` (HTTP + TLS, linked into the suite) | reuse the shape: a real server, compiled in, not a mock |
| Spawn + attach | `TLS…` no; `tests/test_session_runtime.pas:TestSpawnAndAttach` | reuse the idea, but spawn explicitly (see below) |
| Wire assertions | `TRecordingSink` (same unit) | copy the idea into the runner |
| The runtime itself | `RunSessionRuntime` | **unchanged** — the smoke runs the shipped program |

The genuinely new work: the loopback provider, the scenario runner, and the
`make smoke` target.

## Requirements

### Functional

- [ ] `TFakeProvider` binds `127.0.0.1:0`, reports its port, serves
      `POST /v1/chat/completions`, and streams a scenario's frames with a short
      delay between them so the client observes genuine incremental delivery.
- [ ] A scenario is a list of frames plus optional per-request overrides (a
      second request gets a different script — used for the tool round trip).
- [ ] The provider records every request body, in order, for assertion.
- [ ] `TSmokeRunner` spawns the runtime binary explicitly with
      `--session-runtime <id> --workspace <ws> --store <db> --endpoint <url>
      --model <m> --idle-ms <n>`, waits for the socket with a deadline, then
      attaches with `Spawn := False`.
- [ ] Each scenario is a named function returning pass/fail plus a diagnostic;
      the runner executes the selected set and exits non-zero on any failure.
- [ ] Cleanup in a `finally`: terminate the runtime, remove the socket, delete the
      temp dir. Verified by an assertion at the end of every run.
- [ ] `--scenario <name>` selects one; the default runs all.
- [ ] `--list` prints the scenario names (so `make smoke` failures are
      reproducible by name).

### Non-Functional

- [ ] No new dependency: `BaseUnix`/`Sockets` plus `fpjson` only.
- [ ] No fcl-web: the provider must stream, and `fphttpserver` buffers.
- [ ] Total default wall time under ~5 s; every wait is a deadline.
- [ ] Port 0 only (no fixed ports).
- [ ] macOS + Linux; FPC 3.3.1.
- [ ] Not part of `make check` (it forks); a separate `make smoke` target. It may
      be added to `check` later as a third gate once it is proven stable.

## Contracts & Interfaces

```pascal
unit smoke_provider;
{ A loopback OpenAI-compatible SSE server. Streams a scenario's frames, one
  request at a time, and records what it was sent. }

type
  { One request's script: the frames to replay, in order. }
  TFakeScript = record
    Frames: array of RawByteString;
    StatusCode: Integer;        // 0 => 200
    FrameDelayMs: Integer;      // 0 => ~15 ms
  end;

  TFakeProvider = class
  public
    constructor Create;
    destructor Destroy; override;
    { Bind on 127.0.0.1:0. Call before spawning the runtime. }
    function Start(out AError: string): Boolean;
    function Port: Word;
    function EndpointUrl: string;          // 'http://127.0.0.1:<port>/v1/chat/completions'
    { Append the next request's script. The last one repeats. }
    procedure Script(const AScript: TFakeScript);
    { The bodies received so far, in order (a copy). }
    function RequestBodies: TStringArray;
    function RequestCount: Integer;
    procedure Stop;
  end;

{ Frame builders copied from the harness's own fake (same JSON shape the client
  parses): a scenario is written in these, so a change on one side breaks the
  same way on both. }
function SSE(const AJson: string): RawByteString;
function TextDelta(const AText: string): RawByteString;
function ToolNameFrame(AIndex: Integer; const AId, AName: string): RawByteString;
function ToolArgsFrame(AIndex: Integer; const AArgs: string): RawByteString;
function FinishFrame(const AReason: string): RawByteString;
function DoneFrame: RawByteString;
```

```pascal
unit smoke_runner;
{ Drives the real runtime through a scenario and reports a structural result. }

type
  TSmokeOutcome = record
    Ok: Boolean;
    Stage: string;        // 'spawn' | 'attach' | 'turn' | 'gate' | 'store' | ...
    Detail: string;
  end;

  TSmokeScenario = function(const AHost: TSmokeHost): TSmokeOutcome;

  TSmokeHost = class
  public
    Provider: TFakeProvider;
    Workspace: string;
    StorePath: string;
    SessionId: string;
    RuntimePid: Integer;
    { Spawn, attach, and expose the client + the recorded events. }
    function StartRuntime(out AError: string): Boolean;
    function Client: TSessionClient;
    function Events: TSessionEventArray;   // recorded by the sink
    { Poll until a predicate holds or the deadline passes. }
    function WaitFor(APred: TSessionPredicate; ATimeoutMs: Integer;
      const AWhat: string): Boolean;
  end;

function RunScenario(const AName: string): TSmokeOutcome;
function ScenarioNames: TStringArray;
```

## Architecture

### Why the runner spawns the runtime itself

`TSessionClient.Open(Spawn := True)` calls `SpawnDetached`, which passes
`--session-runtime`, `--workspace`, `--store`, `--approval-root` and `--idle-ms`
— **not `--endpoint` and not `--model`**. And `ResolveLLMConfig` reads
`HILDI_LLM_MODEL` and `HILDI_LLM_API_KEY` from the environment but
**never reads an endpoint variable**, although `hildi.cli`'s help text
advertises `HILDI_LLM_ENDPOINT`. So a spawned runtime cannot be aimed at a
local provider by any supported route today.

Two consequences, both recorded rather than papered over:

1. The smoke spawns with an explicit argv (its own `TProcess`, not
   `SpawnDetached`), which is also a better test — it pins the argv the product
   documents.
2. **This is a real product gap**: `HILDI_LLM_ENDPOINT` is documented and
   ignored, and `SpawnDetached` drops `--endpoint`/`--model`. File it separately;
   the smoke must not depend on the fix, or it cannot land first.

### Why not `fphttpserver`

`TFPHTTPConnectionResponse` buffers `Content` and writes it at the end of the
request, so a scenario could not observe *incremental* deltas — the streaming
path would be tested as a single chunk, which is the one thing the unit tests
already do. A small raw-socket server is ~120 lines and streams honestly.

`ponytail:` a hand-rolled HTTP/1.1 request parser, ceiling: one request per
connection, no chunked encoding, no keep-alive, `Content-Length` only. Upgrade
path: `fphttpserver` the day it can flush.

### Scenarios (v1 set)

| Scenario | Asserts | Closes |
| --- | --- | --- |
| `text` | a plain turn streams delta-by-delta, finishes once, persists one assistant message | Agent Loop |
| `tool` | the model asks for `file_write`; `ekApprovalRequest` carries the tool's `reason`; approve; `ekToolResult` carries the write result; the file is on disk with the expected bytes | File Tools, Tool Approvals |
| `denied` | a denial reaches the model as a tool-level denial and the turn **continues** to a finish (not a hang) | Tool Approvals |
| `resume` | after `tool`, re-attach and assert the ledger renders the same user text, tool call and result | Sessions and Ledger, Headless Sessions |
| `introspect` | the request body contains the tool schemas and every advertised tool has a non-empty `reason` property | Tool Approvals (the reason requirement) |

The `introspect` scenario is the cheapest way to prove the *prompt* is
well-formed, which no unit test asserts end to end.

## Validation and error handling

- A stage failure names the stage and the last events received, e.g.
  `turn: no ekTurnFinished within 8000 ms; last events: ekTextDelta×12,
  ekToolCall`.
- The provider returns a 4xx script and the client reports a provider error — a
  scenario asserts the error is legible (the Error Surfacing claim), and it is
  skipped if that feature has not landed.
- A hung runtime is killed after the scenario deadline (terminate, then kill),
  and the outcome is `stage = 'turn', detail = 'timeout'`.

## Testing Requirements

The smoke *is* a test, so its own correctness rests on:

- [ ] Each scenario asserts at least one **negative** (a specific event *absent*,
      or an exact count), so a scenario cannot pass by accident.
- [ ] `make smoke` exits non-zero when a scenario fails — verified once by
      temporarily asserting a falsehood.
- [ ] A deliberately broken endpoint (a closed port) fails at `attach` with a
      named stage, not a hang.
