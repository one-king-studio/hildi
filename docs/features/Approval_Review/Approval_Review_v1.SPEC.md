# SPEC: Approval Review v1

**Related:** [FEATURE.md](FEATURE.md)

## 1. The ask data (phase 2)

```pascal
TApprovalAsk = record
  Summary: string;          // today: the segment text
  Reason: string;
  Subject: TApprovalSubject;
  Options: TApprovalOptionArray;
  Covers: TApprovalSubject;
  HasCovers: Boolean;
  { New: the whole command and the span the operator is approving. }
  Script: string;           // '' when unknown (older producers)
  FocusStart, FocusLen: Integer;   // 1-based byte offset, 0 = no focus
end;
```

- Producers: `BuildAsks` (the splitter) fills `Script := ACommand` and the
  segment span; the tier fills it from the parsed command's span.
- The splitter's tokens need `Start`/`Len` (the tokenizer knows them), so
  `TCommandSegment` gains `Start`/`Len`; the tier's AST needs a `TCommand` span
  (the lexer already tracks offsets; the parser records the first and last
  token's range).
- `session.protocol` encodes `script`, `focus_start`, `focus_len` additively
  (absent = no focus, so older clients still render).

## 2. Redirects are file effects (phase 1, shipped)

| Operator | Ask |
|---|---|
| `>`, `>>`, `>|`, `2>`, `2>>`, `1>`, `1>>`, `&>`, `&>>` | `file:write` for the target |
| `<` | `file:read` for the target |
| `<<`, `<<-`, `<<<` | none (a delimiter, not a path) |
| `<&`, `>&` | none (an fd duplication) |

- The target is resolved like any path (against the effective cwd, with `cd`
  tracked) and must be inside the workspace; an outside target keeps the
  `path:` ask.
- The subject is `Path = <workspace-relative>`, `Params = [<relative>]` — the
  file tools' shape.
- Options, mirroring `TFileTool.Approve`:
  `once`, `exact` (`Params = [rel]`), `dir` (`Directory`), `ext`
  (`Extension`, writes only), `dir_ext` (`Directory` + `Extension`, writes
  only), `any`. There is no `never`: a persistent deny is a rule in the store
  (the `aeDeny` effect), not an option the dialog offers; denying the prompt is
  the per-call answer.
- The segment's `Summary` includes its redirects (`echo x > out.txt`), because
  the operator must see the effect.

## 2a. Pure commands (shipped)

`hildegard.helper.command.pure.IsPureCommand` names the commands that produce
text from their own arguments and nothing else:

`echo`, `printf`, `true`, `false`, `basename`, `dirname`.

- They raise **no command ask**, on both executors (`BuildAsks` skips the
  segment; the tier's gate skips the command ask).
- Their **redirects are still asked**: the interpreter records the command's
  expanded `Reads`/`Writes` in `TShellCall`, and the gate raises the file asks.
- `test`/`[` is not pure (it inspects the filesystem); neither is anything that
  reads, lists, or writes. The rule is "no filesystem, no stdin, no information
  about the machine", not "harmless name".

The tier's gate asks, in one batch: the command (unless pure) + `file:write`
for every write redirect + `file:read` for every read redirect. An empty batch
allows without a prompt.

## 2b. The effect-scoped gate (tier, shipped)

`hildegard.helper.shell.effects.ComputeEffects(Name, Args, out Reads, out
Writes, out Known)` maps a builtin command to the files it will read and write,
positionally (grep's first operand is a pattern, `cp`'s second is the
destination) and without touching the filesystem:

| Effects | Commands |
|---|---|
| reads | `cat`, `head`, `tail`, `wc`, `grep`, `rg`, `sed` (without `-i`), `awk`, `jq`, `sort`, `uniq`, `cut`, `ls`, `find`, `test`/`[` (file tests), `cp`'s source |
| writes | `sed -i`, `tee`, `rm`, `mv`, `cp`'s destination, `mkdir`, `touch` |
| none | `echo`, `printf`, `true`, `false`, `basename`, `dirname`, `tr` (stdin only) |
| unknown | `tool`, `mcp`, and anything not in the table |

The tier's gate then asks, in one batch:

- one `file:write` / `file:read` ask per distinct effect (argument effects and
  redirect effects), with the file tools' options;
- the **command ask only when `Known = False`** (the effect cannot be named);
- nothing at all when the effect list is empty.

A previous grant is matched by the approval service, so a covered effect never
prompts: **the grant is the scope**.

The process path keeps the command-level asks for now (a spawned program's
effects are not knowable); bringing it to the same model is phase 3.

## 3. The dialog (phase 2)

- When `Script <> ''`, the body renders the script instead of `Summary`,
  wrapped to the content width, **scrolled** so the focus span is visible.
  PageUp/PageDown (or the scroll keys the modal already uses) move it.
- The focus span is drawn with the bold/active attribute; everything else
  normal. A marker (e.g. `▸`) sits in the gutter on the focus line.
- The modal's height is capped by the terminal; the scroll offset starts at the
  focus line's block.
- `Summary` remains the fallback when `Script` is empty.

## 4. Known effects per command (phase 3)

The tier parses the command, so it can name the file effects a command *will*
make before running it:

| Command | Effects |
|---|---|
| `sed -i` | `file:write` for each file operand |
| `tee` | `file:write` for each file (append when `-a`) |
| `rm` | `file:write` (delete) for each operand |
| `mv` | write for both operands |
| `cp` | write for the destination |
| `mkdir`, `touch` | write for each operand |
| `cat`, `grep`, `rg`, `find`, `jq`, `wc`, `head`, `tail`, `sort`, `uniq` | reads only (the command ask covers them; no extra ask) |

Redirects are already asked this way on both executors (`TShellCall.Writes` /
`Reads`, filled by the interpreter). The table above is for effects that are
not redirects.

These asks are raised in the same gate call as the command ask, before the
command runs. Anything the table does not know falls back to the command ask
alone (never a silent write).

## 5. Bucketing (phase 4)

When several effects share a ref, the options can be shared: one `dir` option
covering every effect under it, one `ext` option covering every effect with
that extension, and a `dir_ext` for the pair. A batch that is all reads is one
`file:read` ask listing its paths; a batch with writes is one `file:write` ask
per distinct directory/extension bucket. The subject carries the paths (the
file tools' `Path` is singular, so a bucket uses `Params` for the paths and a
`Directory`/`Extension` for the scope).

Open question: whether a bucket ask lists every path in its summary (which can
be long) or the scope it covers — the latter reads better and matches the
grant, but hides the specific files.

## Testing

- `test_command_tool`: the redirect summary includes the redirect; `>` yields a
  `file:write` ask with the full option set; `<` yields `file:read` without
  `ext`; `2>&1` yields no file ask; an outside redirect keeps `path:`.
- Phase 2: the splitter span and the modal's scroll/focus rendering.
- Phase 3: `sed -i`, `tee`, `rm`, `mv`, `cp`, `mkdir`, `touch` ask for their
  targets before running; a denied file ask stops the command before it runs.
- Pure commands raise nothing (both executors); `echo x > f` raises only the
  file ask.
