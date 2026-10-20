# Reasoning Doom Loop Detection

**Status: Parked** (ideated 2026-10-03 with the operator; recorded before the
spark faded). No SPEC, no TODO. To pick up: write the SPEC from the design sketch
below, then TDD. (The index lists this as *Proposed*; parked is the accurate
state, and this line is the one to trust.)

## Overview

A doom loop in a reasoning stream is the model circling: re-deriving the same
approach, re-stating the same plan, re-failing the same inference — with
drift. The text is *never verbatim* (that is what makes it a reasoning loop
rather than a tool loop), but its **structure repeats**: same argument shape,
same pivot ("wait, but that fails because…"), same re-entry ("let me
reconsider…"), cycling with a roughly stable period.

This feature adds a **detector** over the reasoning stream: it matches the
recent tail backwards against the turn's own recent history, keeps the
*parse* (not a compression ratio) as the diagnosis, and reports soft/hard
alarm signals to the turn loop. The detector is a pure, thread-local signal
source: it never modifies content, never gates tools, and never touches the
approval boundary.

## Problem Statement

The loop already bounds *tool* loops: a tool-call budget with soft
interception (`SoftToolLimit`, notice-and-resubmit) and a hard lock. But
reasoning has no equivalent guard — a model can burn its entire context
window circling in thought, and the only backstop today is the context cap
(`MaxContextTokens`), which ends the turn *after* the tokens are spent.

Worse, the two failure modes look identical from the outside: a long, busy,
streaming reasoning block that ends in a context-cap error. The operator
cannot tell "hard problem" from "merry-go-round" without reading it.

What is wanted is the LZ insight — **a compressor's match statistics are a
repetition detector** — used properly: not the ratio (a smoke detector that
cannot name what is burning), but the **parse** — which names the cycle.

## The design (ideation record — the SPEC's starting point)

### Core algorithm: deflate-style match pass over the tail, backwards in time

Rung-2 semantics (match the tail against history) with LZ77 mechanics:

- **Ring buffer** of the normalized reasoning stream (window N ≈ 16 KB).
- **Hash chains over 4-grams**: `head[hash] → chain of prior positions`;
  append-only, incremental maintenance as reasoning streams in.
- **Greedy parse of the tail** (last T ≈ 1–2 KB, re-parsed every ~1 KB of
  new reasoning): at each position, walk the chain (capped, deflate-style
  `max_chain` ≈ 32–64), take the longest match ≥ M (8 bytes), emit it, skip
  ahead.
- **The parse output is the diagnosis**:
  - `coverage` — fraction of the tail covered by matches (healthy reasoning
    is high-literal; a doom loop parses as ~90% matched),
  - `maxRun` — longest single match (a verbatim echo of an earlier block),
  - `dominantPeriod` — the mode of match distances: matches recurring at
    offset ≈ p name a **cycle of period p** directly (a periodic tail parses
    as one long match at offset = period — LZ's overlapping-match rule gives
    the period for free),
  - `literalRatio` — what is genuinely new.
- Chosen over a suffix array + LCP deliberately: we need the *tail's* best
  matches, not global SA statistics; hash chains give O(1) amortized
  append, no periodic rebuild, no RMQ — ~100 lines of pure Pascal, reusable
  buffers, leak-gate friendly, microseconds per parse.

### Normalization (where the craft is)

Before matching: lowercase ASCII, collapse whitespace, map digit runs to
`#`. This kills formatting drift and tick churn while preserving structural
repetition — the substance of a reasoning loop. **Must strip every
known-mutable field the stream emits** (timestamps, elapsed ms, spinner
frames), or every loop pulses "new" grams. Escalation path if byte-level
proves too loose: match over token-gram hashes instead of bytes (same
chains, different alphabet) — decided against the recorded-session corpus,
not up front.

### Alarm logic: trend + period sanity, never a single snapshot

- **Arm late**: no detection before ~8 KB of reasoning in the turn (tables
  and restatements live short).
- **Trend**: alarm when coverage is high **and rising across consecutive
  parses** with a **stable dominant period**. One high-coverage parse is a
  formula or a table; three consecutive growing ones is a loop.
- **Period band**: alarms on reasoning-scale periods (≈ 200–4000 bytes);
  tight short periods with bounded extent are table rows, not loops.

### Integration (reuses the loop's existing machinery)

- Taps the **reasoning stream events** the loop already emits; runs entirely
  on the turn worker thread; window/chain state is thread-local, no locks.
- `TAgentConfig` gains fields beside `SoftToolLimit`: window N, tail T,
  soft/hard thresholds, arm length.
- **Soft response**: inject a notice via the existing
  `InterceptToolCalls`-style mechanism — "your reasoning is cycling on the
  same approach (period ~p); change strategy or conclude" — the model can
  recover.
- **Hard response**: cancel at a loop boundary via the existing
  `CancelCheck` / Interrupt v1 semantics — no new interruption machinery.
- **Invariants**: the detector never modifies content and never gates
  tools; it is a signal source. No trust-boundary implications, no approval
  involvement (it reads what the helper already holds in memory).

### Out of scope / not this feature

- **Tool-call doom loops**: already detectable cheaply by signature
  (`tool name + normalized args hash` across turns) — a different, simpler
  mechanism on a different stream; may share the alarm plumbing later, but
  is explicitly not here.
- Compression ratio as the signal (paszlib or otherwise): kept only as a
  possible *validation* instrument against recorded sessions, never the
  detector — a ratio cannot name the period or localize the cycle.

## Why this shape (decisions worth remembering)

- **Keep the parse, not the ratio** — compression ratio is a smoke detector;
  the parse is a seismograph: coverage, max run, dominant period.
- **Hash chains, not suffix arrays** — the question is local (tail vs
  history), not global; chains are incremental and stream-friendly.
- **Normalization before matching** — reasoning loops are structural, not
  verbatim; the detector must see shape, not bytes.
- **Trend over snapshot, arm late, period band** — the false-positive
  guards that make it usable against legitimate restatement and tables.
- **Signal-only** — the loop's existing notice/interrupt machinery owns the
  response; the detector stays clear of trust boundaries by construction.

## When picked up, the SPEC must nail down

1. Window N, tail T, min match M, chain cap, re-parse cadence; memory cap
   for the gram/chain structures.
2. The normalization allowlist — exactly which mutable fields are stripped,
   with fixture examples from real reasoning streams.
3. Soft/hard thresholds and the arm length; calibration method against
   recorded sessions (the ledger's error-ended sessions are the labeled
   doom-loop corpus).
4. Whether the score surfaces in the status bar (operator visibility) or
   stays silent until an alarm fires.
5. `TAgentConfig` field names and defaults; the pure-function core's
   signature; the test corpus of loop-shaped and healthy streams.
6. Tool-signature loop detection as a separate small feature (same alarm
   plumbing, different detector) or explicitly deferred.

## Notes

- **ICE score: Impact 7, Confidence 6, Ease 6.** High operator value (turns
  an unreadable context-cap death into a diagnosed, interruptible loop);
  moderate confidence pending tuning against real corpora; small surface.
- Measured facts to respect: the loop's existing budget machinery
  (`SoftToolLimit` = 30 default, notice-interception, `CancelCheck`) is the
  response path; the reasoning stream already flows as events.
- Related: Agent Loop (budget/notice host), Interrupt v1 (hard response),
  Context Budget (the after-the-fact guard this complements),
  Session Handoff (headless holders are where nobody is watching the loop —
  strongest motive), and the ledger (the tuning corpus).
