# Changelog format

## Grouping

Use these sections, in this order, and omit a section with no entries:

1. **Added** — something that did not exist before.
2. **Changed** — existing behaviour that works differently now.
3. **Fixed** — a defect the reader could have hit.
4. **Removed** — something taken away.
5. **Internal** — only include this section if the operator asked for it.
   Most readers do not care about refactors.

Commit prefixes map roughly: `feat` → Added, `fix` → Fixed, `perf` and
`refactor` → Changed or Internal, `docs` and `test` → Internal, `chore` →
usually omitted entirely.

## Wording

- **Present tense, what the reader can now do or no longer suffer.** "The
  palette marks which skills are loaded", not "added palette marking".
- **One line.** If it needs two, it is two changes or it is not ready.
- **Lead with the effect.** The file or subsystem is a trailing clause at best;
  often it can be dropped.
- **No praise.** Drop "greatly improves", "significantly faster" unless you can
  put a number on it, and then use the number.

## Shape

```markdown
## <version or date>

### Added
- The skill list marks which skills are in the context.

### Fixed
- A skill body no longer disappears from the context after a checkpoint.
```

Keep the heading whatever the project already uses; ask rather than invent a
version number.
