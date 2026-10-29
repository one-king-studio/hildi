# Component Specification: Stdio Child Manager v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.session.socket` (framing/`select` helpers).
**Depended on by:** `Mcp_Client_v1.SPEC.md`.

## Purpose

MCP's stdio transport is a **bidirectional** conversation with a child process:
we write framed requests to its stdin and read framed responses from its stdout.
The existing runner (`hildi.process`) cannot serve this — it is
one-shot, stdout-only, and never writes to the child's stdin — and the headless
runtime reaches its child over a detached socket, not pipes. So this is the one
genuinely new low-level piece of v1: a small, synchronous, single-threaded
manager that owns a child's pipes and its lifecycle.

It is deliberately **not** a general process API. It does one thing: hold a
long-lived child, exchange newline-delimited lines with it under a bounded wait,
and tear it down leak-clean.

## Requirements

### Functional

- [ ] Spawn a child with a pipe on stdin (write) and a pipe on stdout (read),
      plus a captured stderr pipe; the executable and its argv come from config.
- [ ] Write one LF-terminated line to the child's stdin; report a broken pipe.
- [ ] Read one LF-terminated line from the child's stdout within a timeout;
      distinguish success, timeout, EOF, over-long line, and error.
- [ ] Drain the child's stderr opportunistically so a chatty server cannot fill
      its stderr buffer and block; expose a bounded tail for diagnostics.
- [ ] Tear down with a **bounded close-then-kill**: close stdin (EOF), wait a
      bounded grace period, then terminate; report a normalized exit code.
- [ ] Be leak-clean under the heaptrc gate, including on every failure path.

### Non-Functional

- [ ] Synchronous and single-threaded: no reader thread, no queue, no join to
      forget. All waits are bounded (`select` with a finite timeout — never a
      `0` busy poll; see `docs/guidelines/tui-rendering.md`).
- [ ] Portable to POSIX (macOS/Linux); the child's stdin/stdout are pipes, not
      sockets.
- [ ] `make check` clean.

## Contracts & Interfaces

### Public API

```pascal
unit hildi.stdio.child;

uses
  SysUtils;

type
  { Why a ReadLine call returned False. }
  TStdioReadResult = (srOk, srTimeout, srEof, srTooLong, srError);

  TStdioChildConfig = record
    Executable: string;        // resolved path or PATH name
    Args: array of string;     // exact argv after the executable
    Env: array of string;      // optional 'NAME=VALUE' additions; nil = inherit
    WorkingDir: string;        // '' => current directory
    ReadTimeoutMs: Integer;    // 0 => DefaultStdioReadTimeoutMs
    CloseTimeoutMs: Integer;   // bounded close-then-kill grace; 0 => default
    MaxLineBytes: Integer;     // reject a longer line; 0 => default
    MaxStderrBytes: Integer;   // bound on the retained stderr tail; 0 => default
  end;

  TStdioChild = class
  public
    constructor Create(const AConfig: TStdioChildConfig);
    destructor Destroy; override;

    { Spawn the child with both pipes. False + AError on failure. Idempotent. }
    function Start(out AError: string): Boolean;

    { Write one line to the child's stdin, appending LF. False + AError when
      the pipe is closed (the child has exited). }
    function WriteLine(const ALine: string; out AError: string): Boolean;

    { Read one line from stdout within ATimeoutMs. Returns True (srOk) or False
      with AReason set. ALine excludes the trailing LF (and a preceding CR). }
    function ReadLine(out ALine: string; ATimeoutMs: Integer;
      out AReason: TStdioReadResult): Boolean;

    { True while the child has not been observed to exit. }
    function Alive: Boolean;

    { The last-observed exit code, NormalizeExit'd. Valid after an exit. }
    function ExitCode: Integer;

    { The retained stderr tail (bounded by MaxStderrBytes). }
    function StderrTail: string;

    { Close stdin, wait CloseTimeoutMs, then kill. Idempotent; safe in Destroy. }
    procedure Close;
  end;

const
  DefaultStdioReadTimeoutMs = 30000;
  DefaultStdioCloseTimeoutMs = 2000;
  DefaultStdioMaxLineBytes = 1 shl 20;      // 1 MiB — MCP lines are far smaller
  DefaultStdioMaxStderrBytes = 64 shl 10;   // 64 KiB retained for diagnostics
```

### Data Contracts

- **Line framing.** Lines are LF-delimited; a trailing CR is stripped (mirrors
  `ExtractLine`). The manager never returns a partial line on timeout — the
  in-progress buffer is retained across calls.
- **`MaxLineBytes`.** A line exceeding the cap is `srTooLong` and the child is
  considered failed by the caller (the client drops that server). This is the
  DoS guard the codec's fuzz-resistance relies on.
- **stderr.** Never parsed. Captured into a bounded ring; the tail is surfaced
  for a session event when a server fails.
- **Exit codes.** Reuse the project convention (`0` ok, `124` timeout,
  `128+signal`, `130` cancelled) via `NormalizeExit`.

### Event Contracts

- None. The manager is polled; there is no callback and no background thread.

## Architecture

### Prior Art & Reuse

- **Reuse (rung 2):** `ExtractLine` (pure line splitter), `WaitReadable`
  (single-fd `select`), and `NowMs` from `hildi.session.socket`.
  `WaitReadable` works on a pipe fd exactly as on a socket fd.
- **Do not reuse:** `ReadLineTimeout`/`SendAll`/`Recv` from that unit — they
  call `fpRecv`/`fpSend`, which fail with `ENOTSOCK` on a pipe. This component
  needs a pipe analogue that uses `fpRead`/`fpWrite` and mirrors their shape.
