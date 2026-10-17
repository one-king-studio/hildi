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
