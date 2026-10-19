# Vendored-Engine Lessons (from the GocciaScript spike)

**Status:** carried into [Tree-Sitter](../features/Tree_Sitter/FEATURE.md)
**Related:** [goccia-ast-arena.md](goccia-ast-arena.md),
[goccia-embedding-findings.md](goccia-embedding-findings.md),
[gocciascript-embedder-issues.md](gocciascript-embedder-issues.md) (the engine's
own 47-item register, project-agnostic),
[Composed Tool Sandbox](../features/Composed_Tool_Sandbox/FEATURE.md) (parked)

The Composed Tool Sandbox embedded a third-party FPC engine (GocciaScript) as a
security-relevant component. It is now parked — the engine works, but it is not
mature enough to gate access. These are the lessons worth keeping, written so
they transfer to any vendored parser or runtime, and specifically to
[Tree-Sitter](../features/Tree_Sitter/FEATURE.md), which vendors a C runtime
and per-language grammars for the **same reason** (a correct shell ask set for
the approval gate).

## 1. Ownership is the whole problem, and it is invisible

The engine's AST was a plain object tree the GC never saw. Ownership of it was
declared in the tree's shape and violated in the tree's edges:

- The root had no destructor, so its owned list never freed.
- Every node-to-node edge was a raw field with **no owner** — allocated by the
  parser, freed by no one.

**Rule for any vendored tree:** before adopting a parser/runtime, find its
ownership model and **write down who frees what**. If there is no single answer,
that is the finding. For tree-sitter this is easy and is the reason it is a good
fit: the C runtime returns an opaque `TSTree` you `ts_tree_delete`, and nodes
are *values* into it — there are no cycles and no ownership to infer. **The
absence of an ownership graph is a feature.** Prefer a component whose memory
model is "you own one handle" over one whose model is "every edge is a decision".

## 2. A base-class-keyed ownership scheme has a hole per non-subclass

The arena registered nodes by inheritance (`TGocciaASTNode.Create`). Four classes
that *hold* nodes did not descend from it, so they never registered — and one of
them (`TGocciaClassDefinition`) had its free *dropped by our own change*, on the
assumption the arena owned it.

**The audit, and it is mechanical:** `grep -E '^  \w+ = class$'` — every class
that is not the base. There is no way to find these by reading the tree; you
have to enumerate. **For tree-sitter:** this class of bug cannot occur (nodes are
values, not owned objects), which is another point in its favour.

## 3. Non-owning contents do not imply an owned container

Flipping a list to non-owning moves the *nodes* to the arena but leaves the
*container* unowned. The parser built the program body list with `Create(False)`
and handed it to the root — which had no destructor. One list leaked per parsed
script.

**Rule:** every container handed to a node needs a destructor that frees the
container and not its contents. The two are independent decisions, and a
half-applied flip is worse than none.

## 4. An ownership change converts leaks into crashes

Every `X.Free` in a node destructor is **container (keep)** or **node (drop)**.
Get one wrong and it is a double free — which is why the earlier half-flip was
backed out rather than left in the tree. The failure mode is an
`EAccessViolation` in every worker thread, not a leak.

**And the risk is not only in destructors.** Four parser **recovery** paths
freed arena-owned nodes — the paths that run only when a feature is disabled and
the parser skips a construct. Recovery and error paths are the least-exercised
code, so they are caught last:

```
grep -nE '\w+\.Free;' <the parser>   # belongs in the audit, not just the AST
```

**For tree-sitter:** the C runtime's `ts_tree_delete` is the only free; there is
no per-node destructor to get wrong. The equivalent audit becomes "is every
`TSParser`/`TSTree`/`TSQuery`/cursor freed exactly once", which is a small,
enumerable set and a leak-gate check.

## 5. A capability boundary you cannot test is not a boundary

The engine's failure mode was discovered by running **its own** heaptrc suite
over its own corpus, not by our tests. Our single-file probes all passed on the
crashing file; only the full runner path (testing-library globals + module
loader + shims) reached it.

