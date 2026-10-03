# Session Handoff

## Overview

Today a session belongs to exactly one process, and nothing in the store knows
or cares which one. Two processes can open the same session, interleave writes
to its ledger, and corrupt the user's mental model of what the agent is doing.
This feature makes session ownership **explicit and exclusive**: every active
session has exactly one **holder**, a process that has acquired a lease on the
session and heartbeats to keep it. A second process - a second TUI, or a
headless runner - that wants the session must either **observe** it (a
read-only tail of the live event stream) or **take it over** through an
explicit, user-visible **handoff**.

The feature also introduces the **headless session** as a first-class mode: a
fully detached process that launches with no TTY, registers itself in the
store, creates a session, binds to it, and runs turns to completion without
any user interaction. It reports everything to SQLite as it goes. It cannot be
quietly taken over; it participates in the same handoff protocol as a TUI.

The store is the broker. Holder, requester, and observers are all local
processes that already share one SQLite database, so every step of the
protocol - acquire, request, accept, release, observe - is a row in a table.
No sockets, no IPC daemon, no discovery.

## Problem Statement

Sessions and the ledger assume a single writer. Nothing prevents two TUIs from
restoring the same session, and nothing lets an agent run unattended: today
the harness is always attached to a terminal and dies with it.

Both gaps are the same gap. A session needs an owner of record, a way for that
ownership to be transferred politely, and a way for bystanders to watch
without holding a pen. Once those exist, a detached process becomes just
another holder - one that happens to have no UI - and "run this job headless,
then pick it up in my TUI later" becomes a supported flow instead of an
accident.

Applying the first rung of the Ponytail ladder: sessions, the ledger, the
approval engine, the turn worker with interrupt, and the approval modal all
exist. The genuine gap is narrow - a lease table, a heartbeat, a handoff state
machine, an event feed, and a headless entrypoint. We should build exactly
that and nothing more: no IPC layer, no session server, no remote sessions.

## Goals

- Guarantee **at most one live holder** per session, enforced by the store.
- Let a detached, headless process own a session and run it without a TTY.
- Make takeover **explicit and consensual**: the holder is asked, the turn is
  drained, the ledger is never forked.
- Give non-holders a safe way to **watch** a live session (observe mode).
- Detect dead holders (crash, kill -9) and let a new process recover the
  session cleanly.
- Lay the **driver abstraction** that Remote Agent Link will later plug into:
  a session has one driver (this TUI, a headless runner, later the outbound
  link) plus any number of observers.

## User Stories

- As an **operator**, I want to launch the agent headless and detached (`…
  &`, a launcher, a job scheduler), so work continues with no terminal open,
  and I want its progress recorded in the same session history I already
  read.
- As an **operator**, I want to open a headless session's conversation in my
  TUI and *take it over*, so I can steer the agent that has been working
  unattended.
- As an **operator at a second TUI**, when I open a session that another TUI
  already holds, I want to be told and offered a handoff request, so I never
  silently fight the other window for the same conversation.
- As the **holder** of a session, when another process requests a handoff, I
  want a modal asking me to accept or deny, so I am never evicted without
  consent.
- As the **holder** who accepts a handoff, I want my in-flight turn to finish
  or be interrupted cleanly and my ledger rows flushed, so the conversation is
  intact when the new holder adopts it.
- As the **outgoing TUI**, after releasing I want the screen to blank with a
  clear "session handed off" message, so I understand why my window went
  quiet and do not keep typing into a released session.
- As an **observer**, I want to tail a live session's streamed output
  read-only, so I can keep an eye on a headless run without owning it.
- As an **operator** who returns to a machine after a crash, I want a stale
  lease to be detected (not held hostage by a dead PID), so the session is
  recoverable without manual surgery on the database.
- As a **security-minded operator**, I want a headless agent to obey the
  approval engine with a deny-by-default policy for unattended asks, so a
  detached process is never a silent auto-approver.

## Acceptance Criteria

### Functional Requirements

Headless operation

- [ ] A headless launch (`--headless`) runs with no TTY: it registers itself,
      creates a session (or resumes an explicitly named one it can acquire),
      binds to it, and reports a `headless` holder kind in the store.
- [ ] The headless process runs turns to completion and every ledger row
      (turns, requests, messages) lands in the store exactly as a TUI turn
      does.
- [ ] A headless holder heartbeats its lease while alive and marks its
      holder row `exited` (with a terminal reason) on graceful shutdown.
