# 0143 - Parsed AST nodes are allocated into an engine-owned arena, and the arena is freed with the engine

**Date:** 2026-10-17
**Area:** `ast`, `parser`, `engine`, `memory`
**Related:** [ADR 0017](0017-vmt-dispatch-for-ast-evaluation.md), [ADR 0126](0126-bytecode-call-path-arena-fills-and-thread-binding.md), [ADR 0133](0133-modules-root-their-value-exports.md)

> Harness note: this record is the vendored patch's design note. It is kept in
> the harness tree (`docs/research/`) so a `fetch-goccia.sh` re-fetch cannot
> lose it; the file intended for upstream is
> `docs/adr/0143-parsed-ast-nodes-are-allocated-into-an-engine-owned-arena.md`.

## Context

The parsed AST is a plain Pascal object tree that the garbage collector never
sees. `TGocciaASTNode` is a bare `TObject`, not a `TGCManagedObject`; no node is
ever registered with `TGarbageCollector`, and no collection can reach one. A
parse-only run of

```pascal
R := TGocciaSourcePipeline.Parse(Lines, 'p.goccia', Opts);
R.Free;
```

leaks in proportion to the tree: 13 unfreed blocks for one statement, 805 for
one hundred, about eight per statement and unbounded in script size. The
engine's own test runner under heaptrc reports 18,890 unfreed blocks on the JS
suite. The `memory-safety` job that would catch this
(`.github/workflows/fuzz.yml`) runs `ubuntu-latest` only, so the leak is
untested on macOS and no gate sees it.

Ownership of the tree is incomplete, and the two halves fail differently.

- `TGocciaProgram` has no destructor, so its owned
  `FBody: TObjectList<TGocciaStatement>` is never freed. This is the only
  owned list in the tree; it holds the top-level statements.
- Every other edge is a raw field with no owner. `TGocciaBinaryExpression`
  holds `FLeft`/`FRight`, `TGocciaCallExpression` holds `FCallee`/`FArguments`,
  `TGocciaIfStatement` holds `FConsequent`/`FAlternate`,
  `TGocciaVariableDeclaration` holds an `Initializer` inside each
  `TGocciaVariableInfo`, and so on across 63 expression classes and 35
  statement classes. These children are allocated by the parser and never
  freed.

The lifetime is worse than the leak. A closure does not copy its body: it holds
the parsed nodes. `TGocciaFunctionValue.FBodyStatements` is built by
`CopyStatementList`, which makes a `TObjectList<TGocciaASTNode>.Create(False)`
and adds the same node pointers. So a function value created during a run points
into the AST, while the AST is freed at the end of that run by
`PipelineResult.Free`. On the documented long-lived-engine pattern — one
`Execute` defines `f`, a later one calls it — that is a use-after-free. The
leak is the visible symptom; the dangling pointer is the latent one.

## Decision

**Every AST node is allocated into a single arena owned by the engine, and the
arena is freed when the engine is destroyed.** Nodes hold non-owning references
to one another; the arena holds them all. Freeing the arena frees the tree in
one step, and no node destructor is needed.

This is the shape the lexer already uses for its tokens
(`TObjectList<TGocciaToken>.Create(True)`), and the shape ADR 0126 established
for the bytecode call path's stacks. The parser registers each node as it
creates it; the node classes keep their present fields, which become
non-owning.

**The arena belongs to the engine, not to the parse result.**
`TGocciaSourcePipelineResult` stops owning `FProgramNode`: it exposes a
borrowed view of a program the arena owns. `TakeProgramNode` is reworked to
match — it hands over a pointer the arena still owns, or is removed. The engine
creates an arena per realm and frees it in `TGocciaEngine.Destroy`, beside the
other realm-owned state. Freeing the arena with the engine is what makes the
closure case safe: nothing frees a node while a live closure can still reach
it.

