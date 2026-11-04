# Implementation Plan: LLM Request Parameters v1

**Spec:** [LLM_Request_Parameters_v1.SPEC.md](LLM_Request_Parameters_v1.SPEC.md)
**Feature:** [FEATURE.md](FEATURE.md) — Stage 1 of 5
**Branch:** `agent/llm-params` in `.worktrees/llm-params`

## Phase 1 — Contract (no behaviour change)

- [ ] `src/HildiLLM.pas`: add `TLLMParam` and the seven parameter fields to
      `TLLMConfig`, all defaulting to unset.
      Files: `src/HildiLLM.pas`
      Done when: the tree compiles and the whole existing suite is still green,
      proving the new fields changed nothing.

## Phase 2 — Resolution

- [ ] `ResolveLLMConfig` fills an unset field from its `HILDI_LLM_*` variable,
      via `GetEnvLegacy`, never overwriting a field the caller already set.
      Files: `src/HildiLLM.pas`
- [ ] An unparseable or out-of-range value fails with `leConfig`, naming the
      variable, before any I/O. Not clamped.
      Files: `src/HildiLLM.pas`
- [ ] `HILDI_LLM_STOP` splits on commas and drops empty segments.

## Phase 3 — Serialisation

- [ ] `BuildRequestBody` emits each set parameter, after `stream_options` and
      before `messages`, with the provider's JSON type.
      Files: `src/HildiLLM.pas`
      Done when: every key is absent when its field is unset.

## Phase 4 — Momentum

- [ ] `tests/TestLLM.pas`: the parameter tests.
      Tests:
      - `TestNoParameterKeysByDefault` — the byte-identity guard
      - `TestTemperatureZeroIsSent` — tri-state, not a sentinel
      - `TestEachNumericParameterIsSerialised` — key and JSON type, one each
      - `TestStopBecomesAnArray` / `TestEmptyStopIsOmitted`
      - `TestUnparseableValueIsAConfigError` — code, variable named
      - `TestOutOfRangeValueIsRejectedNotClamped`
      - `TestLegacyEnvSpellingIsHonoured` / `TestNewEnvSpellingWins`
      - `TestExplicitConfigIsNotOverwrittenByTheEnvironment`
- [ ] `docs/features/FEATURES.md`: add the Provider Configuration row.
      **Integrator-owned** (`source-control.md`): agents do not edit it. Hand the
      row to the integrator at merge time; the proposed row is:

      `| [Provider Configuration](Provider_Configuration/FEATURE.md) | Specified | LLM Request Parameters v1 | … |`

      Files: `docs/features/FEATURES.md` (integrator, not this lane)

## Phase 5 — Gate

- [ ] `make check` green: 2,177+ tests, 0 failures, leak-clean.
- [ ] `AGENTS.md` needs no change (no new command, no new unit).

## Notes / deviations

- **`ResolveLLMConfig` becomes fallible, so this is not a two-file change.**
  The SPEC's contract is `function ResolveLLMConfig(const AConfig: TLLMConfig;
  out AError: string): Boolean`, because a value present but unparseable must be
  reported rather than silently coerced. That changes seven call sites:

  | Call site | Change |
  | --- | --- |
  | `src/HildiLLM.pas:836` (`TLLMClient.Create`) | a constructor cannot return an error: carry it as a field and surface it from `Complete`, which already has an `out AError: TLLMError` |
  | `src/HildiHarnessSession.pas:1639` | propagate as a session init failure |
  | `src/HildiHarnessView.pas:228` | display-only path: keep the last good value, surface the error in the view |
  | `examples/agent_cli.pas:1057` | report and exit non-zero |
  | `tests/TestLLM.pas:184,199` | assert `True` |
  | `tests/SmokeRunner.pas:9` | comment only |

  A simpler alternative — keep `ResolveLLMConfig` total and add a separate
  `ValidateLLMConfig(const AConfig): TLLMError` that `Complete` calls after
  resolution — is fewer edits and no constructor-state. The SPEC allows either;
  the contract that matters is that a bad value fails with `leConfig` before any
  I/O. **Prefer the validation function** unless a caller needs the value at
  construction time (the TUI display path does want it, but it can tolerate a
  best-effort read).

- **`stop` shape.** OpenAI accepts a string or an array. The SPEC pins an array,
  which every OpenAI-compatible endpoint accepts and which avoids the
  ambiguity of a single stop containing a comma.
- **Range checks are our policy, not the provider's.** The ranges in the SPEC are
  the documented OpenAI ones. Rejecting rather than clamping is deliberate: a
  value the operator did not ask for is a silent behaviour change.
- **Not in v1:** any CLI flag, any protocol change, any store change. The
  environment is the only source, which keeps this slice to two files plus tests.
- **Sequencing.** Stages 2–5 each need their own SPEC. Stage 2 is blocked on a
  migration number (main is at 21, the MCP lane holds 22, so provider tables
  start at 23).