- [ ] An approval ask in a headless session is decided by an explicit
      unattended policy that defaults to **deny**, recording the denial in the
      ledger like any other decision; the policy is configurable but never
      silently permissive.

Lease and liveness

- [ ] Acquiring a session is a single compare-and-set on the holder row: it
      succeeds only if no live lease exists (expired or released); two
      simultaneous acquirers yield exactly one winner.
- [ ] The lease binds `(hostname, pid, process_start_time)`, so a reused PID
      cannot impersonate a dead holder; liveness is heartbeat-based, with the
      start time as the impersonation guard.
- [ ] A lease that misses its heartbeat window is **stale** and can be taken
      over; the acquirer reports that the previous holder appeared dead and,
      in an interactive UI, asks for confirmation first.
- [ ] A graceful holder exit (normal quit, SIGTERM) releases the lease as part
      of teardown, leaving no running threads or allocated objects (the
      `make check` leak gate applies).

Handoff protocol

- [ ] A requester that wants a held session can only record a
      `handoff_requested` row naming itself; it cannot write to the session
      ledger while the lease is held by another process.
- [ ] The holder sees the request (an approval-modal-style dialog naming the
      requester) and can **accept**, **deny**, or let it time out; the
      decision is recorded.
- [ ] On accept, the holder finishes or interrupts the in-flight turn at the
      turn boundary (reusing Interrupt v1 semantics), flushes the ledger,
      writes `released`, and exits the session UI with the blank "session
      handed off" screen.
- [ ] The requester observes the release, acquires the lease, restores the
      session from the ledger (existing resume path), and continues; every
      message written before the handoff is present after it.
- [ ] A denied or timed-out request is visible to the requester, which
      remains in observe mode or exits; the original holder keeps ownership
      undisturbed.
- [ ] A handoff to or from a headless holder follows the same protocol; a
      headless holder applies its unattended handoff policy (default:
      auto-accept and drain) since no user is present to confirm.
- [ ] If the session had an in-flight turn that its dead holder never
      finished, the adopting holder marks that turn interrupted with an
      explicit error record, consistent with the existing interrupt path.

Observe mode

- [ ] A holder appends its streamed turn events (user prompt, assistant
      deltas or blocks, tool calls and results, errors, state changes) to a
      per-session event feed as they happen.
- [ ] An observer tails the feed read-only (a modest poll is acceptable,
      target 250 ms), renders the live stream, and can never execute tools,
      write ledger rows, or mutate approvals.
- [ ] Multiple observers can tail the same session concurrently without
      affecting the holder's behaviour or performance measurably.
- [ ] The event feed is bounded (pruned on session exit or capped per
      session), so a long-lived headless run does not grow without limit.

Multi-instance safety

- [ ] Opening an actively held session in a second TUI surfaces the handoff
      requirement before any writes; the second TUI proceeds to request a
      handoff or falls back to observe mode.
- [ ] Opening a session with no live holder (released, stale, or never
      held) acquires it transparently - the everyday single-user flow gains
      no extra prompts.
- [ ] All multi-process behaviour works against the same store file the
      project already uses, with WAL mode and a busy timeout set by the store
      itself, and short write transactions.

### Non-Functional Requirements

- [ ] Reliability: leak-clean under the heaptrc gate with heartbeats,
      observers, and handoff drains running; bounded retry/queue/feed state
      under sustained failure.
- [ ] Portability: builds and runs on macOS and Linux with Free Pascal 3.3.1;
      process start time is read per-platform (`kinfo_proc` / `/proc`); no
      macOS-unavailable primitives.
- [ ] Performance: holder overhead from heartbeats and event appends is
      negligible (< ~1% CPU); the observe poll does not spin; idle CPU stays
      near zero.
- [ ] Testability: lease, liveness, handoff, and feed logic are tested
      against the real store with faked processes and clock injection - no
      real second terminals in the suite.
- [ ] Observability: holder state transitions (acquired, requested, accepted,
      denied, released, stolen) are recorded as session events and visible in
      resume banners.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- A confirmed handoff completes (release visible to the requester, session
  restored) in well under a second once the in-flight turn is drained.
- A dead holder's lease is detectable as stale within a bounded window
  (heartbeat interval × missed-heartbeat allowance, target: seconds, not
  minutes).
- Four concurrent observers on an active session do not measurably slow the
  holder's turn throughput.
- Zero ledger rows are lost or duplicated across a handoff (the restore
  renders byte-identical history to what the outgoing holder streamed).

### Qualitative

- Ownership state is unambiguous: for any session, the store says exactly who
  holds it, who is waiting, and what was decided.
