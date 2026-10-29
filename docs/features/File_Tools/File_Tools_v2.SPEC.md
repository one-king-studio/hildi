# Component Specification: File Tools v2

**Related Feature:** [FEATURE.md](FEATURE.md)

**Extends:** [File Tools v1](File_Tools_v1.SPEC.md) (the six tools, the
`ResolveChecked`/`Approve` shape) and [Approval Path Scoping
v1](../Approval_Path_Scoping/Approval_Path_Scoping_v1.SPEC.md) (the
`dir`/`ext`/`dir_ext` options the multi-file tools need).

## Purpose

Add the **first-class edit tools** the Composed Tool Sandbox's `tools.*` surface
promises, so the **gated** path is the **easy** path: an agent reaching for
`bash` because a tool is missing gets a typed, approval-gated, workspace-confined
tool instead. The engine is the vendored SQLite store we already have; the new
work is tool handlers, a glob-driven multi-file replace, and (for YAML) a
minimal, tolerant parser.

This is the increment the [Composed Tool Sandbox](../../features/Composed_Tool_Sandbox/FEATURE.md)
roadmap calls "step 3 — first-class edit tools": it delivers most of the
bash-avoidance value **without** the GocciaScript engine, and it is a
prerequisite for the sandbox being useful.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| Workspace confinement | `TWorkspace.Contains`/`Resolve`, `TFileTool.ResolveChecked` | reuse; extend with the physical check (Path Scoping) |
| Approval gate | `TFileTool.Approve` + `IApprovalService` | reuse; pass the operation's path (Path Scoping) |
| Glob matching | `hildi.files` (`**`, `*`, `?`) | reuse for `file_search_replace` |
| JSON | `fpjson`/`jsonparser` (in-tree) | reuse for `json_read`/`json_edit` |
| Unified-diff apply | none | **new** (a small parser; `patch` is not assumed installed) |
| YAML | none (replymeta has a *tolerant frontmatter* scanner, not a parser) | **new**, minimal subset |
| File ops (move/copy/delete/mkdir/stat) | RTL (`RenameFile`, `CopyFile`, `DeleteFile`, `ForceDirectories`, `FileAge`/`FindFirst`) | wrap |

## Requirements

### Functional

**File writes and edits**

- [ ] `file_append(path, content)` appends, creating the file if absent; returns
      `{ bytes }`.
- [ ] `file_replace_regex(path, pattern, repl, opts?)` replaces by regex within
      one file; `opts.all` (default true), `opts.flags` (a subset: `i`). Returns
      `{ replaced }`. A non-compiling pattern is an error.
- [ ] `file_search_replace(glob, pattern, repl, opts?)` replaces across every
      file matching `glob`; `opts.dryRun` returns the paths and counts without
      writing. Returns `{ files, replacements, dryRun }`.

**Filesystem operations**

- [ ] `file_delete(path)`, `file_move(src, dst)`, `file_copy(src, dst)`,
      `file_mkdir(path)` (parents included), `file_stat(path)` →
      `{ size, mtime, type }` (`file`/`dir`), `file_list`/`file_glob` unchanged.

**Structured formats**

- [ ] `json_read(path, pointer?)` parses JSON, optionally at a JSON pointer;
      `json_edit(path, pointer, value)` sets a pointer and writes back
      **validated** (a parse failure never writes).
- [ ] `yaml_read(path, path_expr?)` / `yaml_edit(path, path_expr, value)` — a
      **minimal, tolerant** YAML subset: mappings, nested mappings by indent,
      sequences, scalars. A construct outside the subset is an error, never a
      silent corruption; `yaml_edit` writes only on a successful parse.

**Patches**

- [ ] `patch_apply(patch, opts?)` applies a unified diff; `opts.strip` (default
      1), `opts.dryRun`. Returns `{ applied, rejected }`; a hunk that does not
      apply is counted rejected, not fatal, and the rest is attempted.

**Cross-cutting (every new tool)**

- [ ] Every tool resolves its path(s) through `ResolveChecked` (workspace-confined,
      physically checked) and resolves approval **before** any I/O.
- [ ] Every tool declares the operation's path on the subject (a single path; for
      `file_search_replace`, the **directory** the glob searches), so Path Scoping
      applies.
- [ ] `file_search_replace` and `file_replace_regex` are **write-shaped** asks
      (offer `dir`/`ext`/`dir_ext`); the read tools stay read-shaped.
- [ ] Each tool requires a non-empty `reason`, returns structured text (JSON), and
      is registered by the same `Register` path as v1.

### Non-Functional