**The arena's lifetime is per run, not per parse.** An arena holds its tree
until it is freed and cannot release a subtree early, so one arena per engine
would grow with every `Execute` a long-lived engine makes — the arena leak this
pattern is usually warned about. The engine-per-run case (an embedder that
creates an engine, runs once and frees it, as this host does) has exactly one
parse per arena and no growth. A long-lived engine needs the arena released
once that run's realm and closures are gone; the engine-per-realm arena above
gives that when the realm is per run, and a REPL-shaped host must say so
explicitly.

## Considered options

- **A destructor per node class, each freeing its own children.** This stops
  the leak and nothing else. It leaves the owner unnamed — the same ambiguity
  that produced the bug — and it adds a second owner wherever a child is also
  in an owned list, so it invites double frees. It is also O(nodes) `Free`
  calls with a `GetMem` per node, where the arena is one reset.
- **Free the tree in `PipelineResult.Destroy` by walking it.** Correct for the
  parse-only case and still wrong for the engine, because a closure outlives
  the result. It also needs the walk to know every node shape, which is the
  destructor plan in another guise.
- **Keep the AST alive for the engine's lifetime without an arena, by making
  every node a `TGCManagedObject`.** The collector would then own the tree and
  the closure case would work. It puts the AST on the GC heap, so the collector
  traces and sweeps millions of nodes it does not need to, and it makes
  `TGocciaLiteralExpression`'s deliberate `UnregisterObject` handoff — "the AST
  owns this value, not the garbage collector" — inconsistent with the rest of
  the tree.
- **Leave it.** The leak is bounded per parse and the dangling closure is not
  exercised by the test suite on the platform the gate runs.

## Consequences

- The parse-only probe goes from 13/805 unfreed blocks to zero, and the
  engine's heaptrc run from 18,890 to zero, on macOS. A host that gates on
  heaptrc can require zero again instead of a floor.
- A closure that outlives its run is now well-defined: its body nodes live as
  long as the engine, and the use-after-free at
  `TGocciaFunctionValue.FBodyStatements` is closed.
- A long-lived engine that parses many scripts must release each run's arena;
  an engine-lifetime arena would retain every tree it ever parsed. The
  engine-per-realm arena is correct only while a realm is per run.
- `TGocciaSourcePipelineResult` no longer owns its program. Callers that free a
  result and keep the program — the module path via `TakeProgramNode` — must be
  reworked to borrow it instead.
- A node that a second owner also frees is now a double free rather than a
  leak, so any list that currently owns nodes must become non-owning when it is
  fed from the arena.
- `TGocciaLiteralExpression` keeps its handoff: the value it holds stays
  outside the collector and dies with the node, which now dies with the arena.

## State at the time of writing

- `deps/goccia` is **gitignored**; the tracked tree is clean. HEAD is
  `7aec819` (this record).
- **The vendored tree is reset to pristine + the three existing patches**
  (re-fetch + `patch-goccia.sh`), and the harness suite is green
  (`make test SUITE=TScriptTest` → 0 failures). No arena work is in the tree.
- **The partial arena work is saved at `/tmp/goccia-arena-wip/`** (may not
  survive a reboot — treat the plan below as the source of truth):
  `Goccia.AST.Arena.pas` (new unit), `Goccia.AST.Node.pas` (arena hook),
  `Goccia.Parser.pas` (the 20-list flip).
- Harness-side tools already present: `scripts/patch-goccia.sh` (three
  patches), `build/script-check/parse_probe.pas` (the repro),
  `build/script-check/leakcat.py`, `leaksites.py`, `list_owners.py`,
  `classify_frees.py` (heaptrc trace symbolizers and AST-ownership audits —
  FPC emits raw addresses; `atos -o <bin> -l <text-base>` resolves them).

## Resume here — exact steps

1. **Add `Goccia.AST.Arena.pas`** (written; in `/tmp/goccia-arena-wip/`): a
   `TGocciaASTArena` with an owning `TObjectList<TObject>` and
   `Register(ANode)`; a `threadvar GCurrentASTArena`.
