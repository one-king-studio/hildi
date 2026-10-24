# Component Specification: Reply Metadata v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.markdown` (`TMarkdownParser`, block kinds),
`hildegard.helper.agent` (the completed-turn append, `DefaultSystemPrompt`),
`hildegard.helper.store` (migrations, the `messages` table),
`hildegard.helper.session.runtime` (the `teDone` boundary),
`hildegard.helper.tui.chat` (`TChatItem`, `ckAssistant`).

**Depended on by:** `Session_Modal_v1.SPEC.md` (the modal lists titles and
searches keywords).

## Purpose

Give every **substantive** assistant reply a small, machine-readable header — a
YAML frontmatter block carrying a `title` and a set of `keywords` — and turn that
header into (a) a persisted session title + per-reply keywords and (b) a
dedicated TUI presentation. The block is **metadata, never body**: it is stripped
before the markdown renderer ever sees the reply, and while the reply streams it
is suppressed until it closes.

The reply body itself is unchanged; the raw reply is stored verbatim so a session
replays from the raw message.

## Prior art and reuse

| Need | Existing unit | What changes |
| --- | --- | --- |
| Parse the body's markdown | `TMarkdownParser.Parse` | **none** — it never sees the frontmatter (stripped first) |
| Store the reply | `TConversationStore.Append` (`agent.pas:1233`, verbatim) | none — the raw reply is already kept |
| Session row | `TSqliteStore` migrations (newest = v9) | a v10 additive migration adds `title`/`title_override`; a new `reply_keywords` table |
| The completed-turn seam | `TSessionRuntime` `teDone` → `CommitCheckpoint` | extract + persist here |
| Render an assistant block | `TChatItem` (`ckAssistant`) via `TMarkdownView` | a metadata header (title + chips) above the body; the body source is the stripped text |
| System instruction | `DefaultSystemPrompt` / session `SystemPrompt` | add the format + flavor instruction |

No YAML dependency: extraction is a tolerant line scanner over the block.

## Requirements

### Functional

- [ ] A YAML frontmatter block is terminated by a later `---`, **or** tolerantly
      by a **blank line after block content** (the model often omits the closing
      fence; YAML frontmatter has no blank lines).
- [ ] The block is normally **leading** (first line `---`), but a model sometimes
      says something first and emits its frontmatter after it. A fence block
      beginning any line counts, and the text before it is **kept** as a preamble
      at the start of the body - dropping it would lose the reply's own words.
- [ ] A fence block is frontmatter **only if it carries a `title` or `keywords`
      key**. A bare `---` is an ordinary thematic break (or a table separator)
      and stays in the body, so a mid-reply rule is never mistaken for metadata.
      A key with an empty value (`title:` with nothing after it) is still
      frontmatter: presence is the signal, not a non-empty value.
- [ ] Extraction is a pure function over reply text: it yields a title, a keyword
      set, and the **body with the block removed**. Malformed input yields no
      metadata and the **unmodified** text (it never raises).
- [ ] The supported block grammar is minimal and tolerant: `key: value`,
      `key: [a, b, c]`, and `key:` followed by `- item` lines; keys are
      case-insensitive; **unknown keys are ignored**; `title` and `keywords` are
      the only keys read (the block is open-ended for the future).
- [ ] The runtime extracts at the completed-turn boundary (`teDone`), persists the
      title (per session, unless overridden) and the keywords (per reply), and
      never persists the block into the body the renderer draws.
- [ ] The raw reply is stored **verbatim** (block included) — the ledger's
      `messages` row is unchanged; the stripped body is a derived view.
- [ ] The TUI renders the extracted metadata through a dedicated presentation on
      the assistant item: a **title line** (accent) and **keyword chips**, drawn
      from `TTheme` roles — never through `TMarkdownView`.
- [ ] While a reply streams, a detected leading block is **suppressed** (its bytes
      are not shown) until the block closes; the metadata header then appears and
      the body streams normally. If the reply turns out to have no block, nothing
      is lost.
- [ ] A session's displayed title is the latest reply's `title`; a reply with no
      block leaves it unchanged. `title_override`, when set, wins.

### Non-Functional

- [ ] Extraction is O(reply length), allocation-light, and independent of the
      store and the model (unit-testable in isolation).
- [ ] No YAML or other dependency; no new unit outside the existing ones unless
      one is warranted (a small `hildegard.helper.replymeta` is acceptable).
- [ ] No leaks (heaptrc gate); `make check` green; macOS + Linux; FPC 3.3.1.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### The extractor (pure)

