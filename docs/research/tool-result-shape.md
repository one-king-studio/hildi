# Tool Results: Text, Not JSON, and Where a Diff Lives

**Status:** design note (not implemented)
**Related:** [File Tools](../../features/File_Tools/FEATURE.md),
[Tool Streaming](../../features/Tool_Streaming/FEATURE.md),
[Workspace Snapshots](../../features/Workspace_Snapshots/FEATURE.md),
[Sessions and Ledger](../../features/Sessions_And_Ledger/FEATURE.md)

Follows from a live smoke of the file tools, which found two things: a real
asymmetry between `json_read` and `json_edit` (fixed), and a design question
about what a write tool should return.

## The asymmetry (fixed)

`json_read` takes an RFC 6901 pointer (`/service/port`); `json_edit` took a bare
top-level key but called the parameter `pointer`. Setting `/service/port`
silently created a key literally named `"/service/port"` and reported
`{"written":true}` — a wrong edit that succeeds.

Fixed: `json_edit` now takes a real pointer (`JsonPointerSet`), the parent must
exist (a typo is `pointer not found`, not a new key), and a bare key is rejected
with a message naming the required form. `yaml_edit` already used a dotted path
(`service.port`), which is now the documented difference: JSON uses pointers,
YAML uses dotted paths, matching what each format's `read` returns.

## What a write tool returns today

Every mutating tool answers with a small JSON blob:

```
{"written":true,"path":"a.txt"}
{"applied":1,"rejected":0,"dryRun":false}
{"replaced":1,"path":"b.txt"}
```

Four problems:

1. **It is JSON in a text channel.** The model reads these as prose; the braces
   are noise. Meanwhile the read tools already return prose ("read a.txt (17
   bytes)").
2. **It is not renderable.** A TUI block shows `{"written":true,...}`. There is
   nothing to style and nothing to expand.
3. **It says *that* something changed, never *what*.** For an edit tool the
   interesting artefact is the change itself.
4. **It costs context for no information** — and the interesting part (what
   changed) would cost *more*, which is exactly why it should not go here.

## Recommendation: three separations

### 1. Tool results become Markdown, not JSON

A mutating tool returns one human sentence, styled by the existing markdown
renderer:

```
Wrote **a.txt** (39 bytes).
Applied 1 hunk to **sub/target.txt**; 0 rejected.
Replaced 1 occurrence in **b.txt**.
```

The model loses nothing (`written:true` only ever meant "it worked", which the
success of the call already encodes) and a block becomes readable and
renderable with no new code — the chat stream already renders markdown.

JSON is right for *input* (structured arguments) and wrong for *output* (a
sentence to a reader). The read tools already follow this; the write tools
should join them.

### 2. The diff is a display artefact, not a tool result

The model gets one sentence. The operator gets the diff. They are different
audiences with different needs, and conflating them is what would make an edit
tool expensive in context.

```pascal
TFileChange = record
  Path: string;          // workspace-relative
  Kind: TChangeKind;     // ckCreated, ckModified, ckDeleted, ckMoved
  Added, Removed: Integer;
  Diff: string;          // unified, bounded (e.g. 8 KiB)
end;
```

Captured at the one place every write already goes through — `WriteAtomic`
(8 call sites, all writes) — which is the leverage that makes this cheap: read
the old text on entry, keep the new text on exit, and compute a unified diff
once.

### 3. It rides the tool-result row, not the message content

Store it **beside** `mrTool`'s content, never inside it:

- a `tool_changes` table keyed by message id (a tool call can touch many files,
  so many rows per message) or a bounded JSON column on `messages`;
- **not** in `Content` — that is the prompt, and a diff there is permanent
  context cost for information the model does not act on;
- the live TUI and a resumed session then read the same rows, so the block
  renders identically (the invariant the streaming work already holds).

Bounded at both ends: the diff is capped when captured, and the row is not part
of the prompt at all.

## A fourth separation, worth saying

**File Tools owns the artefacts; Workspace Snapshots owns the history.**

This note only produces *what changed in this call*. Undo/redo across turns,
snapshots, and the changed-files view are Workspace Snapshots' job, and its
schema is the natural home for "the workspace at turn N". The clean seam:
File Tools writes the `tool_changes` row for the call it just made; Snapshots
reads those rows (or its own snapshot) to offer undo. Building the diff capture
now is not wasted work for Snapshots — it is its input.

## Granularity: two levels, and the shell is blind at the lower one

The snapshot is per **turn** (bounded, atomic, safe to undo). The *review* is per
**tool call** — a twenty-call turn read as one total hides which step went wrong,
and "what did this `file_search_replace` do?" is a different question from "what
did the turn do?".

- **Tool change** — one call (or one parallel batch), captured at `WriteAtomic`,
  stored beside the tool result, **zero** prompt cost.
- **Turn snapshot** — the boundary scan; the undo/redo chain and retention.

| | tool level | turn level |
| --- | --- | --- |
| edit tools (`file_write`, `file_search_replace`, `patch_apply`, …) | **complete** | complete |
| `run_command` (`sed -i`, a build, `git checkout`) | **blind** | complete |
| cost | one file read per write, bounded | a tree scan, incremental |

The asymmetry is the design's honest limit: the tool level sees only the tools
that go through `WriteAtomic`. A turn whose snapshot differs from the sum of its
tool changes has **unattributed** changes, and the UI should say so rather than
imply a shell call changed nothing.

**Attribution with parallel batches.** Each call keeps its own record (the call
id is known in the handler), and a batch's results arrive in call order, so the
blocks keep their attribution; the view can group the batch or list per call.

**Context cost stays zero** in both cases — the diff never enters the prompt.


## Cost, honestly

| piece | who | size |
| --- | --- | --- |
| Markdown tool results | Files + a formatter | small; touches 19 result strings |
| `TFileChange` + capture at `WriteAtomic` | Files | small-medium (one choke point) |
| A unified-diff helper | **already exists** — `hildegard.helper.patch` parses one | the render side reuses it |
| `tool_changes` table + migration | Store | medium (the usual schema reset) |
| TUI block rendering the diff | harness.app, chat | medium |
| Context cost | — | **zero** (never in the prompt) |

The expensive part is not the diff; it is the schema change. Worth doing when
Workspace Snapshots is picked up, so the schema is designed once with undo in
mind rather than twice.
