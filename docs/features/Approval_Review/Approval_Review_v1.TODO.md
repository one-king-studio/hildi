# Implementation Plan: Approval Review v1

**Related:** [FEATURE.md](FEATURE.md) · [Approval_Review_v1.SPEC.md](Approval_Review_v1.SPEC.md)

## Implementation Tasks

### Phase 1: redirects are visible and are file effects (shipped)

- [x] The segment summary includes its redirects (`echo x > out.txt`).
- [x] `>`/`>>`/`2>`/`&>` → a `file:write` ask; `<` → `file:read`; here-docs
      and fd duplications skipped; outside targets keep the `path:` ask.
- [x] The file-tool option shapes: once / exact / dir / ext / dir+ext / any /
      never.
- [x] Tests for each of the above.
- [x] The interpreter records the command's expanded `Reads`/`Writes` in
      `TShellCall`; the tier's gate raises the same file asks (so a redirect is
      gated on both executors).
- [x] Pure commands (`echo`, `printf`, `true`, `false`, `basename`, `dirname`)
      raise no command ask; their redirects still ask. The `never` option is
      removed — a persistent deny is a rule, not a prompt choice.

### Phase 2: the full-script review

- [ ] Splitter token spans; `TCommandSegment.Start/Len`; `TApprovalAsk.Script`
      and `FocusStart/FocusLen`; protocol encode/decode (additive).
- [ ] AST spans for the tier's asks.
- [ ] The modal renders the script, scrolls to the focus, and draws the focus
      span in bold.
- [ ] Tests: spans, the modal's scroll offset, the fallback to `Summary`.

### Phase 3: known per-command effects

- [ ] The tier raises file asks for `sed -i`, `tee`, `rm`, `mv`, `cp`, `mkdir`,
      `touch` before running.
- [ ] A denied file ask stops the command before any effect.
- [ ] Tests per command, including `mv` (two targets) and `tee -a`.

### Phase 4: bucketing

- [ ] Group a call's effects by ref/directory/extension; one ask per bucket
      with shared options.
- [ ] Tests for a read bucket, a write bucket, and a mixed batch.

## Success Criteria

- The operator always sees the effect they are approving (redirects included).
- A file-tool grant covers the shell; a shell grant can be as fine as
  "always .log files in build/".
- No shell write happens without a visible ask.
