# TUI Clipboard

## Overview

The Harness TUI has no copy path of its own. Text leaves the screen only
through terminal-native selection, which the app's own SGR mouse reporting
(`?1000h`/`?1002h`/`?1006h`, enabled for scrolling, focus, and scrollbar
dragging) partially intercepts; today the workarounds are Shift+drag (or
Fn+drag in Apple Terminal), tmux copy-mode, or leaving the TUI and piping
CLI output. This feature adds an explicit, in-app copy mechanism built on
**OSC 52**: the application writes to the system clipboard by emitting
`ESC ] 52 ; c ; <base64>`, and the terminal emulator applies it — locally,
or on the user's machine over SSH.

The scope is deliberately narrow: targeted yank actions for the content
worth copying (the last assistant message above all), not general
screen-selection. Arbitrary selection stays the terminal's job, via the
documented Shift+drag bypass.

## Problem Statement

An agent TUI produces copy-worthy content constantly — an assistant answer
to paste into a doc, a command snippet to re-run, an error to attach to an
issue — and today the only way to get any of it out is fighting the app's
own mouse reporting or dropping to a shell. The pain is not cosmetic:

- **The deployment story is remote.** The helper is installed on devices the
  user reaches over SSH. Terminal-native selection copies on the *remote*
  display's terms, and over SSH there is no shared clipboard at all — except
  OSC 52, where the terminal itself relays the bytes to the user's local
  machine. No other mechanism in the app's power reaches it.
- **The existing bypass is undocumented and fragile.** Shift+drag works in
  kitty, Ghostty, and Alacritty; Apple Terminal wants Fn+drag; some setups
  give no bypass at all. Nothing in the docs records this, so the workflow
  is folklore.

Applying the Ponytail ladder: the terminal relay (OSC 52) needs no
dependency at all — an escape sequence the encoder layer is already equipped
to emit, with OSC-consuming machinery proven by the OSC 11 theme detection.
The genuine gap is narrow: emit, bind, degrade gracefully. No clipboard
library, no native framework binding, no selection engine.

## Goals

- One keybinding copies the **last assistant message** to the system
  clipboard via OSC 52 (the primary use case: taking an answer somewhere
  else).
- Additional targeted yanks where cheap: last error block, and the visible
  tool-command line of the most recent tool block, as natural follow-ups
  (each is one binding; the SPEC may trim).
- Graceful degradation: on terminals that ignore or reject OSC 52, the
  action is a visible no-op (a status-bar hint), never an error.
- The existing bypasses (Shift/Fn+drag, tmux copy-mode, CLI pipes) are
  **documented** in the TUI design language doc as the arbitrary-selection
  story.
- Keep the trust boundary intact: clipboard content is user-visible text and
  must never be logged (the input trace records bytes — clipboard *writes*
  are emits, but the hygiene rule is stated and enforced by review).

## User Stories

- As an **operator**, I want to press one key and copy the assistant's last
  answer, so I can paste it into my editor, issue, or doc without fighting
  mouse reporting.
- As an **operator over SSH**, I want the copy to land on my *local*
  clipboard, so working on a remote device does not strand content on it.
- As an **operator**, I want a clear hint when my terminal does not support
  clipboard writes, so I know to use Shift+drag instead of wondering whether
  the key worked.
- As a **developer**, I want the emit path unit-tested byte-for-byte and the
  bindings tested against an in-memory surface, so the feature is proven
  without a real terminal.

## Acceptance Criteria

### Functional Requirements

- [ ] A keybinding (SPEC decides the chord; candidates: `y` on a message, or
      a compose-free chord with a modifier) copies the last assistant message
      — the full text of the block, including wrapped content but excluding
      UI chrome (labels, stats) — by emitting `ESC ] 52 ; c ; <base64>`.
- [ ] The emitted sequence is byte-exact per the OSC 52 format (52, params,
      `;c;`, standard base64, BEL or ST terminator) — covered by a unit test
      on the encoder/emit path, mirroring the OSC 11 test pattern.
- [ ] The action shows feedback in the status bar on success ("copied") and
      a distinct hint when unsupported ("clipboard not supported — use
      shift-drag"), detected from the terminal profile if available, else
      stated optimistically with the hint on known-unsupported terminals.
- [ ] tmux compatibility is documented (and, if trivial, handled): tmux
      requires `set-clipboard on` to forward; the docs say so. No
      tmux-specific probing in v1 unless the SPEC finds a cheap way.
- [ ] A second targeted yank (last error block) follows the same emit path
      and binding pattern, added only if the SPEC keeps it.
- [ ] Arbitrary selection is NOT reimplemented; the design-language doc
      gains a "copying" section documenting Shift/Fn+drag bypass, tmux
      copy-mode, and the new yank bindings.

### Non-Functional Requirements

- [ ] Zero dependencies: no clipboard library, no framework binding — the
      feature is bytes on a tty, fitting the TUI's no-new-deps rule.
- [ ] The payload is bounded: cap the base64 payload (SPEC picks, ~64 KB)
      with a hint when a block exceeds it, so a pathological paste-into-
      terminal is never generated.
- [ ] Log hygiene: clipboard content never enters the input trace, the
      session ledger, or error output.
- [ ] `make check` passes (functional tests plus the leak gate); no new
      leaks from the encoder path.

## Success Metrics

### Quantitative

- Copy-last-answer works in kitty, Ghostty, and WezTerm without
  configuration; works in tmux with `set-clipboard on`; degrades to a clean
  hint in Apple Terminal (no OSC 52 support).
- Over SSH (kitty/Ghostty/WezTerm local side), the copied content lands on
  the local clipboard — the deployment-story smoke test.
- Emit cost per copy is microseconds; no repaint is triggered by the emit.

### Qualitative

- "Copy the answer" stops being a workaround hunt and becomes a keypress.
- The mouse-reporting conflict is documented instead of discovered.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse the existing OSC machinery (`tui.encoder`/`tui.surface.video`
  for emits; `input.decode`'s whole-sequence OSC consumption is the model
  for correctness), not a new escape-sequence layer.
- Base64 comes from FPC's own RTL (`EncodeStringBase64`) — no dependency.
- The feature lives in the TUI Harness scope: keybindings join the existing
  focus/chord system, status feedback joins the existing status bar.

### Non-Goals

- No general text selection or native scrollback integration — the terminal
  (or tmux) owns that, via Shift+drag / copy-mode; we document, not rebuild.
- No native clipboard bridge (`NSPasteboard`/X11/Wayland bindings): OSC 52
  covers local and remote; a native bridge adds platform code for no gain.
- No clipboard *read* (paste) in v1 — bracketed paste already covers input.
- No sync of selection to clipboard automatically (no "copy on select");

  copies happen on explicit yank.

## Notes

- **ICE score: Impact 7, Confidence 8, Ease 8.** High value per line of code;
  the emit machinery exists, the risk is terminal support spread, which
  graceful degradation absorbs.
- Sequencing: small enough to slot after the paste-bug fix and before or
  parallel with Session Handoff; nothing here blocks the Remote Agent Link,
  but the SSH story makes the two feel like siblings.
- Related open item: `TUI_Harness/PASTE_BUG.md` (paste-*in* path); this
  feature is copy-*out* and independent of it.
