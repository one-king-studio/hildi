# Implementation Plan: Text & Data Commands v1

**Related:** [FEATURE.md](FEATURE.md) · [Sed v1 SPEC](Sed_v1.SPEC.md)

## Overview

Add the transform primitives to the builtin shell tier — `sed`, then `awk`,
`jq`, `yq`, `rg` — each as a subset that declines the rest to `/bin/bash`.
Evidence first: the corpus says `sed` (1,245 uses) is the whole story today;
`awk` is a dozen; `jq`/`yq`/`rg` are prospective. Spec-driven, TDD,
`make check` before moving on.

## Implementation Tasks

### Phase 0: the shared pattern engine

- [x] **Extract** `shell.pattern` from the grep work: `TranslatePattern`,
      `PosixClassRange`, `TPatternMatcher`, `PatternSupported`.
- [x] **Test**: the existing grep and tier tests exercise it unchanged.

### Phase 1: sed (shipped)

- [x] **Implement** `hildegard.helper.shell.sed`: `-n`, `-E`/`-r`, `-e`,
      `-i[SUFFIX]`; addresses `N`, `$`, `/re/`, ranges; `p`, `d`, `q`, `s///`
      with `g`/`p`/`i`; `&` and `\1`..`\9` in the replacement.
- [x] **Register** `sed` in the tier and the option table (`-i<suffix>` exempt
      from the combined-flag check).
- [x] **Test**: paging, ranges (numeric, regex, to end), substitution forms,
      delete, quit, `-i` with a backup, a missing file, an unsupported command.
- [x] **Differential**: 13 scripts recorded from `/bin/bash`.
- [x] **Measure**: whole-script coverage 23% → 51% (751 → 1,670 of 3,255).

### Phase 2: awk fields (shipped)

- [x] **Implement** `awk`: `-F`, `{print ...}` with `$0`/`$N`/`NR`/`NF`,
      conditions (`$N <op> value`, `$N ~ /re/`, `&&`, `||`), one pattern-action
      form (`/re/ { ... }`), string literals in `print`.
- [x] **Decline**: functions, arrays, `getline`, `printf` formats, variables
      assigned in the program, multiple rules beyond the supported shape.
- [x] **Test** + 10 differential fixtures; coverage 1,670 → 1,686.

### Phase 3: jq paths

- [ ] **Implement** `jq`: `.`, `.foo`, `.foo.bar`, `.foo[]`, `.[N]`,
      `.["k"]`, `-r` (raw), `-c` (compact), `keys`, `length`.
- [ ] **Decline**: pipes, `select`, `map`, variables, functions, `-e`.
- [ ] **Test** + differential fixtures; measure.

### Phase 4: yq (last)

- [ ] **Decide** whether to add `yq` at all: the harness already has
      `yaml_read`/`yaml_edit`, and the corpus has no uses.
- [ ] If added: the same path queries as `jq`, over the existing YAML reader.

### Phase 5: rg

- [ ] **Decide** the `.gitignore` question: ripgrep's defining behaviour is
      skipping ignored files. Either implement `.gitignore` (root + nested,
      with negation) or decline any traversal and support only explicit paths.
- [ ] **Implement** `rg` over the shared engine: `-n`, `-i`, `-l`, `-c`, `-F`,
      `-E`, `-g/--glob`; recursive by default.
- [ ] **Test** + differential fixtures; measure.

### Phase 6: validation and docs

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] Update `COMMAND_COVERAGE.md` and `FEATURES.md`; rename this TODO to
      `Text_Data_Commands_v1.DONE.md` when the set is complete.

## Success Criteria

- [x] `sed` runs in the tier and matches bash on the recorded fixtures.
- [ ] Each later command matches its subset and declines the rest.
- [ ] `make check` green, leak-clean.
- [ ] Coverage is measured after each command and recorded.

## Notes

- **Subsets, not emulations.** A command that cannot be faithful declines; it
  never approximates and lets the difference reach the model.
- **Share the engine.** sed, grep and rg must agree on BRE/ERE.
- **Watch the gate.** Each command asks once, `run_command:<bin>`, inherited
  reason.
