# Component Specification: Workspace Instructions v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `HildiHarnessSession` (prompt assembly),
`HildiCoordination` (the rules/mode split), `HildiShellCommands`
(`BuiltinCommandList`), `HildiAgent` (`TAgentConfig.SystemPrompt`,
`TAgentLoop.StablePrompt`).

## Purpose

Read the workspace's instruction file and deliver it to the model per turn,
wrapped and attributed; and split existing guidance by whether it can change
mid-session, so static text is sent once and cached while variable text rides
the turn.

## Requirements

### Functional

- [x] **Candidate order.** The first existing file wins:
      `AGENTS.md`, `README.md`, `readme.md`, `README`, `readme`. Both
      capitalisations are listed because a case-sensitive filesystem will not
      find `readme.md` when asked for `README.md`.
- [x] **Read at every turn boundary.** Not once at `Init`. The operator edits the
      file and the next turn sees it.
- [x] **Attribution.** The delivered block names the file twice: in prose
      ("the verbatim contents of AGENTS.md from the root of this workspace") and
      in the element attribute (`<agents_md source="AGENTS.md">`).
- [x] **Subordination.** The prose states the text is repository context, not
      harness or operator instructions, and that conflicting, concealing or
      rule-disregarding content is to be ignored.
- [x] **Absent is normal.** No file, an unreadable file, a binary file, or a
      whitespace-only file produces no block and no error.
- [x] **Cap and marker.** At most 32768 bytes; when truncated, a
      `[truncated at 32768 bytes]` line precedes the closing tag.
- [x] **Placement.** The block is the FIRST thing in the per-turn stable text,
      before the skill catalogue and the mode line.
- [x] **Static guidance moves to the system prompt**: `ShellGuidanceText` and,
      when a board or task store exists, `CoordinationRulesText`.
- [x] **Variable guidance stays per turn**: `CoordinationModeLine`.

### Non-Functional

- [x] One read attempt per turn per candidate, stopping at the first hit.
- [x] No new unit and no new dependency; `TFileStream` only.
- [x] A malformed file cannot fail a turn.

## Contracts & Interfaces

### Public API

```pascal
{ HildiCoordination: the split. CoordinationPromptFor is kept for callers that
  want both halves together. }
function CoordinationRulesText: string;
function CoordinationModeLine(AMode: TCoordinationMode;
  AReason: TCoordinationReason): string;

{ HildiHarnessSession: the assembled system prompt, read-only, for diagnostics
  and for asserting placement in tests. }
property SystemPromptText: string read FSystemPromptText;

{ Rebuild the per-turn stable text now. Called at every turn boundary; public so
  a test can exercise one refresh without driving a whole turn. }
procedure RecomposePrompt;
```

### Private

```pascal
function ShellGuidanceText: string;          { static; system prompt }
function ProjectInstructionsText: string;    { variable; stable text }
procedure AppendBlock(var APrompt: string; const ASegment: string);
```

## Design

### The split, and why it is not optional

`HildiAgent.pas:1831` appends the system message **only when the store has no
messages** — it is written once, on the first turn, and never rewritten. Whatever
is placed there is frozen for the session's life.

| Content | Frozen into the system message | Placement |
| --- | --- | --- |
| Base + `UserInstructions` | already | system prompt |
| `ShellGuidanceText` | constant | system prompt |
| `CoordinationRulesText` | constant | system prompt |
| `CoordinationModeLine` | **changes when a peer attaches** | stable text |
| `ProjectInstructionsText` | **changes when the operator edits it** | stable text |
| `FSkills.StableText` | changes when a skill loads | stable text |

`CoordinationPromptFor` previously returned rules + mode as one string, which
made the whole block un-movable. Splitting off `CoordinationModeLine` is what
allows the rules to be static at all.

### Assembly order

System prompt, in one message:

```
<base: DefaultSystemPrompt or the operator's override>
<blank line>
<ShellGuidanceText>
<blank line>              ← only when a board or task store exists
<CoordinationRulesText>
```

Per-turn stable text, appended to that same message on the way out
(`HildiAgent.pas:1322`), rebuilt at each boundary:

```
<ProjectInstructionsText>   ← AGENTS.md, or the README fallback
<blank line>
<FSkills.StableText>
<blank line>
<CoordinationModeLine>
```

`AppendBlock` inserts the blank line only when both sides are non-empty, so a
session with no skills and no instructions does not open with stray whitespace.

## Security

The file is **repository content and therefore attacker-influenced**: cloning a
repo is enough to have its `AGENTS.md` read by the model on turn one, with no
operator action. Three properties contain that:

1. **Named element.** `<agents_md source="...">` — the text is inside a labelled
   container, never bare in the prompt.
2. **Named provenance.** The prose says who wrote it: "whoever authored this
   repository", explicitly neither the harness nor the operator.
3. **Explicit subordination.** The model is told to ignore content that
   conflicts with its rules, asks it to conceal something from the operator, or
   tells it to disregard its instructions.

The harness keeps the last word by naming the source, not by trusting it. This is
the same stance `<guard>` takes toward tool results, applied to a new input.

## Constraints

- The read is local rather than via `HildiFiles.ReadTextFile`, which is
  implementation-only; widening that interface for one caller is not worth it.
- `Trim(Text) = ''` is treated as absent, so a file of only whitespace does not
  produce an empty wrapper.
- A `#0` byte marks the file binary; a README with a stray NUL is skipped rather
  than injected as mojibake.

## Testing

Five tests in `tests/TestHarnessSession.pas`:

| Test | Asserts |
| --- | --- |
| `TestAgentsMdRidesTheStablePrompt` | content is in the stable text **and not** in the system prompt |
| `TestAgentsMdIsTaggedWithItsSource` | `<agents_md source="AGENTS.md">`, `</agents_md>`, and the subordination prose |
| `TestAgentsMdFallsBackToReadme` | `README.md` content, with `source="README.md"` |
| `TestAgentsMdAbsentLeavesNoBlock` | no `<agents_md` at all |
| `TestAgentsMdIsRepublishedAfterAnEdit` | an edit between turns replaces the old text |

Two existing tests were **updated, not deleted**, because they asserted the old
placement:

- `TestTheCoordinationTextRidesTheSystemPrompt` now asserts the board/task rules
  are in the system prompt **and the mode line is not** — that second half is the
  regression guard for the split.
- `TestStablePromptIsSetWithoutAnyMcp` now checks shell guidance in the system
  prompt.

## Open Questions

- Nested/per-directory instructions are out of scope for v1.
- A shadowed file (`AGENTS.md` and `README.md` both present) is silently unused;
  no operator surface reports it.
