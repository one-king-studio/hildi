# File Tools

## Overview

Native, approval-gated tools for reading, writing, editing, listing, and
searching files inside the active workspace: `read_file`, `write_file`,
`edit_file`, `list_dir`, `glob`, and `grep`. They sit beside `run_command` in the
tool registry and share the same trust model: nothing runs without an approval
decision, and every path is resolved against the workspace root.

## Problem Statement

Today the only way the model can touch files is `run_command` (`cat`, `sed`,
`grep`, `find`). That is powerful but blunt: it composes shell quoting, gives no
structured read, and makes every file operation look like a
shell command to the approval whitelist. A coding harness wants first-class file
operations with structured arguments, bounded output, and per-operation approval.

Apply the Ponytail ladder: rung 1 does not hold (the operator asked for these
tools); rungs 3/4 hold for the mechanics - the RTL already has file I/O
(`TFileStream`, `TStringList`, `FindFirst`/`FindNext`) and the approval engine
exists - so only the tool layer and a small glob matcher are new.

## Goals

- Six tools with JSON-Schema parameters, matching the existing tool contract.
- Every tool call is approval-gated through `IApprovalService` (reads included).
- All paths resolve under the workspace root; escapes are refused.
- Bounded output: large reads/listings/searches are truncated, never unbounded.
- Deterministic, testable logic with a real temp directory in tests.

## User Stories

- As an **operator**, I want the agent to read a file's contents so it can
  inspect and edit it.
- As an **operator**, I want the agent to write and edit files, so it can make
  changes without shelling out.
- As an **operator**, I want to approve each file operation (read or write) with
  the same once/exact/wildcard/deny choices as commands, so I stay in control.
- As an **operator**, I want the agent to discover files by name and content
  (`glob`, `grep`) instead of guessing paths.
- As a **harness author**, I want file access confined to the workspace and
  bounded, so a confused model cannot read or dump the whole disk.

## Acceptance Criteria

### Functional Requirements

- [ ] `read_file(path, offset?, limit?)` returns the file's text (optionally a
      line range) for a file under the root; a directory or missing file is an
      error.
- [ ] `write_file(path, content)` creates or overwrites a file, creating parent
      directories as needed, and reports bytes written.
- [ ] `edit_file(path, old_string, new_string, replace_all?)` replaces an exact
      string; zero matches is an error; more than one match without
      `replace_all` is an error (ambiguous); it reports the replacement count.
- [ ] `list_dir(path?, recursive?)` lists entries under a directory, one per
      line, directories suffixed `/`.
- [ ] `glob(pattern, path?)` returns workspace-relative paths matching `*`, `?`,
      and `**`, sorted.
- [ ] `grep(pattern, path?, ignore_case?, max_results?)` returns
      `path:line: text` for lines containing the pattern.
- [ ] Every tool resolves approval before acting; a denial returns the batch
      reason and performs no I/O.
- [ ] A path that resolves outside the workspace root is refused.
- [ ] Output is truncated at a configured byte cap with a `[truncated]` marker.
- [ ] A tool call with no approval service fails with a clear error.

### Non-Functional Requirements

- [ ] No new dependency; RTL only.
- [ ] Deterministic and unit-tested against a temporary directory.
- [ ] Leak-clean under `make test-leak`; `make check` green.
- [ ] Style: `{$mode delphi}{$H+}`, unit `hildegard.helper.file.tool`.

## Success Metrics

### Quantitative

- Every acceptance criterion maps to at least one named fpcunit test.
- The six tools are advertised in the registry when the harness/CLI starts.
- `make check` green.

### Qualitative

- Structured arguments and bounded output beat `cat`/`sed` for the common cases.
- Approval choices are identical in shape to `run_command`.

## Constraints

### Technical

- Build with FPC 3.3.1, `{$mode delphi}`; keep `make check` green.
- Reuse `TToolRegistry`, `IApprovalService`, and the `TApprovalAsk` model.
- Work on `main`; spec-first, TDD.

### Business / Time

- Operator-requested; unblocks real editing work in the TUI/CLI agent.

## Dependencies

### Internal

- `hildegard.helper.agent` (`TToolRegistry`, `TToolSpec`, `TToolHandler`).
- `hildegard.helper.approval` (`IApprovalService`, `TApprovalAsk`,
  `TApprovalOption`, `DefaultApprovalRule`).
- `hildegard.helper.workspace` (`TWorkspace` containment) - the same boundary
  the shell tool uses.

### External

- RTL only: `Classes`, `SysUtils`.

## Risks

- **Path escape via symlink or `..`.** Mitigation: resolve against the root and
  require containment; document that this is a guardrail, not an OS sandbox
  (same stance as the command policy).
- **Huge files / unbounded search.** Mitigation: byte caps on read/list/glob/grep
  and a result cap on grep.
- **Glob matcher complexity.** Mitigation: a small, table-tested matcher for
  `*`/`?`/`**`; unsupported syntax matches literally.

## Out of Scope

- A filesystem sandbox or permission model beyond workspace containment.
- Binary-safe reads (v1 reads text; binary content is reported, not decoded).
- Patch/diff application, multi-file transactions, or undo.
- Regex `grep` (v1 is a plain substring match; `ignore_case` supported).
- Editing outside the workspace root.

## Future Considerations

- Regex grep and richer glob (brace expansion).
- `move`/`delete`/`mkdir` tools.
- Diff/patch application and multi-file edits.
- Streaming reads for very large files.

## Notes

- **ICE score: Impact 8, Confidence 8, Ease 7.** High impact for a coding
  harness, high confidence (RTL mechanics plus the existing approval model), and
  moderate ease (the glob matcher and path containment are the only real work).
- **Reuse:** the approval ask/option shape is copied from `TCommandTool` so the
  CLI/TUI approval UI already understands it.
