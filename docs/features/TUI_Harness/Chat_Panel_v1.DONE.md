# Implementation Plan: Chat Panel v1

**Spec:** [Chat_Panel_v1.SPEC.md](Chat_Panel_v1.SPEC.md)
**Status:** Implemented. `make check` green (473 tests, leak-clean).
**Feature:** [FEATURE.md](FEATURE.md)

TDD throughout; `make check` before moving on. Update this file as tasks
complete.

## Phase 1 - Surface helpers

- [x] **1.1** Tests: `PutCh` places one cell; `PutText` places a string; both
      clip outside the surface bounds and advance by display width.
- [x] **1.2** Add `PutCh`/`PutText` to `hildi.tui.surface`.

**Files:** `src/hildi.tui.surface.pas`, `tests/test_tui_surface.pas`.

## Phase 2 - Chat stream

- [x] **2.1** Tests: add/clear/count/item access; `SetText`/`AppendText` change
      the measured height; a user bubble, an assistant line, a collapsed and an
      expanded thought/tool block each render their chrome on `TSurfaceMemory`;
      a click toggles and fires `OnToggle`; the thinking block animates.
- [x] **2.2** Add `src/hildi.tui.chat.pas` with `TChatKind`,
      `TChatItem` and `TChatStream`, moved from the demo and made mutable.
- [x] **2.3** Tests: adding items keeps the newest visible; `Clear` empties it.

**Files:** `src/hildi.tui.chat.pas`, `tests/test_tui_chat.pas`,
`tests/hildi_tests.pas`.

## Phase 3 - Compose and chat panel

- [x] **3.1** Tests: `NeededHeight` grows with wrapped text; Enter submits and
      clears; Shift+Enter adds a line; the info line renders.
- [x] **3.2** Add `src/hildi.tui.compose.pas` with `TComposeBox`.
- [x] **3.3** Tests: the compose overlays the messages panel without reflowing
      it; the status line and CTA render; `SetComposeActive(False)` stops input
      while keeping the text.
- [x] **3.4** Add `src/hildi.tui.chatpanel.pas` with `TChatPanel`.

**Files:** `src/hildi.tui.compose.pas`,
`src/hildi.tui.chatpanel.pas`, `tests/test_tui_compose.pas`,
`tests/test_tui_chatpanel.pas`, `tests/hildi_tests.pas`.

## Phase 4 - Harness wiring

- [x] **4.1** Tests: a streamed turn renders into the panel and re-enables the
      compose; a tool call renders a tool block; an error renders an error block;
      the approval modal still resolves; one frame per step.
- [x] **4.2** Rewire `THarnessApp`: build the panel, replay history into the
      stream, map `TTurnEvent` to blocks, drive the thinking indicator, and set
      the status line from the workspace.
- [x] **4.3** Delete `hildi.tui.conversation.pas` and its tests once
      nothing uses them.

**Files:** `src/hildi.harness.app.pas`, `tests/test_harness_app.pas`,
`src/hildi.tui.conversation.pas`, `tests/test_tui_conversation.pas`.

## Phase 5 - Demo adoption

- [x] **5.1** Replace the demo's private chat/compose/column classes with the
      library widgets; delete the copies.
- [x] **5.2** Scripted pty capture: the demo still renders the design (bubbles,
      thought/tool blocks, overlay compose, scrollbar in the border).

**Files:** `examples/tui_layout_demo.pas`.

## Phase 6 - Verification and close-out

- [x] **6.1** `make check` green (tests + leak gate).
- [x] **6.2** `make tui-agent` runs the panel; scripted capture of a turn.
- [x] **6.3** Update `docs/features/FEATURES.md` and the TUI Harness `FEATURE.md`
      application section.
- [x] **6.4** Rename this file to `Chat_Panel_v1.DONE.md` and record deviations.

## Dependencies and order

Sequential: 1 unblocks 2; 2 and 3 unblock 4; 4 unblocks 5 (the demo adopts the
library); 5 and 6 close it out. Phase 1 can run in parallel with nothing else
(it is a two-function change).

## Risks

- **Behaviour drift from the demo.** The demo is the design reference; the
  extraction must not change what it renders. Mitigation: keep the render code
  as-is where possible and diff the demo's pty capture before and after.
- **Streaming into a laid-out stream.** Appending text changes an item's height,
  which re-lays out the column and can fight the sticky bottom. Mitigation:
  `FollowBottom` on every mutation and a test that the newest block stays visible.
- **Harness test coupling.** `test_harness_app` asserts on rendered text; the
  panel changes what that text looks like. Mitigation: update the assertions to
  the new blocks rather than loosening them.

## Deviations from the SPEC

- **Tool blocks.** Collapsed tool blocks use a *thin* rule in full contrast
  (not the dimmed rule and heavy edge first drafted), and the block's title is
  the model's stated reason rather than the tool name, so collapsed tool lines
  read as a story of decisions. The tool name and arguments moved into the body.
- **`ckError`.** Errors needed their own kind to render in the error colour; the
  SPEC's contract now lists it.
- **`Remove`.** The thinking indicator's lifecycle needs a block to be dropped,
  so `TChatStream.Remove` was added.
- **Status line.** It shows `workspace   state`; the session id and model moved
  to the compose info line and the workspace.
- **History replay.** Session history maps to blocks by role (user, tool, system,
  assistant) rather than to labelled lines.

## Follow-ups

- **LLM metrics (collect-only).** The loop keeps no usage data today: the SSE
  parser drops `usage`, the request does not ask for it
  (`stream_options.include_usage`), and only whole-turn `ElapsedMs` is carried.
  A separate spec should parse usage into a normalised `TTokenUsage` (prompt,
  completion, total, cached/miss across the OpenAI, DeepSeek and
  Anthropic-gateway spellings), time each LLM and tool call, and carry both
  through `TTurnEvent`. The panel should *collect* it first; the stats line can
  show it once the layout is decided.
- **Phase 5.** `examples/tui_layout_demo.pas` still carries its own copies of the
  chat/compose/column classes.
- A file/diff viewport pane beside the chat panel.
- Editing files from the TUI (the editor panel adopting `TTextEdit`).
