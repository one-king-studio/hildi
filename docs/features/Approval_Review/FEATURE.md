# Feature: Approval Review

**Status:** Phase 1 shipped (redirects are named in the ask and bound to the
file tools). The full-script review, focus highlighting, scrolling and the
per-command file effects are specified here.

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
   tools** (exact / dir / ext / dir+ext / any / never). A `file_write` grant
   therefore covers the shell, and an operator can say "always .log files in
   build/".
4. **The command's own file effects are known where the tier knows them.**
   `sed -i`, `tee`, `rm`, `mv`, `cp`, `mkdir`, `touch` name their targets; the
   tier raises the same file asks before running, from the AST. The process
   tier cannot know, so it keeps the splitter's analysis (the redirects and the
   outside-path asks).
5. **Buckets.** When a call's file effects are known, group them: one option
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

- `echo x > out.txt` shows `echo x > out.txt` and asks for `file:write out.txt`
  with exact/dir/ext/dir+ext/any/never.
- `cat < in.txt` asks for `file:read in.txt`.
- `2>&1` and `<&` raise no file ask.
- An outside redirect keeps the `path:` ask and raises no `file:` ask.
- A long compound script opens the dialog scrolled to the highlighted command
  (phase 2).
- `sed -i` and friends raise their file asks (phase 3).