2. **Hook the base node.** In `Goccia.AST.Node.pas`, add `Goccia.AST.Arena` to
   `uses` and, in `TGocciaASTNode.Create`, `if GCurrentASTArena <> nil then
   GCurrentASTArena.Register(Self)`.
3. **Set the active arena** in `TGocciaSourcePipeline.Parse` (create the arena,
   set `GCurrentASTArena`, restore in `finally`).
4. **Flip the parser's node lists to non-owning.** Exactly 20 sites in
   `Goccia.Parser.pas`: `TObjectList<TGoccia{Expression,Statement,ASTNode,
   CaseClause,DestructuringPattern,DestructuringProperty}>.Create(True)` →
   `(False)`. **Leave `FPrivateClassContexts` owning** (lines 599/620) — those
   are parser state, not nodes. No other unit constructs an owning node list.
5. **Fix the AST destructors.** 12 classes hold a node list and need a
   destructor that frees **only the list** (in `Goccia.AST.Expressions.pas`
   unless noted): `TGocciaTemplateWithInterpolationExpression.FParts`,
   `TGocciaCallExpression.FArguments`, `TGocciaArrayExpression.FElements`,
   `TGocciaNewExpression.FArguments`, `TGocciaArrayDestructuringPattern.FElements`,
   `TGocciaObjectDestructuringPattern.FProperties`, `TGocciaBlockStatement.FNodes`
   (Statements). The four that already have one keep it
   (`TaggedTemplateExpression.FExpressions`, `SequenceExpression.FExpressions`,
   `CaseClause.FConsequent`, `SwitchStatement.FCases`) — their lists are
   non-owning, so `.Free` still frees only the container.
6. **Drop the child frees from existing destructors.** `classify_frees.py`
   prints the exact list; `DROP (node child)` items must go (the arena frees
   them), e.g. `ClassDefinition.FSuperClassExpression`,
   `ClassDeclaration/ClassExpression.FClassDefinition`, `CaseClause.FTest`,
   `SwitchStatement.FDiscriminant`,
   `ExportDestructuringDeclaration/ExportClassDeclaration.FDeclaration`.
   **Keep** every map/string-list `.Free` (`FMethods`, `FGetters`,
   `FInstancePropertyTypes`, …) — verify each against `TGocciaExpressionMap`.
7. **Remove `TGocciaProgram`'s ownership of `FBody`** — no destructor (the arena
   frees the statements). Confirm nothing else frees the program: today
   `TGocciaSourcePipelineResult.Destroy` calls `FProgramNode.Free` and must
   stop; `TakeProgramNode` must be reworked to borrow.
8. **Wire the arena to the engine.** Create it in `TGocciaEngine` (per realm),
   free it in `TGocciaEngine.Destroy` after the closures are gone; make
   `TGocciaSourcePipelineResult` a non-owning view. This is the step that also
   closes the closure use-after-free — do not skip it, and do not free the
   arena at the end of `Execute`.
9. **Verify:** parse-only probe → **0** (1 and 100 statements); the engine's
   heaptrc runner → **0**; the harness gate with `LEAK_MAX_BLOCKS=0`; then
   `make check`.
10. **Patch-package it:** `scripts/patches/000{1..4}-*.patch` applied with
    `patch -p1 --forward`; migrate the three existing patches; add the arena
    patch. The arena patch's diff is the upstream PR.
11. **Update the pin** from `531fb52` to upstream `main` (`1284dbb1`) and
    re-verify (the arena rebases onto current main; a pristine tree of main is
    at `/tmp/goccia-main/`).

### Traps found while implementing (do not rediscover these)

- **A half-applied flip is worse than the leak.** With lists flipped to
  non-owning but destructors still freeing children, a node is freed twice.
  Steps 4–6 must land together, and the build must be checked after each file.
