# Component Specification: File Tools v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

A single component, `TFileTool`, that registers six approval-gated file tools
with a `TToolRegistry` and executes them inside the active workspace:
`read_file`, `write_file`, `edit_file`, `list_dir`, `glob`, `grep`.

It follows `TCommandTool` exactly: the component owns an `IApprovalService`,
resolves an approval ask before acting, and reports failures as `False` +
`AError` (which the agent loop records as an error tool result).

## Requirements

### Functional

- [ ] Register six tools with JSON-Schema parameters.
- [ ] Resolve approval (once/exact/wildcard/deny) before any I/O, reads included.
- [ ] Confine every path to the configured root; refuse escapes.
- [ ] Bound all output by byte/result caps with a `[truncated]` marker.
- [ ] Report failures as `False` + `AError`; never raise to the caller.

### Non-Functional

- Performance: bounded by caps; a grep stops at `max_results`.
- Reliability: no leaks; no partially written files on a refused write.
- Portability: macOS and Linux; RTL only.

## Contracts & Interfaces

Unit: `hildegard.helper.files`.

```pascal
type
  TFileToolConfig = record
    Root: string;             // workspace root; '' => process cwd
    MaxReadBytes: Integer;    // 0 => DefaultMaxReadBytes
    MaxOutputBytes: Integer;  // 0 => DefaultMaxOutputBytes (list/glob/grep)
  end;

  { Six gated file tools. Owns no threads. Handlers match TToolHandler. }
  TFileTool = class(TInterfacedObject)
  public
    constructor Create(const AConfig: TFileToolConfig;
      AService: IApprovalService);

    { Registers all six tools. }
    procedure Register(ATools: TToolRegistry);

    { Handlers (public for direct testing). Each resolves approval first. }
    function ReadFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function WriteFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function EditFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function ListDir(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function Glob(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function Grep(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;

const
  DefaultMaxReadBytes = 262144;    // 256 KiB
  DefaultMaxOutputBytes = 65536;   // 64 KiB
  DefaultGrepMaxResults = 200;
```

### Tool schemas (advertised `ParametersJson`)

Every schema is an object; the registry auto-injects the required string
`reason`.

- `read_file`: `path` (string, req), `offset` (integer), `limit` (integer).- `write_file`: `path` (string, req), `content` (string, req).
- `edit_file`: `path`, `old_string`, `new_string` (all string, req),
  `replace_all` (boolean).
- `list_dir`: `path` (string), `recursive` (boolean).
- `glob`: `pattern` (string, req), `path` (string).
- `grep`: `pattern` (string, req), `path` (string), `ignore_case` (boolean),
  `max_results` (integer).

### Approval contract

One ask per call. Subject refs and params:

| Tool | Ref | Params |
| --- | --- | --- |
| read_file | `file:read` | `[relpath]` |
| write_file | `file:write` | `[relpath]` |
| edit_file | `file:edit` | `[relpath]` |
| list_dir | `file:list` | `[relpath]` |
| glob | `file:glob` | `[pattern, relpath]` |
| grep | `file:grep` | `[pattern, relpath]` |

