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
  only), `any`, `never` (deny).
- The segment's `Summary` includes its redirects (`echo x > out.txt`), because
  the operator must see the effect.

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
| `cat`, `grep`, `rg`, `find`, `jq`, `wc`, `head`, `tail`, `sort`, `uniq` | reads only (no ask) |

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