- **`TakeProgramNode` is the module path's hand-off.** It sets
  `FProgramNode := nil` so the result will not free it; under the arena the
  program is never the result's to free, so this must change (step 7).
- **The existing `TGocciaLiteralExpression` destructor is already correct**:
  it frees the literal's `TGocciaValue` (a non-GC handoff) and must stay.
- **`CopyStatementList` already makes a non-owning list**
  (`Create(False)`), so closure bodies need no change; they are exactly the
  pointers the arena now owns.
- **Upstream `main` has diverged** (230 changed source files, `0142` is its
  newest ADR) but has the *same* AST shape, so the arena applies there.

## Update (2026-10-17): the module loader and shims already depend on AST lifetime

Implementing steps 4–8 surfaced a constraint the first plan missed, and it is
the reason the arena is **not** a mechanical change. Two independent places
already rely on a parsed program outliving its run:

1. **`Goccia.Shims.pas` (threadvar comment, ~line 1008) states it outright:**

   > One parsed program per DEFAULT_SHIMS entry, filled on first use. A parsed
   > program is never released while the thread's engines run: the functions a
   > shim defines keep pointing into its AST, and `TGocciaProgram.Free` releases
   > only the program node, not the statements under it. Parsing per engine
   > therefore leaked the shim ASTs of every engine: about 1.1 MB per engine
   > that uses Date on 64-bit…

   So the *existing* design deliberately keeps shim ASTs alive for the thread
   and caches one program per shim. It also documents the very defect this ADR
   fixes ("releases only the program node, not the statements under it") as the
   cause of a *previous* 1.1 MB-per-engine leak.

2. **`Goccia.Modules.Loader.pas`** frees programs at five sites —
   `TGocciaModuleLoadState.Destroy` (`ProgramNode.Free`),
   `TGocciaDeferredModuleBody.Destroy` (`FProgramNode.Free`), and three more in
   the load path. Each is a program whose lifetime the loader owns, on the
   failure path and on the deferred-body path.

Consequences for the plan:

- **The arena cannot be engine-scoped without touching the module loader.**
  A program the loader parses and frees is not the engine's to own. Either the
  loader gets the engine's arena and stops freeing programs, or a program's
  arena is per-program and the loader keeps owning it — which is the module
  case, and it is not engine-scoped.
- **Shims want a thread-lifetime arena**, not an engine- or run-scoped one.
  They are cached per thread and explicitly outlive engines.
- So there are **three arena scopes**, not one: the run's tree (freed with the
  engine), the module's tree (owned by the loader / module), and the shim's
  tree (thread-lifetime, already cached). A single engine arena would
  double-free the module and shim programs.

The corrected shape: an arena is an **owner object a program is parsed into**,
and the *caller that owns the program* owns the arena —
`TGocciaSourcePipelineOptions.Arena` already carries this, and `FASTArena` on
the engine is right only for the entry program. The module loader passes its
own arena and keeps its `ProgramNode.Free` → arena-free equivalence; the shim
cache keeps its per-thread arena.

Steps 4–8 as written are therefore **necessary but not sufficient**; step 8
must be split per program owner (entry / module / shim). Nothing was left
half-applied: the vendored tree is reset to pristine + patches, and the harness
is green (`make test SUITE=TScriptTest` → 16 tests, 0 failures).

### WIP location (this session)

`/tmp/goccia-arena-wip2/` holds the eight edited units from this attempt:
`Goccia.AST.Arena.pas`, `Goccia.AST.Node.pas`, `Goccia.Parser.pas`,
`Goccia.AST.Expressions.pas`, `Goccia.AST.Statements.pas`,
`Goccia.SourcePipeline.pas`, `Goccia.Engine.pas`, `Goccia.Interpreter.pas`.
They compile as far as the pipeline; the module loader and shims are untouched,
which is exactly where it must be finished.