- **Reuse (rung 3):** `TProcess` (`Process`) with `poUsePipes`, and the
  `TProcess.Input`/`Output`/`Stderr` handles for the three fds.
- **Promote, don't duplicate:** `NormalizeExit` is currently file-local in
  `hildi.process`. v1 **exports it in place** (move its signature to
  that unit's interface section); this manager adds
  `uses hildi.process` and reuses it rather than copying the mapping.
  (Decision A: smallest diff, no new unit for one function.)
- **Genuine gap:** bidirectional pipe I/O with bounded reads and a bounded
  close-then-kill. Nothing in `src/` provides it.

### Component Boundaries

- **Responsibilities:** child spawn, pipe ownership, framed line I/O, stderr
  capture, bounded teardown, exit-code normalization.
- **Dependencies:** `hildi.session.socket` (helpers),
  `hildi.process` (`NormalizeExit`), `Process`, `BaseUnix`.
- **Side effects:** creates a process; owns three fds; reaps the child.

### Data Flow

1. `Start` spawns the child with `poUsePipes`, capturing the three handles.
2. `WriteLine` writes a codec-produced line to stdin.
3. `ReadLine` selects on stdout (and stderr, to drain it) with a finite
   timeout, accumulates bytes, and emits a line when `ExtractLine` finds LF.
4. `Close` closes stdin, waits `CloseTimeoutMs`, then `Terminate`s; `WaitOnExit`
   and `NormalizeExit` give the code.

### Integration Patterns

- **Synchronous, single-threaded.** The MCP client drives it on the loop's
  thread during tool dispatch. This is the Ponytail choice: no reader thread
  means no shared state, no lock, and nothing to join. Ceiling noted below.
- **Lifetime.** The manager owns the `TProcess` and every buffer; `Destroy`
  calls `Close`. The client owns the manager.

## Validation Rules

### Input

- `Executable` non-empty (config guarantees this); `Args` copied into `TProcess`.
- `ReadTimeoutMs`/`CloseTimeoutMs` `<= 0` take the documented defaults.
- `WriteLine` refuses a line containing an embedded LF (the caller's codec never
  emits one; a guard keeps a stray newline from desynchronizing the stream).

### Output Guarantees

- A successful `ReadLine` is exactly one wire line, LF/CR stripped.
- `ReadLine` never blocks past `ATimeoutMs`.
- `Close` always leaves the child reaped and all fds closed.

## Error Handling

- **Spawn failure** (`ENOENT`, permission): `Start` = False + `AError`; no
  partial state (fds closed, process freed).
- **Timeout:** `srTimeout`; the caller decides whether to retry or drop the
  server. There is no automatic retry here.
- **EOF** (child closed stdout / exited): `srEof`; the caller marks the server
  failed and unregisters its tools.
- **Over-long line:** `srTooLong`; treated as a protocol failure.
- **Broken pipe on write:** `srError` + `AError`; the caller drops the server.
- **Teardown:** a child that ignores the stdin EOF is killed after the grace
  period; `Close` is idempotent and never raises.

## Testing Requirements

### Unit Tests (`tests/test_stdio_child.pas`)

- [ ] A scripted fake child (a shell script or a tiny helper) echoes a written
      line back; `WriteLine` then `ReadLine` round-trips it.
- [ ] `ReadLine` on a silent child returns `srTimeout` within the bound (assert
      "returned", not exact timing).
- [ ] A child that exits closes stdout ⇒ `srEof`, and `ExitCode` is normalized.
- [ ] A child that never reads stdin and exits ⇒ `WriteLine` reports the broken
      pipe without raising.
- [ ] A line longer than `MaxLineBytes` ⇒ `srTooLong`.
- [ ] A child writing to stderr does not block stdout reads; `StderrTail`
      returns the captured text.
- [ ] `Close` on a live, non-cooperative child kills it within
      `CloseTimeoutMs` and reaps it (no zombie).
- [ ] Every case is leak-clean under `make test-leak`.

### Integration Tests

- [ ] Exercised end-to-end by `Mcp_Client`'s fake-server lifecycle tests.

## Performance Targets

- Line I/O is O(line length); the read path does one `select` per available
  chunk, never a busy poll.
- Startup is bounded by the client's initialize timeout, not by this unit.

## Security Considerations

- The child is operator-configured, but its **stdout is untrusted**: the line
  cap bounds memory, and no output is interpreted here.
- stdin is closed on teardown so the child sees EOF before any kill.
- No shell is involved — the executable and argv are passed directly to
  `TProcess`, so config values are not re-parsed by a shell.

## Success Criteria

### Functional

- [ ] Bidirectional framed I/O works against a real child over pipes.
- [ ] Bounded close-then-kill leaves no zombie and no leak.
- [ ] `make check` passes.

### Quality

- [ ] No leaks under the heaptrc gate, including failure paths.
- [ ] Reuses `ExtractLine`/`WaitReadable`/`NormalizeExit`; duplicates none.

## Future Considerations

- **Ceiling (deliberate).** Synchronous reads mean a server that floods
  unrelated notifications between our request and its response delays the
  response by one `ReadLine` iteration each. Bounded by `MaxLineBytes` and the
  timeout; upgrade to a reader thread + queue only if a real server misbehaves.
- **Windows** (out of scope, see `docs/guidelines/windows-portability.md`)
  needs `PeekNamedPipe`/`WaitForMultipleObjects` here.