- [ ] Output is bounded (`MaxOutputBytes`) with a `[truncated]` marker.
- [ ] A regex that matches too much is bounded by a per-call cap (files scanned,
      replacements made) so a runaway script cannot hang the turn.
- [ ] No new dependency: `fpjson` is in-tree; the diff and YAML parsers are
      small, pure, and unit-tested.
- [ ] Portability: macOS + Linux, FPC 3.3.1; `make check` green; leak-clean.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

```pascal
unit hildi.files;

type
  { The v2 handlers, added to TFileTool. Each resolves approval first. }
  TFileTool = class
  public
    function AppendFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ReplaceRegex(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function SearchReplace(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function DeleteFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function MoveFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function CopyFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function MakeDir(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function StatFile(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function JsonRead(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function JsonEdit(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function YamlRead(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function YamlEdit(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function PatchApply(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;
```

```pascal
unit hildi.patch;   // NEW: a unified-diff applier (pure)

type
  TPatchResult = record
    Applied: Integer;
    Rejected: Integer;
    RejectedAt: string;   // the first rejected hunk's header, '' if none
  end;

{ Apply a unified diff to the file it names (ARead/AWrite are the host's I/O,
  so the parser stays pure and testable). ADryRun computes the result without
  writing. Never raises on a bad hunk; counts it rejected. }
function ApplyUnifiedPatch(const APatch: string; AStrip: Integer;
  ADryRun: Boolean; const ARead: TPatchRead; const AWrite: TPatchWrite;
  out AResult: TPatchResult; out AError: string): Boolean;
```

```pascal
unit hildi.yaml;   // NEW: a minimal, tolerant YAML subset

{ Parse to a fpjson TJSONData (so the tool result is uniform JSON). A construct
  outside the subset (anchors, tags, flow beyond simple scalars) fails with a
  line number; it never silently mis-parses. }
function ParseYaml(const AText: string; out AError: string): TJSONData;
{ Set a dotted path (a.b[2].c) and re-emit the document. }
function SetYamlPath(const AText, APath: string; const AValue: TJSONData;
  out AError: string): string;
```

## Data flow

1. The handler parses arguments (`ParseArgs`), resolves the path(s)
   (`ResolveChecked`).
2. It builds the approval ask with the operation's path on the subject, resolves
   it, and only then performs I/O.
3. It returns a JSON object (`{ replaced }`, `{ bytes }`, …) as the tool result.

## Validation and error handling

- A path outside the workspace: refused, no I/O (as v1).
- A malformed patch / YAML / JSON: a clear error, no partial write.
- A `file_search_replace` over a huge tree: capped (files/replacements), with a
  `truncated` marker.
- A denied ask: the batch reason, no I/O.

## Testing requirements

### Unit tests (`test_file_tools.pas`)

- [ ] `file_append` creates then appends; `file_stat` reports size/type.
- [ ] `file_replace_regex` replaces all/one, is case-insensitive with `i`, and
      errors on a bad pattern.
- [ ] `file_search_replace` across a glob: the right files, a `dryRun` that
      writes nothing, and a bounded count.
- [ ] `file_delete`/`file_move`/`file_copy`/`file_mkdir` round-trip on a temp dir.
- [ ] `json_read`/`json_edit` at a pointer; a parse failure never writes.
- [ ] `yaml_read`/`yaml_edit` on the subset; an out-of-subset construct errors.
- [ ] `patch_apply` applies a clean diff, counts a bad hunk rejected, and
      `dryRun` writes nothing.
- [ ] Every tool refuses a path outside the workspace and asks for approval
      first (a fake service records the ask and the `Subject.Path`).

### Integration

- [ ] `file_search_replace`'s ask offers `dir`/`ext`/`dir_ext` (Path Scoping) and
      a `dir_ext` grant suppresses the prompt for a matching batch.

## Performance targets

- `file_search_replace` is O(files matched × size), bounded; a large tree is
  capped rather than unbounded.

## Security considerations

- Workspace confinement + the physical check (Path Scoping) apply to every new
  tool, so a symlink out is refused.
- A regex is model-authored: bounded work, no catastrophic backtracking assumed
  (FPC's `RegExpr` is not PCRE; still capped by the file/replacement limits).

## Success criteria

- [ ] All contracts implemented; `make check` green; leak-clean.
- [ ] Each tool maps to a `bash` idiom the roadmap table lists, and each is
      gated + confined + reasoned.
- [ ] A `dir_ext` grant makes a multi-file replace one prompt.

## Future considerations

- `xml_edit`; a fuller YAML (anchors, tags) if the subset proves too bare.
- The Composed Tool Sandbox injects these as `tools.*` once the engine spike
  passes.
- Snapshot interception (`Workspace_Snapshots`) on every write path.
