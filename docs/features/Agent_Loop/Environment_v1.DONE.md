# Implementation Plan: Environment File Loading v1

**Related Specification:** `Environment_v1.SPEC.md`

## Tasks

- [x] `src/hildi.env.pas`: `ParseDotEnv` (pure), `ApplyEnv`,
      `LoadDotEnvFile`
- [x] Comments, blank lines, `export ` prefix, whitespace, single/double quotes,
      `=` in values, malformed-line skipping
- [x] Never overrides existing environment variables
- [x] `tests/test_env.pas` with the nine named tests
- [x] CLI loads `./.env` at startup; `.env.example` added; `.env` gitignored

## Outcome

9 tests, green under `make check` (95 total). Verified end-to-end: a throwaway
`.env` supplying the API key is picked up, and the CLI then reports the missing
model rather than the missing key.