Options mirror `run_command`: `once` (no persist), `exact` (persist `=<params>`),
`any` (persist, any params). `Summary` is a short human line (e.g.
`read src/foo.pas`). A denied batch returns `Batch.Reason` as `AError` and
performs no I/O.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.command.tool` (`TCommandTool`) - the gated-tool pattern:
  parse args, resolve approval, act, return text. The ask/option shape is reused
  verbatim so the CLI/TUI approval UI already understands it.
- `hildegard.helper.approval` - `IApprovalService.Resolve`,
  `TApprovalBatchResult`, `TApprovalAsk`, `TApprovalOption`, `DefaultApprovalRule`.
- `hildegard.helper.workspace` - `TWorkspace.Resolve`/`Contains` for the trust
  boundary (the same one the shell tool uses).
- RTL: `SysUtils` (`FindFirst`/`FindNext`, `ForceDirectories`, `FileExists`,
  `DirectoryExists`), `Classes` (`TStringList`, `TFileStream`), `fpjson`.

Gap designed here: the tool handlers, the glob matcher, and path containment.

### Component Boundaries

- **Responsibilities:** argument parsing, path containment, approval resolution,
  file I/O, output bounding.
- **Dependencies:** agent (registry), approval, workspace, RTL.
- **Side effects:** reads and (on approval) writes inside the workspace.

### Data Flow

1. **Parse** the JSON arguments; missing required fields -> error.
2. **Resolve** the path against the root; refuse if it escapes.
3. **Approve** via `IApprovalService.Resolve`; deny -> error, no I/O.
4. **Act** (read/write/edit/list/glob/grep) with byte/result caps.
5. **Report** text in `AResult`, or `False` + `AError`.

### Integration Patterns

- Synchronous; no threads.
- The owning bootstrap (`THarnessSession`, `agent_cli`) creates one `TFileTool`
  with the workspace root and the shared `IApprovalService`, and keeps it alive
  for the process lifetime (the handlers are `of object` pointers).

## Validation Rules

### Input

- Required string args must be present and non-empty (after trim).
- `offset`/`limit`/`max_results` are non-negative integers; `0` means "default"
  for `limit`/`max_results`.
- `path` resolves under the root; `..` and absolute escapes are refused.
- `edit_file` requires `old_string` non-empty; `new_string` may be empty.

### Output Guarantees

- `read_file` returns the file's text (optionally a line range); no line-number
  prefixes.
- `list_dir` directories end with `/`; entries are sorted.
- `glob` results are workspace-relative and sorted.
- `grep` lines are `relpath:lineno: text`.
- Any truncated result ends with a `[truncated]` marker line.

## Error Handling

Failures return `False` with a human-readable `AError`:

- `missing required "path"` / `missing required "content"` / etc.
- `path escapes the workspace: <path>`
- `no such file: <path>` / `not a file: <path>` / `not a directory: <path>`
- `old_string not found` / `old_string is not unique; use replace_all`
- `no approval service configured`
- `approval error: <reason>` / `<denied reason>`

## Testing Requirements

### Unit Tests

- [ ] `read_file`: text content; `offset`/`limit`; missing file; directory;
      truncation at `MaxReadBytes`.
- [ ] `write_file`: creates parents; overwrites; reports bytes; refused write
      leaves no file.
- [ ] `edit_file`: single replace; `replace_all`; not-found; ambiguous (no
      `replace_all`).
- [ ] `list_dir`: entries sorted, dirs suffixed; recursive; missing dir.
- [ ] `glob`: `*`, `?`, `**`; sorted relative paths; no matches -> empty.
- [ ] `grep`: matches with `path:line: text`; `ignore_case`; `max_results` cap.
- [ ] Approval: each tool refuses on deny with the batch reason; no service ->
      error.
- [ ] Containment: `../` and absolute paths outside the root are refused.
- [ ] Registry: `Register` advertises six tools, each with `reason` required.

### Integration Tests

- [ ] With a memory approval store: an `exact` allow persists a rule and the
      second identical call is auto-allowed (no prompt).

### Leak Tests

- [ ] All handlers free their JSON/streams; `make test-leak` clean.

## Security Considerations

- Workspace containment is a guardrail, not an OS sandbox; symlinks are resolved
  and checked, and the limitation is documented (same stance as the command
  policy).
- Writes are atomic enough for v1: content is written to a temporary sibling and
  renamed, so a refused or failed write does not truncate an existing file.
- Output caps prevent a single tool call from flooding the model or ledger.

## Success Criteria

### Functional

- [ ] All contracts implemented; all validation rules enforced; all error paths
      handled.
- [ ] Every acceptance criterion in the FEATURE maps to a test.
- [ ] `make check` passes.

### Quality

- [ ] The six tools are registered by `THarnessSession` and `agent_cli`.
- [ ] No leaks; output bounded; paths contained.

## Future Considerations

- Regex grep; brace-expansion glob.
- `move`/`delete`/`mkdir`; diff/patch application.
- Streaming reads and binary handling.
