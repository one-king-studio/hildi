# Implementation Plan: Per-call File Changes v1

**Related:** [FEATURE.md](FEATURE.md) · [File_Changes_v1.SPEC.md](File_Changes_v1.SPEC.md)

## Implementation Tasks

### Phase 1: the builtin tier records its writes (shipped)

- [x] `hildegard.helper.workspace.changes`: `TFileChange`, `TFileChangeSet`,
      `Summary`.
- [x] `TWorkspaceShellFs.OnChange` and reporting in `WriteFile`, `Delete`,
      `Move`, `Copy`, `MakeDir`, `Touch`.
- [x] `ICommandExecutor.Execute` takes the call's set; the builtin executor
      passes it to the tier; `TCommandToolConfig.OnChanges` fires once.
- [x] Tests: the compound script's changes; the callback.

### Phase 2: the process tier (shipped)

- [x] Snapshot (path, size, mtime) before/after a spawned command when a set is
      supplied; ignore-aware via `hildegard.helper.gitignore`.
- [x] Report created/modified/deleted into the same set; read content for
      created and modified files up to the cap (a deleted file keeps its size
      only — its bytes are gone by the time we diff).
- [x] Snapshot only when somebody listens: the tool passes a set only when
      `OnChanges` is assigned.
- [x] Tests: the snapshot/diff unit suite (ignored paths, a nested
      `.gitignore`, `.git`, created/modified/deleted, large files, directories)
      and a real `/bin/bash` write through the process executor.

### Phase 3: surfacing (shipped: the tool result line)

- [x] Decide: the tool result line first — visible to the model and the panel
      in one place, no protocol or view change. A TUI diff pane and a
      checkpoint store stay open, fed by the same `OnChanges` set.
- [x] `run_command` appends `[changed: A new.txt, M src/a.pas (+3 -1), ...]`
      when the set is non-empty, capped at 400 bytes on a UTF-8 boundary.
- [x] Tests: the note names the change; no note without changes; a large set is
      capped.

### Phase 4: docs

- [ ] Update `FEATURES.md`; rename this TODO to `File_Changes_v1.DONE.md`.

## Success Criteria

- A call's writes are described exactly (path, kind, content) for the builtin
  tier.
- The process tier's blind spot is closed (phase 2).
- The consumer surfaces the set without changing the model's contract.
