# SPEC: sed v1

**Related:** [FEATURE.md](FEATURE.md) · [Text & Data Commands TODO](Text_Data_Commands_v1.TODO.md) · [Command & Flag Coverage](../Builtin_Shell_Tier/COMMAND_COVERAGE.md)

## Scope

A line-oriented sed subset that covers the recorded corpus (1,245 uses) and
declines the rest. Implemented in `hildegard.helper.shell.sed`
(`RunSed`) and registered as the `sed` command by the tier.

```
src/hildegard.helper.shell.sed.pas        RunSed (the interpreter)
src/hildegard.helper.shell.pattern.pas    BRE/ERE translation + matcher (shared)
src/hildegard.helper.shell.commands.pas   the `sed` command: argv, files, -i
```

## Command line

```
sed [-n] [-E|-r] [-e SCRIPT]... [-i[SUFFIX]] [SCRIPT] [FILE...]
```

- `-n` — suppress the default print; only `p` and `s///p` print.
- `-E` / `-r` — ERE. The default is BRE, translated by `shell.pattern`
  (so `\(`, `\)`, `\{`, `\}`, `\|`, `\+`, `\?`, `\<`, `\>` behave as bash's).
- `-e SCRIPT` — add a script; may repeat; scripts combine with newlines.
- `-i[SUFFIX]` — rewrite each file in place. With a suffix, the original is
  written to `FILE+SUFFIX` first. `-i` with no files is a usage error.
- One script without `-e` is taken from the first non-option argument.
- No files → stdin; the result goes to stdout.
- Flags may be combined (`-ni`); `-i`'s suffix is the rest of its token.

## The program

Commands are separated by newlines and `;`. Leading blanks are skipped.

### Addresses

| Address | Meaning |
|---|---|
| `N` | line N |
| `$` | the last line |
| `/re/` | every line matching `re` |
| `A,B` | from a line matching A through the first line matching B (inclusive) |
| `A,$` | from A through the last line |

A range's end is not tested on the line that opened it (bash's behaviour), so
`/alpha/,/alpha/p` prints the block starting at a second occurrence, not a
single line. An end address that is a line number is tested on the start line
(`3,3` is one line).

### Commands

| Command | Meaning |
|---|---|
| `p` | print the pattern space |
| `d` | delete: no default print, stop this line's commands |
| `q` | print (unless `-n`) and stop reading input |
| `s/re/repl/flags` | substitute |

`s` flags: `g` (every match), `p` (print if a substitution happened), `i`/`I`
(case-insensitive). The delimiter is any character (`s|a|b|`). In the
replacement, `&` is the whole match, `\1`..`\9` are groups, `\&` is a literal
`&`, and `\\` is a literal backslash.

Only the first match is replaced unless `g` is given.

### Not supported (declines or errors)

Hold space (`h`, `H`, `g`, `G`, `x`), branching (`b`, `t`, `:`), `n`/`N`,
`a`/`i`/`c`, `y`, `=`, `l`, `w`/`r`, multiline pattern space, and `0,/re/`.
`sed` is not a scripting language here; those go to `/bin/bash`.

## Execution

For each input line, in order:

1. If the line is in a range, mark every command whose address is active.
2. Run the active commands in script order; `d` stops, `q` stops the input.
3. Unless `-n` or `d`, print the (possibly substituted) line.

Output lines are joined with `\n`. The last line is printed with a newline.

## `-i` and the filesystem

- Each file is read through `TWorkspaceShellFs`; a path outside the workspace is
  refused (`path escapes the workspace`), status 2.
- The transformed text is written back through the same seam.
- With a suffix, the original content is written to `FILE+SUFFIX` **before** the
  rewrite; a backup failure stops the command (status 4) and leaves the file
  untouched.
- `-i` never touches stdin.

## Errors

| Situation | Status | stderr |
|---|---|---|
| a missing/unreadable file | 2 | `sed: FILE: …` |
| a program error (unsupported command, bad regex, unterminated `s`) | 1 | `sed: …` |
| a write failure on `-i` | 4 | `sed: cannot write FILE…` |

A program error is reported before any output for that file.

## Pre-flight

The tier's option table lists `-n -E -r -e -i`; `-i<suffix>` is exempt from the
combined-flag check (the suffix is attached). A **literal** script containing a
construct `shell.pattern` cannot express is declined by the tier, so `auto`
falls back to `/bin/bash`; a script only known at run time errors with status 1.

## Testing

- `tests/test_shell_commands.pas` — paging, single line, `$`, regex ranges,
  substitution (`&`, groups, `g`, `p`), delete, quit, match-to-end, `-i` with a
  backup, a missing file, an unsupported command.
- `tests/data/shell_commands_differential.txt` — 13 scripts recorded from
  `/bin/bash`, replayed through the tier (paging, ranges, `s///` forms, ERE
  groups, delete, quit, in-place + `cat`).

## Recorded deviations

- Only the commands listed above; everything else errors with
  `unsupported sed command: X`.
- Line numbers count `\n`; a file without a trailing newline has one fewer
  line, as in bash.
- Address and substitution regexes use the shared BRE/ERE translation, so
  GNU extensions (`\+`, `\?`, `\|`) work and unknown letter escapes are
  literal.
- Binary input is treated as text (a NUL is copied through).
