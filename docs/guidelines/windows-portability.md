# Windows Portability

> **Status: not supported.** The project targets macOS and Linux. Nothing has
> been built or run on Windows, and there is no Windows CI; everything below is
> a survey from static analysis. Treat it as a backlog, not a promise — keep it
> current when platform code is added.

## Why this exists

The deployment story is "copy one self-contained binary to a device". If a
device could be Windows, the port matters; if not, it does not. This note records
what a port would cost so the decision can be made deliberately rather than
discovered late. It also fixes the two decisions that are expensive to change
later: the **TUI terminal adapter** and the **Headless Sessions transport**.

## What is already in your favour

- FPC is fully Windows-capable (`win32` / `win64` targets).
- `cthreads` and `cwstring` are `{$ifdef unix}`-guarded in every program header,
  so Windows programs link nothing extra.
- The TUI toolkit is **terminal-free by design** — `video` and the termios
  adapter live in two units, behind `ISurface` / `IInputSource`. Porting the TUI
  is writing one adapter, not touching the widgets.
- No `TSemaphore` (the macOS trap is already avoided; critical section + event).
- `{$else}` branches already exist for `chmod` (`store.pas`) and `setenv`
  (`env.pas`) — the pattern is established.
- `TProcess` already has `poDetached`, so a detached child is cross-platform.

## The survey

Only **8 of 53** `src` units touch a Unix-only API, and **zero** units contain
any Windows `ifdef`.

### Portable as-is (pure logic, no platform)

Local SQLite Store (schema + ledger), Tool Approvals, Approval Path Scoping,
Workspaces (bar one check), Sessions and Ledger, Context Budget, Response
Continuation, Live Turn Control, File Tools, the agent loop, Markdown, syntax
highlighting, TUI widgets / layout / text / scroll / encoder / decode /
animation / text editing / clipboard.

### Needs a small shim

| Where | Unix | Windows |
| --- | --- | --- |
| `hildi.ansi` | `isatty(1)` | `_isatty` |
| `hildi.env` | `setenv` | `SetEnvironmentVariable` |
| `hildi.workspace` | `fpAccess` | an access check |
| `hildi.store` | `fpChmod` (already no-op'd) | — |
| build | static `libsqlite3.a`, `libmbedtls.a` | mingw `.a` or MSVC `.lib` |

### Needs a real rewrite

1. **TUI terminal adapters** — `tui.input.terminal.pas` (termios, `TIOCGWINSZ`,
   `isatty`, `tcflush`, `/dev/tty`, `SIGTERM`/`SIGINT`/`SIGHUP`) and
   `tui.surface.video.pas` (`fpioctl`). Windows needs
   `SetConsoleMode` / `ReadConsoleInput` / `GetConsoleScreenBufferInfo`.
   `video` already supports Windows, so the surface half is the easier part.
2. **TLS C shim** — `src/hildi_tls_shim.c` uses `sys/socket.h`, `send`/`recv`,
   `errno`, `SO_NOSIGPIPE`. Windows needs `winsock2.h`, `WSAStartup`,
   `WSAGetLastError`, and no SIGPIPE (there isn't one). `tests/tls_test_server.c`
   is worse (`arpa/inet.h`, `pthread.h`, `signal.h`, `unistd.h`).
3. **Command tool streaming** — `hildi.process.pas` uses `fpSelect` in
   `WaitReadable` and `poNewProcessGroup`. Windows needs
   `WaitForMultipleObjects` / `PeekNamedPipe` and `CREATE_NEW_PROCESS_GROUP`.
4. **Headless Sessions transport** — see below; this is the one to decide early.
5. **The build** — the Makefile keys off `uname -s`, uses `-fPIC`,
   `-mmacosx-version-min`, and `-k<abs path>` for static `.a` archives.

## Headless Sessions: transport options

The v1 spec uses `AF_UNIX`. That is fine on macOS and Linux, but **FPC does not
expose AF_UNIX on Windows**: `TUnixSocket`/`TUnixServer` are `{$ifdef Unix}` in
`ssockets.pp`, and `AF_UNIX` is not declared in the Windows RTL. (The OS supports
it since Win10 1803, but the RTL does not.)

| Option | Unix | Windows | Local access control | Cost |
| --- | --- | --- | --- | --- |
| **AF_UNIX** | native | not in FPC | filesystem `0700`, free | v1 |
| **Named pipes** | — (FIFOs ≠ named pipes) | native | pipe ACL, free | two implementations |
| **TCP loopback** | yes | yes | none — needs a token | one implementation, portable |
| **WebSocket over TCP** | yes | yes (FPC `fcl-web`) | none — needs a token | one impl + an HTTP layer |
| **Store-backed feed (poll)** | yes | yes | SQLite file perms | portable, high latency |

**Decision (v1): AF_UNIX, Unix only. Windows is deferred.** The protocol is
transport-agnostic by design — the schema is separate from the envelope and the
transport — so this is a binding choice, not a schema change.

**When Windows matters**, pick one:

- **TCP loopback + a per-session token** — one implementation for all platforms.
  The `hello` handshake already verifies the session id; add a token to guard
  access. Simplest path to Windows.
- **AF_UNIX on Unix + named pipes on Windows** — best per-platform security, but
  two implementations and a Win32 binding.
- **WebSocket** — the right binding for a **web client** and the **network link**
  (FPC ships `fpwebsocketclient` / `fpwebsocketserver`); it rides TCP, so it is
  cross-platform, but it is an application protocol and needs a token for local
  access. Add it when those clients arrive, over the same schema.

## If Windows becomes a target

Suggested order, cheapest first:

1. The small shims (`isatty`, `setenv`, workspace access).
2. The build path (mingw, static SQLite + mbedTLS).
3. The TLS shim (Winsock) and the test server.
4. The command tool's streaming/timeout path.
5. The Headless Sessions transport (whichever option above).
6. The TUI console adapter, validated in ConHost and Windows Terminal.

**Constraints to accept up front:** it needs a real Windows machine and CI; the
terminal assumptions (kitty keyboard protocol, OSC 52, SGR mouse) differ; and
none of this is trustworthy without calibration on the platform.

## Decisions recorded

- **Windows is out of scope for v1 of every feature.** Several FEATUREs already
  say so (TLS Foundation, Session Handoff).
- **Headless Sessions ships AF_UNIX only.** The transport is a seam; Windows is a
  later binding.
- **Nothing here changes until Windows is a real target** — this note exists so
  the two expensive decisions (TUI adapter, session transport) are made
  deliberately, not by accident.
