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

### Phase 2: the full-script review (shipped)

- [x] Splitter token spans; `TCommandSegment.Start/Len`; `TApprovalAsk.Script`
      and `FocusStart/FocusLen`; protocol encode/decode (additive).
- [x] AST spans for the tier's asks: the lexer's `EndOffset`, the parser's
      simple-command span, `TShellCall.Start/Len`.
- [x] The modal renders the script (8-row band), scrolls to the focus, and
      draws the focus span in bold with a `→` marker; PageUp/PageDown and the
      wheel scroll.
- [x] An effect ask keeps its summary line above the script (the path is what
      is approved).
- [x] Tests: spans (splitter, parser, tier, protocol), the modal's focus
      highlight, the scroll offset and the scroll keys, the fallback to
      `Summary`.

### Phase 3: the effect-scoped gate (tier shipped; process path decided)

- [x] `shell.effects`: per-command reads/writes from the expanded arguments.
- [x] The tier asks effects as `file:read`/`file:write`; the command ask only
      when the effects are unknown.
- [x] Tests in `test_shell_effects`; the tier's asks assert file refs.
- [x] **Decision: the process path keeps its command asks.** In bash a name is
      not the program: the same script may define `cat() { … }`, an alias may
      shadow it, and `PATH` may point elsewhere. The effect table describes
      *our* builtins, so applying it to a spawned command would under-gate.
      The process asks still name the script, its focus span and its redirects
      (and an outside path keeps its own ask). When a script is declined only
      for an unsupported flag, the fix is to support the flag in the tier —
      then the effects are asked — not to guess on the bash side.

### Phase 4: bucketing (deliberately per effect)

- [x] **Decision: one ask per effect, not per bucket.** The approval service
      matches rules against one subject per ask, so an effect a grant already
      covers is silent. A single ask for a bucket of paths would have no single
      subject to match: a directory grant could no longer suppress it without a
      batch concept in the service, the protocol and the dialog — the opposite
      of "the grant is the scope".
- [x] Each effect's ask already offers the batch-granular choices
      (exact / dir / ext / dir+ext / any), so one grant covers the rest of the
      call's effects, and later asks never appear.
- [x] _(Future, not this plan)_ a batched ask — several subjects with per-subject matching —
      only if the prompt count itself becomes the problem. It needs the
      service, protocol and dialog to carry a subject list.

## Success Criteria

- The operator always sees the effect they are approving (redirects included).
- A file-tool grant covers the shell; a shell grant can be as fine as
  "always .log files in build/".
- No shell write happens without a visible ask.
