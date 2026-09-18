# Implementation Plan: Agent CLI v1

**Related Specification:** `Agent_CLI_v1.SPEC.md`

## Tasks

- [x] `hildegard.helper.cli`: `TCLIOptions`, `ParseCLIOptions`, `UsageText`
- [x] `hildegard.helper.transcript`: labelled sections, streaming, token pacing
- [x] `tests/test_cli.pas` (12 tests) and `tests/test_transcript.pas` (10 tests)
- [x] Rewrite `examples/agent_cli.pas`: interactive/once modes, piped stdin,
      flags, exit codes, streaming
- [x] `make agent-cli`
- [x] Verified `--help`, usage errors (exit 2), `.env` loading, plain output

## Outcome

The CLI is a thin adapter over the loop. Output is a pipe-friendly transcript;
`--no-reasoning` / `--no-tools` trim it, `--max-tps` paces it. 117 tests total,
green under `make check`. Live model verification remains a manual step.
