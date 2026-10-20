# Feature: Approval Review

**Status:** In Progress (phases 1 and 2 shipped): redirects are named and bound to the file
tools, pure commands are ungated, the **effect-scoped gate** is live on the
builtin tier (a granted `file:read`/`file:write` scope is the approval), and
the dialog shows the **whole command**, scrolled to the span being approved
and bolding it (the rest of the script dimmed, no colour). The process-tier effects and bucketing remain.

**Related:** [Command Tool](../Command_Tool/Command_Tool_v1.SPEC.md) ·
[Approval Path Scoping](../Approval_Path_Scoping/Approval_Path_Scoping_v1.SPEC.md) ·
[Builtin Shell Tier](../Builtin_Shell_Tier/FEATURE.md) ·
[File Changes](../File_Changes/FEATURE.md)

## The Problem

The approval dialog asks about **one segment at a time**, and the segment's
text omits its redirects — `echo x > out.txt` was summarised as `echo x`. For a
compound script with control flow, the operator sees a list of fragments with
no view of the script they belong to, and no way to tell which fragment the
prompt is about. Long summaries are wrapped and then cut at the modal's edge
(there is no scrolling).

The option list is command-shaped (`once`/`exact`/`any`/`prefix`), while the
file tools already offer the finer vocabulary the operator wants: exact path,
a directory, an extension, or a directory *and* extension. And a shell write
(`>`, `sed -i`, `tee`, `rm`) is a different grant from `file_write`, even
though it is the same effect.

## The Decision

Make the ask a **reviewable unit**, not a fragment:

1. **The ask carries the whole command** (`Script`) and the span of the
   relevant command within it (`FocusStart`, `FocusLen`). The operator reads
   the script; the fragment being approved is highlighted.
2. **The dialog scrolls** when the script is longer than the modal, opening at
   the focused command rather than at the top.
3. **Redirects are file effects.** `>`/`>>`/`2>`/`&>` become a `file:write`
   ask and `<` a `file:read` ask, with the **same option shapes as the file
   tools** (exact / dir / ext / dir+ext / any). A `file_write` grant therefore
   covers the shell, and an operator can say "always .log files in build/".
   There is no `never` option: a deny is a policy decision (the deny rule the
   store already models), not a per-prompt choice — denying the prompt is the
   answer, and a persistent deny belongs to the rules, not the dialog.
4. **The grant is the scope.** On the builtin tier the gate asks about
   **effects**, not programs: every read and write a command will make (its
   operands *and* its redirects) is checked as `file:read`/`file:write`. A
   granted scope — a path, a directory, an extension, or a directory *and* an
   extension — silently covers any command whose effect falls inside it; an
   effect outside the grant is asked. So granting "read `*.pas` in `src/`"
   covers `cat`, `head`, `grep`, `rg` and `jq` there alike, and `rm`/`sed -i`
   are covered by the write scopes. Commands whose effects cannot be named
   (`tool`, `mcp`, unknown names) keep the command-level ask.
5. **Pure commands are not gated.** `echo`, `printf`, `true`, `false`,
   `basename` and `dirname` produce text from their own arguments: no
   filesystem, no stdin, no information about the machine. They ask nothing.
   Their **redirects are still asked** (`echo x > f` asks for `file:write f`),
   and anything that reads, writes, or lists a directory remains gated —
   extraction into the context and writes back to the system are exactly what
   approval is for.
6. **The working directory is part of the ask.** A relative argument means
   something different after a `cd`, so every file ask (and the command ask)
   names the effective cwd when it is not the workspace root
   (`read sub/a.txt (cwd sub)`). Effects are resolved against the cwd, so the
   ask is unambiguous even when the script changed directory.
7. **`cd` cannot leave the workspace in the tier.** The tier's filesystem is
   the workspace, so `cd /outside` is refused (`path escapes the workspace`),
   not approved: with `&&` the rest does not run, with `;` the rest runs in the
   old directory. Outside work is the process tier's job, where the splitter's
   path asks (which track a `cd`) cover it.
8. **Buckets.** When a call's file effects are known, group them: one option
   can grant a directory, an extension, or the pair, across several effects —
   the granularity the file tools already expose, applied to a batch.

## Boundaries

- **No new tool parameters.** The model's contract is unchanged.
- **The script is the source of truth.** The ask's `Script` is the command as
  run (after HTML-entity decoding); the focus is a byte span into it.
- **File asks never broaden the workspace bound.** An outside target keeps the
  existing `path:` ask (absolute path, separate coordinate space).
- **The command ask stays.** A redirect grant is additional, not a replacement:
  the operator still approves the program. An existing exact command grant
  keeps suppressing the path ask, as today.

## Acceptance

- `echo x > out.txt` asks for `file:write out.txt` with
  exact/dir/ext/dir+ext/any (and no command ask: `echo` is pure).
- `cat < in.txt` asks for `file:read in.txt`.
- `2>&1` and `<&` raise no file ask.
- An outside redirect keeps the `path:` ask and raises no `file:` ask.
- `echo x`, `printf …`, `basename /a/b` ask nothing; `ls`, `cat`, `test -f`,
  `sed -i` ask as file effects (`file:read` / `file:write`).
- With a `file:read` grant for `src/*.pas`, `cat`, `head`, `grep` and `rg` on
  those files prompt nothing; a read outside that scope still does.
- `cd sub; cat a.txt` asks for `read sub/a.txt (cwd sub)`; `cd /tmp` inside the
  tier is refused and changes nothing.
- A long compound script opens the dialog scrolled to the highlighted command
  (phase 2).
- `sed -i` and friends raise their file asks (phase 3).
