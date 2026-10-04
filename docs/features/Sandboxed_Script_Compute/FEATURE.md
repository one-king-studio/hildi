# Sandboxed Script Compute

## Overview

Give the agent a **deterministic compute tier**: an in-process, capability-free
JavaScript engine the model can write small scripts for. It sits between
*think* (no side effects) and *act* (the approval-gated shell and file tools),
and it is the only tier where the model can execute code it wrote without the
code being able to touch the machine.

The engine is [GocciaScript](https://github.com/frostney/GocciaScript) — an
MIT, FPC-native ECMAScript runtime built *for* AI-agent hosts, whose capability
model already matches this project's values (deny-by-default, deny-wins,
auditable denials). It is embedded in-process from a pinned source tree and
compiled by the helper's own Free Pascal toolchain.

## Problem Statement

Today the agent can only compute in one of two ways:

- **Token-by-token.** Arithmetic, aggregation, and text transforms over data
  the model already holds are slow and unreliable in a language model.
- **`run_command`.** The usual escape hatch is `python3 -c '…'` — which spawns a
  process and asks the operator to approve model-authored code with *full host
  access*, to do sums. The approval is real, but it is spent on arithmetic.

There is no middle tier: no way to run a model-authored script that is exact,
fast, and *incapable* of reaching the host. This feature adds one.

## Decision

**Committed: GocciaScript, embedded in-process from a pinned source tree, and
compiled with the helper's FPC toolchain.** Not a subprocess, not a
dynamically loaded library, not a second interpreter written here.

Three sub-decisions follow from the research (recorded in Notes):

1. **Capability-free core-only mode.** v1 uses `TGocciaEngine` (the
   core-language API), not `TGocciaRuntime`, and an immutable
   `TGocciaCapabilities.None` set. No runtime extensions, so no `console`,
   `fetch`, `URL`, or `goccia:` modules; no filesystem, network, FFI, or exec.
2. **Source, not artifact.** The engine is vendored as a **pinned git
   submodule** under `deps/` and compiled as part of the helper build. Compiled
   Pascal artifacts are *not* committed — FPC's `.ppu` is compiler-version- and
   flags-locked, and its `.o` files are platform-specific, so a vendored
   "compiled library" would pin the build to one exact compiler and one
   platform and break the project's macOS/Linux portability.
3. **Spike before SPEC.** The integration cost is the open question. The first
   task is a throwaway spike that builds the engine, embeds it, and measures the
   release-binary delta and the build-time cost. If the delta is out of
   proportion to the value, the feature is re-evaluated before any SPEC is
   written.

## Goals

- Add a `run_script` tool that executes a model-authored script with no ambient
  host access, a hard timeout, and bounded output/memory/instructions.
- Make compute deterministic: identical input and script produce identical
  output (no clock, no randomness, no environment).
- Keep the privileged tier unchanged: the shell and file tools remain the only
  way to touch the host, behind their existing approvals.
- Preserve the deployment story: no runtime library is added; the release stays
  a single self-contained binary.
- Keep the dependency surface narrow and pinned, so an engine release cannot
  silently change helper behaviour.

## User Stories

- As an **operator**, I want the model to be able to do exact computation
  without approving `python3 -c` for every sum, so approvals are spent on
  things that touch the machine.
- As an **operator**, I want a model-authored script to be *unable* to read a
  file, open a socket, or spawn a process, so I can allow it as a class.
- As the **agent**, I want a scratchpad that is exact where token arithmetic is
  not — aggregates, checksums, encodings, date math, text transforms.
- As a **reviewer**, I want a script that is the answer — a tokenizer, a state
  machine, a checksum chain — to be persisted and re-runnable, not a wall of
  pseudocode.
- As the **Remote Agent Link designer**, I want the engine's snapshot-in /
  diff-out execution and layered capability model available as prior art for
  the link's request scoping.

## Acceptance Criteria

### Functional Requirements

- [ ] A `run_script` tool is registered and advertised like every other tool
      (required non-empty `reason`; approval-gated as the class `script:run`).
- [ ] Execution is in-process, core-language-only, with
      `TGocciaCapabilities.None`: no filesystem, network, FFI, exec, or
      time-of-day; no runtime globals.
- [ ] Limits are enforced: a wall-clock timeout wired to the existing cancel
      check, an instruction cap, a memory cap, and an output-size cap.
- [ ] The result is structured: standard output, the script's return value, and
      a typed error on failure or timeout — never a crash of the harness.
