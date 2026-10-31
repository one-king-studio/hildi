# Hildi

A small, portable coding agent written in Free Pascal.

Most coding agents ship as Node, Python, or Rust applications that carry a
runtime, a package manager, and 100–250 MB of idle overhead before they do any
work. Hildi takes the opposite constraint: a compiled binary measured in
single-digit megabytes, no language runtime to install, and a dependency surface
small enough to audit in an afternoon.

Vendored dependencies (SQLite, mbedTLS, the CA bundle) are linked statically, so
there is no package to fetch at run time and no version to keep in sync. The
platform C library — `libSystem` on macOS, glibc and `libm` on Linux — is the
only dynamic dependency, and every platform provides it.

The design follows the Delphi-era distribution ethos — compile once, ship one
artifact, run anywhere — applied to a problem that has drifted away from it.

> **Status: pre-1.0, actively developed.** Interfaces, storage layout, and CLI
> flags will change. Pin a commit if you build on this.

## What it does

Hildi is an agent harness with an approval gate. It turns natural-language
instructions into shell commands and file operations, and shows you exactly what
it proposes to do before it does it.

- **A terminal UI** (`hildi`) — conversation view, streaming markdown, an
  approval modal that groups and scopes what it asks for.
- **A headless runtime** (`hildi-agent`) — the agent loop and tools, driving a
  session over a local socket.
- **A gated shell** — 55+ builtin commands classified by effect, so a read stays
  read-only and a write is visibly a write.
- **A local store** — SQLite sessions, messages, approvals, and a change log that
  supports reverting a turn.

## Why it exists

Three things motivated it, in order:

1. **Distribution.** An agent that needs `npm install` cannot run in an air-gapped
   environment, a minimal container, or on a device where you cannot install a
   runtime. A single binary you can copy, hash, and run can.
2. **Auditability.** Every dependency is either in the standard library, vendored
   and checksummed by a fetch script, or absent. There is no transitive tree to
   trust.
3. **Honest gating.** The approval dialog shows the command it will run and how
   broad the grant is, rather than asking you to trust a category.

## Who it's for

- Developers running agents on constrained hardware — Raspberry Pi, edge devices,
  small containers.
- Air-gapped and offline environments where a package manager is not an option.
- Anyone who wants to read the whole thing and know what it does.

## What it isn't

Not a feature-complete replacement for Claude Code or Codex CLI, and it does not
try to be. It is a deliberately minimal harness that prioritises distribution
properties the mainstream ecosystem has largely abandoned.

## Build

Requires Free Pascal (**3.3.1 today**; a move to the stable 3.2 line is planned)
and a C toolchain for the vendored libraries.

```sh
make deps          # fetch and checksum sqlite, mbedtls, and a CA bundle
make check         # build, then run the full suite plus the leak gate
make tui-agent     # build and launch the terminal UI
```

Artifacts land in `build/bin/`. `hildi` and `hildi-agent` are expected to sit
side by side: the UI resolves the runtime as a sibling of its own executable, or
from `HILDI_RUNTIME_BIN`.

## Configuration

| Variable | Purpose |
| --- | --- |
| `HILDI_LLM_MODEL` | Model identifier |
| `HILDI_LLM_API_KEY` | API key (or `FIREWORKS_API_KEY`) |
| `HILDI_LLM_ENDPOINT` | OpenAI-compatible endpoint |
| `HILDI_STORE_PATH` | Session database location |
| `HILDI_RUNTIME_BIN` | Headless runtime to spawn |
| `HILDI_MAX_CONTEXT_TOKENS` | Override the loop's context guard |

The store defaults to `$XDG_DATA_HOME/hildi/store.db`, i.e.
`~/.local/share/hildi/store.db`. Older locations (`~/.hildi`,
`~/.hildegard-helper`) are still read when the new one is absent, so an upgrade
never presents an empty database as a lost history.

`HILDEGARD_*` spellings are accepted as deprecated aliases.

## Documentation

`docs/` is the source of truth for what exists, what is specified, and what was
tried and rejected:

- [`docs/features/FEATURES.md`](docs/features/FEATURES.md) — the feature index,
  with a verified status per feature.
- `docs/features/<Feature>/` — the artifact chain: `FEATURE.md` → `SPEC.md` →
  `TODO.md` → `DONE.md`.
- `docs/research/` — investigations, including post-mortems of things that did
  not work and why.
- [`AGENTS.md`](AGENTS.md) — the rulebook this project is developed under.

The project is developed spec-first and test-driven by a mix of humans and
agents; the documentation is the record of that process rather than a marketing
surface.

## Contributing

**Not accepting pull requests yet** while the interfaces settle. Forks are
welcome — that is what the licence is for. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

MIT — see [`LICENSE`](LICENSE). Copyright © 2026 One King Studio, LLC.
