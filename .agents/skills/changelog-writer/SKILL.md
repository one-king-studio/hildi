---
name: changelog-writer
description: Turn a range of git commits into a changelog entry grouped by kind, in the project's existing style. Use when the operator asks to write or update a changelog after a set of changes.
license: Apache-2.0
compatibility: Needs git on PATH. Reads only the local repository.
metadata:
  author: hildi
  version: "1.0"
---

# Changelog writer

Write a changelog entry for a range of commits. The output is a Markdown
section, not a whole file: the caller decides where it goes.

## Steps

1. Collect the commits in range. Run `scripts/collect.sh <from> <to>` from this
   skill's directory. It prints one line per commit: the short hash, the
   conventional-commit prefix (if any), and the subject.
2. Read `references/format.md` for the grouping rules and the wording to use.
3. Group the commits by kind, in the order the reference gives.
4. Write the section. One line per change, no bullet for a change that a reader
   could not act on (a reformat, a version bump with no behavioural effect).

## Rules

- **Never invent a change.** If the subject is unclear, quote it rather than
  paraphrasing it into something more impressive.
- **Group by effect on the reader, not by commit.** Three commits that fix one
  bug are one line.
- **Say what changed for the user**, not which file changed. "A long state
  label no longer squeezes the hints off the row" beats "fix TUI layout".
- If the range is empty, say so in one line and stop.

## Do not

- Do not rewrite or amend history.
- Do not write the changelog into the repository unless asked; print it.
- Do not add an entry for a revert that cancels a change in the same range —
  the pair is a no-op.
