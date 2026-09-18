# Implementation Plan: ANSI Terminal Styling v1

**Related Specification:** `ANSI_v1.SPEC.md`

## Tasks

- [x] `src/hildegard.helper.ansi.pas`: `TAnsiColor`, named palette, `AnsiFg`,
      `AnsiReset`, `AnsiBold`, `AnsiDim`, `AnsiStyled`, `AnsiEnabled`,
      `AnsiSetEnabled`
- [x] Auto-detection: TTY + `TERM<>dumb` + `NO_COLOR` unset, via libc `isatty`
- [x] `tests/test_ansi.pas` with the six named tests
- [x] Wire `test_ansi` into the runner

## Outcome

6 tests, green under `make check`. Disabled mode returns text unchanged, so the
suite and piped output are unaffected.
