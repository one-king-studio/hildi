# Implementation Plan: Animation Clock

**Specs:** [Animation_Clock_v1.SPEC.md](Animation_Clock_v1.SPEC.md),
[Focus_Reporting_v1.SPEC.md](Focus_Reporting_v1.SPEC.md)

Each phase is independently testable and lands green. The registry (1–2) and the
chat counter (3) capture most of the win; focus reporting (5–6) finishes it.

## Phase 1 — The registry

- [x] **Implement** `TAnimationClock` in `src/hildegard.helper.tui.clock.pas`:
      `Register`/`Unregister`/`MinIntervalMs`/`Count`, and the process
      `AnimationClock` accessor.
- [x] **Implement** the `TWidget.SetAnimation`/`ClearAnimation` helper in
      `src/hildegard.helper.tui.widget.pas`.
- [x] **Test** `tests/test_tui_clock.pas`: register/replace/unregister;
      `MinIntervalMs` is the minimum; `<= 0` unregisters; unknown unregister is a
      no-op; `Count` tracks entries. Add the unit to
      `tests/hildegard_helper_tests.pas`.

## Phase 2 — The app rate

- [x] **Implement** `TTuiApp.FrameIntervalMs` (registry interval, else
      `IdleWaitMs`) and `GetAnimating` (registry non-empty); drive
      `NextFrameDelayMs` from it.
- [x] **Register every animating widget** (the app no longer discovers them):
      the panel's state sparkle, the spinner, and the progress bar.
- [x] **Test** `tests/test_tui_app.pas`: the frame interval follows the fastest
      registration; the idle wait when empty.

## Phase 3 — The chat stack counter

- [x] **Implement** `TChatStack.FAnimatingBlocks`, maintained on
      `Add`/`Remove`/`Clear`; `Animating` is O(1); `Advance` returns `False`
      immediately when none animate.
- [x] **Test** `tests/test_tui_chat.pas`: `AnimatingCount` tracks thinking blocks;
      `Advance` is a no-op with none; `Animating` is `False` with none.

## Phase 4 — The caret

- [x] **Implement** `TTextEdit.FBlinkIntervalMs` and register/clear the caret
      with the clock from `SetActive`.
- [x] **Test** `tests/test_tui_edit.pas`: `Active := True` registers at the caret
      interval; `Active := False` clears.

## Phase 5 — Focus reporting

- [ ] **Implement** `ikFocus` (appended last) and `TInputEvent.Focused` in
      `src/hildegard.helper.tui.input.pas`.
- [ ] **Implement** the `CSI I`/`CSI O` mapping in
      `src/hildegard.helper.tui.input.decode.pas`.
- [ ] **Implement** `CSI ? 1004 h` on init and `CSI ? 1004 l` on teardown in
      `src/hildegard.helper.tui.surface.video.pas`.
- [ ] **Test** the decoder mapping and the surface's emitted bytes.

## Phase 6 — Focus-aware animation

- [ ] **Implement** `TTuiApp.FTerminalFocused` and its `ikFocus` handling;
      `Animating` requires focus.
- [ ] **Implement** `TTextEdit.Blinking` (default `True`); the app sets it `False`
      on focus-out so the caret holds solid.
- [ ] **Test**: memory surface + scripted `ikFocus`: idle wait while unfocused,
      caret interval when focused; the caret stays solid while unfocused.

## Phase 7 — Documentation and completion

- [ ] Update `docs/features/FEATURES.md`, `HANDOFF.md`, and
      `docs/guidelines/tui-rendering.md` (the animation-clock rule).
- [ ] Measure idle CPU (focused and unfocused) on a large session; record it.
- [ ] Rename this file to `Animation_Clock_v1.DONE.md`.

## Ordering Notes

- Phases 1–4 are independent of 5–6 and can land first; they already remove the
  100 Hz idle loop.
- Phase 3 (the chat counter) is independent of the registry and can land alone.
- Phase 6 depends on Phase 5.