**Rule:** when vendoring a component that will gate access, adopt the vendor's
own test suite and run it under your sanitizer. If the vendor has no such suite,
that is a maturity signal. For tree-sitter: the runtime has a conformance
corpus, and `tree-sitter-bash` has its own tests — wire both into `make check`
if the shell gate is to be trusted.

## 6. Fail safe, never fail open — and make the fallback a test

The gate's correctness requirement is asymmetric: **too many asks is a nuisance,
too few is a breach.** The composed sandbox could not offer that asymmetry
cleanly (a script either ran or did not). The shell gate can, and does:

> if the parse is imperfect (an `ERROR`/`MISSING` node, an unsupported
> construct), the ask set is the **union** of what the tree yields and what the
> conservative splitter yields; if neither is confident, the raw command is an
> ask.

**Rule:** a boundary component needs a *degraded* mode that is strictly more
conservative, and a test that pins it. The union rule is why tree-sitter is a
good fit: a wrong parse widens the dialog, it never blinds it.

## 7. The method: symbolize, then bisect

Two techniques carried over, both cheap and both decisive:

- **heaptrc + `atos`.** Build under `-gh`; get the binary's `__TEXT` base with
  `DYLD_PRINT_SEGMENTS=1`; `atos -o <bin> -l <base>` the raw addresses; group by
  the first frame in *our* units; read one full trace. That turned "18,890
  blocks" into "`ParseObjectPattern` → `ScanIdentifier`" in one step.
- **Line-count bisection.** Truncate the failing input and re-run until the
  fault appears between two line counts (60→100, 70→80, 74→76), then read the
  construct there. That turned "a 244-line file crashes" into a four-line repro
  in five runs.

Both are reusable for any vendored component with a leak or a crash, and both
should be scripted (they are — see `build/script-check/leakcat.py`,
`leaksites.py`, `trace_needle.py`).

## 8. Prefer the boundary you already have

The strongest lesson is the reframing itself. We added a second interpreter
(the engine) to make compound work **observable** — the model reached for `bash`
to hide a loop inside one approval. But the thing being hidden was **shell**, and
the boundary that needs to see it is the **shell boundary**.

- A new interpreter is a new thing to secure, version, patch, and test.
- The shell is already there, already gated, already audited.
- Making the *existing* gate correct (parse the shell, name every program it
  runs, fail safe) fixes the actual problem with **no new runtime**.

**Rule:** before vendoring a component to enforce a boundary, ask whether the
boundary already exists and merely needs to be made correct. Correcting a
boundary is usually cheaper than adding one — and the tree-sitter path is a C
library with a value-semantics API, not a language runtime with an ownership
graph.

## 9. A vendored dependency should be a pinned fork you can patch

The fixes ended up as **commits on a fork** (`github.com/johnrcui/GocciaScript`,
branch `ast-arena`), fetched by commit SHA and checksummed, with
`patch-goccia.sh` reduced to an *assertion* that the fetched tree carries them.
That is better than `sed` patches in a script: the vendored tree is exactly a
revision, a re-fetch cannot lose the fixes, and the diff is the upstream PR.

**Rule for any vendored dep:** pin a fork (or a commit) and checksum it; keep
your changes as commits, not as mutations. It makes upgrades a rebase and
patches reviewable.

## What to carry into Tree-Sitter, concretely

| Lesson | Concrete action |
| --- | --- |
| 1, 2, 4 (ownership) | Tree-sitter's API is handles-and-values; the audit is "every handle freed once", enforced by `make test-leak`. |
| 5 (test the boundary) | Wire the runtime's and the grammar's own test corpora into `make check`. |
| 6 (fail safe) | The union rule is already in the SPEC; keep the splitter as the fallback and test every degraded path. |
| 7 (method) | Keep `leakcat.py`/`trace_needle.py`; they work on any binary. |
| 9 (vendoring) | Same fetch+checksum pattern; the C runtime needs no fork if upstream is clean. |

The through-line: **the engine's defects were all about ownership of a tree we
did not author. Tree-sitter has no such tree — it gives you one handle and
values.** That is the property to look for when a vendored component must gate
access.
