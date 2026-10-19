# Research

Investigation notes. These are **not** specifications — they are what was learned
while deciding something, kept because the reasoning is expensive to reconstruct.
`docs/features/` holds what we build; `docs/guidelines/` holds how we work; this
folder holds what we found out.

A research doc is finished when its conclusion has landed somewhere durable
(a FEATURE, a SPEC, a guideline, a test). At that point it becomes *historical*:
still accurate about what it observed, no longer a description of the tree.

## Index

| Document | What it is | Status |
| --- | --- | --- |
| [vendored-engine-lessons.md](vendored-engine-lessons.md) | Nine transferable lessons from adopting a third-party engine, written for any vendored parser or runtime. The heaptrc + `atos` method. Why the boundary you already have is usually the cheaper fix. | **Live** — read before adopting any vendored component |
| [just-bash-and-the-builtin-shell-tier.md](just-bash-and-the-builtin-shell-tier.md) | A study of Vercel's `just-bash` (a bash implementation in the host: parser, interpreter, ~80 commands, virtual FS, ~60 limits) and what to borrow: the closed command set, direct dispatch, capability FS/network, parse-then-transform, and the limits checklist. The three-tier choice (linear / compound / transform) and a recommendation. | **Live** — the design input for a builtin command tier |
| [gocciascript-embedder-issues.md](gocciascript-embedder-issues.md) | The engine's own defect register: 47 items across ownership, lifecycle, build, API, CI and docs, each with severity, root cause, fix and a proof command. No host-project references, so it can be handed to the engine's maintainers unchanged. | **Live** — the artifact that outlives the feature |
| [tool-result-shape.md](tool-result-shape.md) | Why tool results should be Markdown rather than JSON, and where a per-call diff lives at zero context cost. | **Live** — the design the next feature needs |
| [cli-agent-harness-parity.md](cli-agent-harness-parity.md) | Five terminal coding agents compared against this one: table stakes, differentiators, deliberate divergences. | **Live** — reference for scope questions |
| [pascal-async-await.md](pascal-async-await.md) | What a general Pascal program can take from promise/RxJS-shaped async, independent of any engine. | **Live** |
| [goccia-ast-arena.md](goccia-ast-arena.md) | The full record of the AST ownership defect and its fix: the arena design, the three-scope correction, the five defects the fix exposed, the measurement tables, and the method. Written as an upstream ADR, kept here because the code it describes is not in this tree. | **Historical** — but the ownership analysis and the method are the most reusable thing in this folder |
| [goccia-embedding-findings.md](goccia-embedding-findings.md) | The embedding-compatibility findings: unit-name collision, `-Sew`, `constref`, the pinned-singleton floor, and the pin-a-fork pattern. The upstream PR body. | **Historical** — conclusions are folded into the register above |
| [gocciascript-async.md](gocciascript-async.md) | How that engine does promises and `await`, and where a Pascal host plugs in. | **Historical** — describes an engine no longer vendored; read only if the sandbox is reconsidered |
| [gocciascript-embedding.md](gocciascript-embedding.md) | The pre-spike survey: what the engine offers and what we would want from it. | **Historical** — superseded by the feature's own FEATURE and SPEC |

## The engine is no longer vendored

`deps/goccia` was deleted on 2026-10-18 and the composed tool sandbox was parked;
the code, tests and fetch scripts now live in
`docs/features/Composed_Tool_Sandbox/` and are not built. Any research doc that
says "vendored at `deps/goccia`" or "`scripts/fetch-goccia.sh`" is describing the
state at the time of writing, not the current tree. Re-entry conditions and the
admission battery a fixed engine must pass:
`docs/features/Composed_Tool_Sandbox/REWRITE_PROPOSAL.md`.

## Writing one of these

- **Lead with the conclusion.** The reader wants the answer, then the evidence.
- **Record the measurements, not the adjectives.** "18,890 → 0 blocks" survives
  review; "much better" does not.
- **Keep the dead ends.** The plan that failed and *why* is usually the most
  valuable paragraph, because it is what the next attempt would otherwise repeat.
- **Say what you did not verify.** An unmarked inference reads as a measurement.
- **Date it and name the revision.** Otherwise nobody can tell whether it still
  holds.
