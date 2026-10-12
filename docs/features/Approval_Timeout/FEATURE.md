# Approval Timeout

## Overview

An approval ask that no one answers is **not** a denial. It is reported as a
timeout, and the auto-deny applies only to a **headless** run — a session with no
connected client. A connected client (the TUI, or another) owns the timeout.

## Problem Statement

Two problems, one root: the session treated every unanswered ask as an operator
decision.

- A timeout produced `Allowed = False` with no marker, so the tool reported
  **"denied by operator"** for a call the operator never saw — blaming the
  operator for a timeout.
- The session auto-denied after a fixed wait regardless of whether a client was
  attached, so a TUI that was simply slow (or the operator, mid-thought) lost the
  call.

## Decision

1. **A timeout is a timeout.** `TApprovalChoice` carries `TimedOut`; a timed-out
   ask is reported as *"approval timed out (no operator response)"*, never as
   *"denied by operator"*.
2. **The auto-deny is headless-only.** A session with no connected client may
   auto-deny so an unattended run does not block forever.
3. **A connected client owns the timeout.** When a client is attached, the
   session waits **indefinitely** for a response — the client decides.
4. **A crashed client is the session's cleanup.** If the TUI dies or is
   restarted, session recovery/cleanup presides (the pending ask is resolved by
   the session, not left hanging).

## Implementation

- `hildegard.helper.approval` — `TApprovalChoice.TimedOut`; the denial reason
  distinguishes a timeout from an operator denial.
- `hildegard.helper.harness.turn` — `TApprovalGate.Ask` sets `TimedOut` on a wait
  timeout (a `WaitFor` that returned `wrTimeout`).
- `hildegard.helper.harness.view` — `THarnessSessionConfig.ApprovalTimeoutMs`
  (0 => wait indefinitely).
- `hildegard.helper.harness.session` — the gate uses the configured timeout.
- `hildegard.helper.session.runtime` — sets `ApprovalTimeoutMs := 0`: the runtime
  serves connected clients, which own the timeout.

## Acceptance Criteria

- [x] A timed-out ask is reported as a timeout, not a denial.
- [x] A connected session waits indefinitely (the runtime sets the gate timeout
      to 0 on attach).
- [x] A **headless** run (no client) auto-denies: the runtime starts at
      `DefaultApprovalTimeoutMs` and reverts to it when the last client leaves.
- [x] A client that crashes or disconnects resolves the pending ask (the
      session's cleanup presides, `CancelAsTimeout`), and the runtime reverts to
      the headless auto-deny.

## Notes

- Complete: the mechanism (`TApprovalChoice.TimedOut`, `TApprovalGate.SetTimeoutMs`
  / `CancelAsTimeout`) plus the runtime wiring (headless default at start, 0 on
  attach, `CancelAsTimeout` + revert on the last disconnect).
