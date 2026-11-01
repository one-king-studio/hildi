# Platform Support

What hildi builds and runs on, what that costs, and the constraints that only
appear on one platform. Anything about the Free Pascal *language* (unicode,
containers, unit reuse) lives in `fpc-gotchas.md`; this file is about
*platforms*.

## Supported platforms

| Platform | Compiler | Gate |
| --- | --- | --- |
| aarch64-darwin (macOS) | FPC 3.3.1 | `make check` verified |
| aarch64-linux (Fedora) | FPC 3.3.1 | `make check` verified |
| x86_64-linux (Fedora) | FPC 3.3.1 | `make check` verified |

"Gate verified" means all four targets pass — `test-parallel`,
`test-leak-parallel`, `shell-standalone`, `markdown-standalone`. Keep this table
honest: a platform is listed only when someone has actually run the gate there,
not when it merely compiles.

Windows is **not supported**; see `windows-portability.md` for the survey of
what a port would cost. It is a backlog, not a promise.

## Getting the compiler

FPC 3.3.1 is required. The 3.2 line does not work: the async core uses the
`reference to` syntax that 3.2 does not have. 3.3.1 is the development line, so
there is no release tarball or distro package; most people build it from source.
`fpcenv` is the quickest path (see the README) and generates a matching
`fpc.cfg`.

Two traps, both from the README and both real:

- **The macOS snapshot is old** (Nov 2023). It works, but its RTL emits warnings
  that `-Sew` promotes to errors during the gate. On macOS, build from source if
  you plan to run `make check`.
- **An existing `~/.fpc.cfg` shadows a new install**, because FPC reads it
  first. That surfaces as `Can't find unit system`. The Makefile derives the
  config from whichever `fpc` is in use, so `make` is fine; invoking `fpc`
  directly needs `-n @~/.fpcenv/current/lib/fpc/etc/fpc.cfg`.

The FPC source tree (for reading RTL/FCL/Packages units) is machine-local and not
recorded in the repo. Set `FPCDIR`, or see `LOCAL_NOTES.md` (gitignored) on a
configured machine.

## Build differences

The Makefile keys off `uname -s`, so there is exactly one branch point:

- **macOS** links `libSystem` unconditionally, which already provides the math
  and compiler-runtime symbols. `SYS_LDFLAGS` is empty.
- **Linux** sets `SYS_LDFLAGS := -k-lm` plus the compiler runtime, because the
  vendored archives have symbols nothing else supplies: `__udivti3` (mbedTLS
  bignum) comes from the compiler runtime, `log` (SQLite FTS5) from `libm`.

Two hard-won details in that branch, both from build failures:

- **Do not hardcode `-lgcc`.** It assumed GCC, and a box with clang and no GCC
  has no `libgcc` at all — it failed with `cannot find -lgcc`. Both pieces are
  resolved through the C compiler actually installed (`-print-libgcc-file-name`)
  and added only if the file exists.
- **`crtbegin.o`/`crtend.o` are GCC-distributed too**, so their directory goes on
  the library path. Without it FPC warns they are missing and the link can fail.

Linker order matters and has been fixed twice: system libraries go **after** the
archives that need them, or the symbols go unresolved.

## Platform-conditional code

A handful of units carry `{$ifdef darwin}` blocks. Each exists for a reason; do
not "clean them up".

- **`sa_len` exists on Darwin only.** `sockaddr_in`/`sockaddr_un` carry a
  length field on macOS and not on Linux, so every `sockaddr` the code fills has
  to set it under `{$ifdef darwin}`. See `HildiSessionSocket.pas` and
  `HildiMCPOAUTHFlow.pas`. Forgetting it produces connects and binds that fail
  with no useful error.
- **`SO_NOSIGPIPE` is a Darwin socket option.** Linux uses `MSG_NOSIGNAL` per
  send instead. `HildiSessionSocket.pas` normalizes this (`SetNoSigPipe`); writing
  to a closed peer must not kill the process with `SIGPIPE` on either platform.
- **`TSemaphore` is unusable on macOS** — `sem_init` returns `ENOSYS`. Use
  `TCriticalSection` + `TSimpleEvent` instead. This is the one that bites hardest,
  because it compiles everywhere and fails only at runtime.
- **`TProcess.ExitStatus` conventions vary** by platform and build. Never read
  the raw value; `HildiProcess.NormalizeExit` normalizes it.

## Verifying a platform

Before adding a platform to the table above:

1. `make deps` — fetch and checksum the vendored libraries.
2. `make check` — all four targets, not just `make test`. The leak pass and the
   isolation checks are where platform differences surface (see
   `testing.md` for what each target covers).
3. `make tui-agent` — launches the UI, which the gate does not exercise. This is
   the only way to catch a rendering or terminal problem.

`make tui-agent` **builds and launches**; in a non-interactive shell it hangs
forever. Use `make build/debug/bin/hildi` to build the TUI without running it.

## Related

- `fpc-gotchas.md` — language and RTL traps (unicode, `TDictionary`, ppu reuse).
- `testing.md` — the gates and what they catch.
- `windows-portability.md` — the unsupported-platform survey.