```pascal
unit hildegard.helper.replymeta;

type
  { The metadata a reply's leading frontmatter block carries, plus the body with
    the block removed. HasMeta is False when there was no leading block (Body is
    then the whole input, unchanged). }
  TReplyMeta = record
    HasMeta: Boolean;
    Title: string;
    Keywords: TStringArray;   // lowercased, de-duplicated, order preserved
    Body: string;             // the reply with the block stripped
  end;

{ Parse a reply. Tolerant: no leading block, an unterminated block, or garbage
  yields HasMeta = False and Body = ARaw. Never raises. }
function ExtractReplyMeta(const ARaw: string): TReplyMeta;

{ The streaming helper: feed the reply in chunks; it buffers only the potential
  leading block and reports what is safe to display. }
type
  TFrontMatterSuppressor = record
    State: (fmUndecided, fmInBlock, fmDone);
    Pending: string;   // bytes withheld while undecided/in-block
  end;
{ Feed a chunk. Appends any displayable text to AOut and returns True when the
  caller should render. While undecided/in-block, AOut is unchanged. }
function SuppressFrontMatter(var S: TFrontMatterSuppressor;
  const AChunk: string; out AOut: string): Boolean;
```

### Store additions (migration v10)

```pascal
type
  { Set the extracted (generated) title; ignored when an override is set. }
  function SetSessionTitle(const ASessionId, ATitle: string;
    out AError: TStoreError): Boolean;
  { Set or clear (AOverride = '') the operator override. }
  function SetSessionTitleOverride(const ASessionId, AOverride: string;
    out AError: TStoreError): Boolean;
  { The resolved title (override else extracted) and the two parts. }
  function SessionTitle(const ASessionId: string; out AResolved: string;
    out AError: TStoreError): Boolean;

  { Replace a reply's keyword set (by the assistant message id). }
  function SetReplyKeywords(const AMessageId: Int64;
    const AKeywords: TStringArray; out AError: TStoreError): Boolean;
  function ReplyKeywords(const AMessageId: Int64;
    out AKeywords: TStringArray; out AError: TStoreError): Boolean;
```

```sql
-- migration v10 (additive; newest today is v9)
ALTER TABLE sessions ADD COLUMN title          TEXT NOT NULL DEFAULT '';
ALTER TABLE sessions ADD COLUMN title_override TEXT NOT NULL DEFAULT '';
CREATE TABLE reply_keywords (
  message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  keyword    TEXT NOT NULL,
  PRIMARY KEY (message_id, keyword)
);
CREATE INDEX idx_reply_keywords_keyword ON reply_keywords (keyword);
```

### The prompt (the contract with the model)

```text
The system prompt gains, once:
  - open a SUBSTANTIVE reply with a frontmatter block:
        ---
        title: <short subject>
        keywords: [term, term, term]
        ---
    (3-8 lowercase keywords; a terse acknowledgement need not include a block)
  - use CommonMark with GFM pipe tables for the body
```

## Data flow

1. The model streams a reply. The TUI feeds each delta through
   `SuppressFrontMatter`; nothing of a leading block is displayed until it closes.
2. The turn completes (`teDone`). The runtime calls `ExtractReplyMeta(answer)`.
3. If `HasMeta`: `SetSessionTitle` (honours the override) and `SetReplyKeywords`
   against the assistant message id. The **raw** reply is already in the ledger.
4. The TUI item draws the metadata header (title + chips) and renders `Body`
   through the markdown view — which never contained the block.

## Validation and error handling

- No leading block, or one closed by neither a `---` nor a blank line:
  `HasMeta = False`, `Body = ARaw` (the suppressor flushes it at end of reply).
- Unknown keys / wrong value types: ignored; a partial block still yields the
  keys it did parse.
- A store error on persist: recorded as a session error; the reply is unaffected.
- The streaming suppressor must never drop body text: anything that is not a
  leading block is flushed to `AOut`.

## Testing strategy

- `ExtractReplyMeta` table-driven: no block; well-formed; `[a,b,c]`; `- item`
  list; unknown keys; unterminated; `---` only in the body; CRLF; empty title;
  duplicate keywords.
- The suppressor: chunk boundaries at every position of a block; a false `---`
  start (a rule later); no-block replies flush fully; nothing is lost.
- Store: title/override resolution; keywords replace (not append); cascade on
  message delete.
- The render: the assistant item shows the title/chips and the body without the
  block (headless, against `TSurfaceMemory`).

## Performance

- Extraction is linear and runs once per completed turn (not per delta); the
  streaming suppressor is linear and buffer-bounded by the block length.

## Open questions (settle at implementation)

1. Chip cap: show all keywords or the first N with a `+k` affordance?
2. Keyword normalization: lowercase + trim + de-dupe (chosen); hyphenation or
   stemming (out of scope)?
3. Does a keyword-bearing reply also get its keywords shown in the modal row, or
   only on the reply?