- [ ] The tool boundary is pure text (the helper's UTF-8 `AnsiString` converts
      explicitly to and from the engine's UTF-16 `string`); no host object
      crosses the boundary.
- [ ] A denied or capped operation surfaces as a script-level error naming the
      capability and scope, never a host path.

### Non-Functional Requirements

- [ ] Portability: builds and runs on macOS and Linux, arm64 and x86-64.
- [ ] Determinism: the same script and input produce the same output across
      runs and platforms.
- [ ] Binary size: the release-binary delta is measured and recorded; the spike
      gates the feature on it.
- [ ] Build time: the clean-build cost of compiling the engine is measured and
      recorded.
- [ ] `make check` passes (functional suite plus the leak gate) with the engine
      in the process; the engine's allocations do not leak.
- [ ] No runtime library is introduced; the release binary remains
      self-contained.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}` for helper units, and keep
  `make check` green.
- The engine is `{$mode delphiunicode}` (UTF-16 `string`); per-unit modes are
  fine, but every value crossing the boundary converts explicitly.
- Vendoring follows the `deps/` pattern: pinned source, no committed compiled
  artifacts, no system-library fallback.
- The engine's public API must be reached through a thin helper facade, so an
  engine upgrade is a facade change and not a sweep of call sites.
- The engine must not be allowed to become a second thing to sandbox: its own
  capability model is the boundary, and v1 grants nothing.

### Business / Time

- No deadline. Sequenced behind the critical path (Remote Agent Link, Session
  Handoff); picked up when a concrete compute need appears.

## Dependencies

### Internal

- `hildegard.helper.agent` — the tool registry and contract (`reason` validation,
  dispatch).
- `hildegard.helper.approval` — the `script:run` ref and the ask/decide flow.
- The turn cancellation seam (`Live Turn Control`) — the timeout rides it.
- `hildegard.helper.llm` — nothing new; the tool result is ordinary text.

### External

- **GocciaScript** (pinned submodule under `deps/goccia`) — the engine. MIT.
- Its generated data resources (Intl / TimeZone / Unicode) — the largest
  binary-size contributor; optionality is an open question for the spike.

## Risks

- **Binary size.** The engine is large: ~286,000 lines across 351 non-test
  units, plus ~2.3 MB of generated data resources (Intl 1.19 MB, TimeZone
  718 KB, Unicode 393 KB). The release delta could be several megabytes against
  a 2.9 MB base. Mitigation: the spike measures it first; the Temporal timezone
  resource is opt-out (`GOCCIA_TEMPORAL_NO_EMBEDDED_TZDATA`); if the delta is
  disproportionate, the feature is re-evaluated.
- **Bus factor.** Two contributors (the author and a bot), 196 open issues, a
  0.x version. Mitigation: pin a version; use a narrow, facade-isolated surface;
  the engine is vendored, so upstream changes only arrive when we choose.
- **Build-time cost.** Compiling ~286k lines into the helper raises clean-build
  time. Mitigation: measure it; a cached precompiled unit directory under
  `build/` is the escape hatch (not committed artifacts).
- **String-mode boundary.** The engine's UTF-16 `string` versus the helper's
  UTF-8 `AnsiString`. Mitigation: a single conversion point in the facade; the
  helper already links `cwstring`.
- **FPC version coupling.** The engine tracks FPC closely. Mitigation: the
  project already pins FPC 3.3.1; the pin and the engine pin move together.
- **Sandbox escape.** A model-authored script must not reach the host.
  Mitigation: core-only `TGocciaEngine`, `TGocciaCapabilities.None`, no runtime
  extensions, no FFI; the engine's deny-by-default model is the boundary and it
  is tested upstream.

## Out of Scope

- Runtime extensions (console, fetch, URL, CSV/TSV/JSONL/JSON5/TOML/YAML
  modules) — v1 is core-only; adopting one is a deliberate, separately-approved
  widening.
- The Remote Agent Link `run script` action — this feature provides the local
  compute tier; the link consumes it later.
- A JavaScript REPL or editor for the operator.
- File or network grants of any kind, in v1.

## Future Considerations

- **Data-format modules** (`goccia:csv`, `goccia:jsonl`, …) if core-only proves
  too bare for real work — each a deliberate capability decision.
- **Snapshot-in / diff-out** (`--copy` / `--copy-rw`): compute the would-be
  changes over a snapshot and apply only what the host asks — composes with
  Approval Path Scoping and is prior art for Remote Link writeback.
- **`run script` over the link**, reusing the same tool and approval class.
- **The engine's capability model** (immutable sets, deny-wins, nested contexts
  only narrow, auditable denials) as a cited reference in the Remote Agent Link
  SPEC's request-scoping design.

## Notes

- **Un-parked** from `FEATURES.md` (it was a one-paragraph "Planned" note). The
  intent and the SPEC requirements in that note carry forward: a hard
  per-execution timeout, a minimal builtin set, in-memory-only module resolution
  (or no imports), output/memory caps, and host-object isolation.
- **Verified research** (against `main`, 2026-10-04). Every load-bearing claim
  was checked in the repository, not taken from a summary:

  | Claim | Verified |
  | --- | --- |
  | Object Pascal, FPC-native, MIT, active | README ("implemented in FreePascal, supports Delphi"); pushed daily; 0.14.0 |
  | Immutable `TGocciaCapabilities`; `None` by default; deny-wins regardless of order; nested contexts only narrow | `docs/permissions.md` |
  | Denials catchable and audited, naming capability and scope, never a host path | `docs/permissions.md` |
  | Sandbox mode: in-memory VFS of snapshots; `--copy` vs `--copy-rw`; `--diff` | README |
  | Core-only `TGocciaEngine` vs runtime-layer `TGocciaRuntime`; `DefineLexicalBinding`; pluggable resolver | `docs/embedding.md` |
  | `test262` on every PR and main commit, with a live dashboard | README |
  | **Not** a single-file amalgamation; no library target; `{$mode delphiunicode}` | source tree; `build.pas`; `source/shared/Shared.inc` |

- **The first task is a spike**, not a SPEC: vendor the engine, build it with
  FPC 3.3.1, embed `TGocciaEngine` core-only, and measure (a) the release-binary
  delta, (b) the clean-build time, (c) whether the Intl/Temporal/Unicode
  resources can be dropped. Record the numbers here and gate the SPEC on them.
- **Reuse note (Ponytail):** the engine is a dependency, not something to
  build; the new work is a facade, a tool, and a build integration. The
  capability model is reused wholesale rather than reimplemented.