- No IPC daemon, no socket protocol, no new dependency - the store remains
  the single coordination point.
- The protocol reads the same for TUI and headless holders, so Remote Agent
  Link can adopt it later without a redesign.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse `hildegard.helper.session`/`.store` (ledger and restore),
  `harness.turn` (drain/interrupt), the approval engine, and the modal
  machinery; the protocol must not reimplement any of them.
- Store changes must be an additive migration (v2) - `session_holders` and a
  session event feed - with no reset of existing history; the store already
  enables WAL and a busy timeout (`DefaultBusyTimeoutMs`, `journal_mode=WAL`),
  which multi-process use relies on.
- Handoffs happen at turn boundaries; mid-stream takeover is expressly out of
  scope (force-interrupt is the escape hatch, via Interrupt v1).
- No sockets, no daemon process, no network transport: the store is the only
  coordination mechanism in v1.

### Business / Time

- No external deadline. This is a foundation feature, sequenced before Remote
  Agent Link because the link adopts its driver abstraction, not because of a
  date.

## Dependencies

### Internal

- `hildegard.helper.store` - a new additive migration (v2) adding
  `session_holders` and the per-session event feed; the existing WAL + busy
  timeout.
- `hildegard.helper.session` / `.store` - the ledger and the restore path the
  requester adopts.
- `hildegard.helper.harness.turn` - the turn worker and the drain/interrupt
  semantics reused by the handoff.
- The approval engine and the approval modal - the holder's accept/deny dialog.
- `hildegard.helper.tui.app` / `harness.app` - the TUI holder and its blank
  "session handed off" screen.

### External

- OS facilities to read a process start time (`BaseUnix` plus `sysctl`
  `kinfo_proc` on macOS, `/proc/<pid>/stat` on Linux).
- None beyond the existing vendored SQLite.

## Risks

- **Two acquirers both win the lease.** Mitigation: acquisition is a single
  compare-and-set on the holder row, so exactly one wins.
- **A reused PID impersonates a dead holder.** Mitigation: the lease binds
  `(hostname, pid, process_start_time)`; liveness is heartbeat-based and the
  start time is the impersonation guard.
- **The heartbeat window is wrong.** Too short steals a live session; too long
  strands a dead one. Mitigation: configurable interval and missed-heartbeat
  allowance with documented defaults; a stale lease is recoverable.
- **A same-user process seizes a headless session.** A headless holder
  auto-accepts handoff because no user is present. Mitigation: the store file is
  owner-only (`ChmodOwnerOnly`), the unattended approval policy is
  deny-by-default, and every transition is recorded.
- **Ledger writes while another holder owns the session.** Mitigation: the
  driver refuses ledger writes without the lease; only the holder of record
  writes.
- **A long-lived headless feed grows without bound.** Mitigation: the feed is
  capped and pruned on session exit.
- **Store-as-broker polls.** Mitigation: a modest poll (target 250 ms) with
  idle CPU near zero; no spin.
- **Mid-turn handoff timing.** Mitigation: drain at the turn boundary reusing
  Interrupt v1; force-interrupt is the escape hatch.

## Out of Scope

- Remote sessions over the network - that is Remote Agent Link, which should
  adopt the driver abstraction this feature introduces (one driver per
  session, observers read-only).
- Multiple concurrent writers to one session, and any merge of divergent
  histories.
- Mid-stream (non-boundary) takeover; force-interrupt via Interrupt v1 is the
  escape hatch.
- Windows support.
- A session server or supervisor process.

## Future Considerations

- Push notification instead of polling (a store trigger or a lighter channel).
- Cross-device handoff once Remote Agent Link exists.
- A richer observer view (the full chat panel in read-only observe mode).
- OS-keychain-backed holder identity.

## Notes

- **ICE score: Impact 8, Confidence 6, Ease 4.** Impact is high because
  ownership, headless operation, and observe mode unblock the link and make
  multi-instance use safe. Confidence is moderate because multi-process SQLite
  timing and per-platform process start time need calibration. Ease is low:
  lease, heartbeat, handoff state machine, event feed, and a headless entrypoint
  are all new.
- **Sequencing:** the driver abstraction (one driver, many observers) is
  introduced here and adopted by Remote Agent Link, so this lands before the
  link. It is independent of TLS Foundation.
- **Reuse note (Ponytail):** the store, the ledger and restore path, the turn
  worker with interrupt, and the approval modal all exist. The new pieces are
  the holder/lease table, the handoff state machine, the event feed, and the
  headless entrypoint.
