# GocciaScript — Embedder Issue Register and Readiness Gaps

**Status:** findings report. Not a specification, not a patch series.
**Scope:** the GocciaScript engine and its packaging, judged as an embeddable
component — i.e. a library a host program links, instantiates, runs untrusted
programs in, and disposes.
**Revision examined:** `ast-arena` branch of the fork, tip `b5acee64`, plus
upstream `531fb52`. Upstream `main` had diverged substantially at the time of
writing (≈230 changed source files).

> **This document is deliberately self-contained.** It names no host project and
> assumes no knowledge of one, so it can be pasted into an issue tracker, a fork's
> `docs/`, or an upstream PR description unchanged.

---

## 1. How to use this

1. **Re-verify before filing.** Every item was observed at the revision above. Some
   may be fixed on current `main`. Each row has a *proof* column — that is the
   command or test that decides whether the item is still live. Run it first;
   do not file from this document alone.
2. **Fix in the order given in §5, not the order listed.** The register is grouped
   by area; the sequence is driven by what makes later work possible.
3. **Every fix ships with the test that fails without it.** A fix without a gate
   regresses silently: most of the items here were invisible until a specific,
   rarely-run path executed.
4. **Read §3 (Gaps) as seriously as §2 (Issues).** §2 is a list of bugs. §3 is a
   list of things that do not exist, which is why the bugs kept arriving one at a
   time.

### Severity legend

| Sev | Meaning |
| --- | --- |
| **S1** | Memory unsafety: double free, use-after-free, uninitialized pointer, free-before-use. Can corrupt or crash the host. |
| **S2** | Unbounded growth or leak. Safe but disqualifying for a long-lived host. |
| **S3** | Integration blocker: cannot build or link correctly under a normal host configuration, or fails **silently**. |
| **S4** | API/ergonomics: forces host-side workarounds, so the host owns complexity it should not. |
| **S5** | Test, CI or documentation gap — the mechanism by which S1–S4 stay invisible. |

### Counts

| Area | Items | Of which S1 |
| --- | --- | --- |
| A. AST ownership and destruction | GC-01 … GC-12 (12) | 6 |
| B. Process-global state and lifecycle | GC-13 … GC-17 (5) | 0 |
| C. Build, packaging, compatibility | GC-18 … GC-26 (9) | 0 |
| D. Public embedding API | GC-27 … GC-33 (7) | 0 |
| E. Test and CI coverage | GC-34 … GC-39 (6) | 0 |
| F. Documentation and process | GC-40 … GC-44 (5) | 0 |
| G. Async and the event model | GC-45 … GC-47 (3) | 0 |
| **Total** | **47** | **6** |

### If you only fix five things

1. **GC-03** — the closure/use-after-free. It is the only defect here that silently
   corrupts memory on a *documented* usage pattern (a long-lived engine).
2. **GC-34 / GC-35** — make the leak gate trustworthy on more than one platform and
   give it a meaningful number. Without this you cannot tell whether a fix worked.
3. **GC-05** — the recovery-path double frees. Error paths are the last to be
   exercised and the first to crash.
4. **GC-18** — the `JSONParser` unit collision. It breaks hosts *silently*, at a
   distance, with no error at the engine boundary.
5. **GC-27** — publish an embedding API. Until the surface is declared, every other
   fix is a host-visible breaking change.

---

## 2. Issue register

### A. AST ownership and destruction

The through-line: **ownership of the parsed tree is declared in one place and
violated in another, and the violations are invisible until a specific path runs.**
The AST is a plain object graph (`TGocciaASTNode` is a bare `TObject`), so the
garbage collector never sees it and no collection can reach it.

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-01** | S2 | **Parse-only leaks scale with the tree.** Every node-to-node edge (`FLeft`/`FRight`, `FCallee`/`FArguments`, `FConsequent`/`FAlternate`, each `TGocciaVariableInfo.Initializer`, …) is a raw field with no owner. Measured on a parse-only probe: 13 unfreed blocks for 1 statement, 805 for 100 — about 8 per statement, unbounded in script size. Across 63 expression and 35 statement classes, no child is ever freed. | Give the tree **one owner**. Either (a) an arena: every node is allocated into an arena the program's owner holds, and one `Free` releases the whole tree; or (b) value semantics: nodes are records inside one buffer, referenced by index. (b) removes the class of bug permanently; (a) is the smaller change. Do **not** add a destructor per class — that leaves the owner unnamed and invites double frees wherever a child is also in an owned list. | A parse-only probe: parse N statements, free the result, zero unfreed blocks, **flat** in N. Add it as a test, not a one-off probe. |
| **GC-02** | S2 | **`TGocciaProgram` has no destructor**, so its owned `FBody: TObjectList<TGocciaStatement>` is never freed — one list per parsed script. This is the only *owned* list in the tree, which is why it was easy to miss: everything else is unowned, so a missing destructor looked normal. | Program frees its body list and **not** its contents. Generalise: every container handed to a node needs a destructor that frees the container; whether it frees its contents is an independent decision. | The GC-01 probe shows the container block gone; a `Create(False)` → destructor audit finds no other orphan containers. |
| **GC-03** | **S1** | **Closures alias their AST, which is freed at end of run.** `TGocciaFunctionValue.FBodyStatements` is built by `CopyStatementList`, which makes a **non-owning** list and copies the *pointers*. A closure created in one `Execute` and called in a later one therefore dereferences freed nodes. On the documented long-lived-engine pattern (one `Execute` defines `f`, a later one calls it) this is a use-after-free. The leak (GC-01) is the visible symptom; this is the dangerous one, and it is silent. | Make the lifetime explicit: either the closure **copies** the body it captures, or the function value holds a reference that keeps the tree alive, and the type says so. An arena owned by whoever owns the program (see GC-08) satisfies this as long as the arena outlives every value reachable from it. | A test: `Execute("function f(){return 1}")`, then `Execute("f()")` on the **same** engine, under heaptrc and (if available) an ASan-equivalent build. Must not fault; must not leak. |
| **GC-04** | S2 | **Ownership keyed on a base class has a hole per non-subclass.** The arena registers nodes in `TGocciaASTNode.Create`, so any class that *holds* nodes but does not descend from it never registers and its subtree leaks. Four such classes: `TGocciaDestructuringProperty`, `TGocciaObjectMatchProperty`, `TGocciaMatchClause`, `TGocciaClassDefinition`. `TGocciaClassDefinition` is worst: a destructive edit to the arena flip *dropped the free of the node that holds it*, assuming the arena owned it. | Remove the registration hook entirely (GC-01 option b), or replace it with an explicit `Register` the parser calls at every allocation site — and then audit. | `grep -E '^\s+\w+ = class$'` over the AST units: every bare class (one not descending from the node base) must be either an allocation site that registers, or provably not holding nodes. Make this a checked-in script. |
| **GC-05** | **S1** | **Four parser recovery paths free arena/owner-owned nodes — a double free.** These run only when a feature is disabled and the parser skips the construct, so no ordinary probe reaches them. Sites: `WhileStatement` recovery (skipped `BodyStmt`), `DoWhileStatement` recovery (same), the loose-equality warning (`DiscardedLeft`, `Right`), and the invalid-labeled-declaration path (`Result`). Symptom in warning-recovery mode: `EBusError` / `EAccessViolation`, nondeterministic, in every worker thread. | Audit **error and recovery paths** as part of any ownership change, not just destructors: `grep -nE '\w+\.Free;'` over the parser and the AST, classify each as *container (keep)* or *node (drop)*. Under an arena every wrong one becomes a crash, so the audit must be exhaustive — a half-applied flip is worse than none. | A corpus file per recovery path, each run under heaptrc *and* a plain build, in warning-recovery mode. This is exactly the configuration the existing corpus lacked. |
| **GC-06** | **S1** | **`DefaultOptions` leaves newly added fields uninitialized.** Adding `Arena` to `TGocciaSourcePipelineOptions` without extending `DefaultOptions` gave callers a garbage pointer. The idiom — a plain record with a `Default`-like helper that must be edited in lockstep — makes "add a field" a silent breaking change. | Records with a lifetime get an explicit `Init`/`Done` pair, or are constructed only by a function that initialises every field, and the "default" is a function, not a hand-maintained record. Then a new field cannot be forgotten, because there is no literal to forget it in. | Compiler-enforced if possible (a class/record with `class function Create`); otherwise a test that constructs options the documented way and asserts every field is non-garbage. |
| **GC-07** | **S1** | **Destruction order is inverted.** The engine freed its arena *before* the builtins, interpreter, realm and module loader that parse into it. Symptom: faults during `Destroy` in hosts that create many engines. | Destructors free in reverse construction order, explicitly, with a comment naming the order. One teardown procedure, not scattered `Free` calls. | Construct/destroy N engines in a loop under heaptrc and a plain build; N = 1, 10, 1000. |
| **GC-08** | S1 | **There are multiple program owners, so a single-scope ownership fix is wrong.** The module loader frees programs at five sites (`TGocciaModuleLoadState.Destroy`, `TGocciaDeferredModuleBody.Destroy`, and three in the load path); the shim cache holds one parsed program per shim for the **thread's** lifetime and deliberately never releases it. A single engine-scoped arena double-frees the module and shim programs. (Discovered only while implementing GC-01 — and it invalidated the first, obvious plan.) | Make an **arena the property of whoever owns the program**, and pass it into the parse (`TGocciaSourcePipelineOptions` already carries one). Three scopes: entry program (engine), module (loader/module), shim (thread cache). Say so in the ownership document. | A test per scope: entry program freed with the engine; module freed with the loader; shim program freed at thread teardown. Each must be free of both leaks and double frees. |
| **GC-09** | **S1** | **`TGocciaClassDefinition.Destroy` frees `FElements[I].StaticBlockBody`**, a `TGocciaBlockStatement` that the owner owns. Under an arena this is a double free — `EAccessViolation` in every worker thread, not a leak. | Drop the free; the block is owned by the arena/its owner. This is the canonical example of GC-05's rule: every `X.Free` in a destructor is either *container* or *node*, and the node case must go. | Covered by the GC-05 audit plus a class-with-static-block test under heaptrc. |
| **GC-10** | S2 | **The object-literal parser orphans its insertion-order temporary.** One container per object literal, freed by no one. | Free it in the same routine that builds it, or hand it to an owner with a destructor (GC-02's rule). | Object-literal-heavy corpus (nested literals inside functions, destructuring) under heaptrc; count must be flat. |
| **GC-11** | S2 | **Identifier strings are retained past the parse**, reachable from `ParseObjectPattern`. After the AST work landed, the residual on one corpus was 1,534 → 355 blocks and still scaled with file count. Not proportional to the AST — a second, smaller retention path (tokens or destructuring keys held past the tree). | Intern identifiers into a table the program owns, and release the token strings with the parse. Audit what the parser keeps in fields beyond the node tree. | The same corpus, measured across file counts; the count must be flat in file count as well as statement count. |
| **GC-12** | S5 | **A deliberate ownership exception is undocumented.** `TGocciaLiteralExpression` unregisters its value from the GC ("the AST owns this value, not the collector"). Correct, but it is the one place the AST owns a GC object, and nothing states the rule, so any ownership redesign risks breaking it silently. | One paragraph in the ownership document: what the AST owns, what the collector owns, and where the handoff happens. | The document exists and the handoff is asserted by a test (literal survives GC; freed with the tree). |

### B. Process-global state and lifecycle

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-13** | S2 | **`PinSingletons` has no counterpart.** `TGocciaEngine.PinSingletons` (constructor) pins the primitive singletons, the hole value and the BigInt singletons; the realm's shared prototype graph is pinned too (`TGocciaSharedPrototype.Create` → `PinObject(FPrototype)`). There is **no `UnpinObject` call for any of them anywhere**. Consequence: nothing can free them, so a host can never reach zero unfreed blocks; the residue is a fixed per-process floor, not a per-run leak. | Decide the lifetime and make it explicit: either add `UnpinSingletons` in `Destroy` (and free), or declare them process-lifetime and expose a host-callable `Shutdown` that unpins and frees, so a leak checker can account for them. Either way, `Pin*` and `Unpin*` must come in pairs — that is the invariant to state and test. | Construct/dispose N engines in a loop under heaptrc: flat in N (today it is flat but non-zero). After `Shutdown`, zero. |
| **GC-14** | S2 | **Class-var singletons have no unit `finalization`.** `TGocciaSymbolValue`'s well-known symbols, the primitive singletons, `TGocciaTypedArrayStaticFrom`, and the graph built by `TGocciaEngine.RegisterTypedArrayConstructor` survive process end with nothing to free them. | A unit `finalization` per owning unit, ordered so dependencies are destroyed before dependents; or fold them into the `Shutdown` of GC-13. | `haltonnotreleased` on a program that creates and frees one engine and exits: report must be empty. |
| **GC-15** | S4 | **The collector and microtask queue are thread-local singletons with `Initialize`/`Shutdown` but no documented lifecycle.** An embedder cannot tell who must call `Shutdown`, when, or what happens on a thread that exits without it. | Document it, and make it safe: `Shutdown` idempotent, and a thread-exit hook that cleans up if the host forgot. | A test that creates and abandons a thread which used the engine, then checks for leaks. |
| **GC-16** | S2 | **The shim cache is a threadvar holding parsed programs for the thread's lifetime**, with no eviction and no teardown. The source comment records that parsing per engine instead leaked about **1.1 MB per engine** that used `Date` — i.e. the cache exists to work around GC-01 rather than because the lifetime is right. | With GC-01 fixed, re-evaluate: either release at thread exit with an explicit hook, or keep the cache and document it as process/thread-lifetime state with a bound and a teardown. | A thread that runs many engines, then exits, under `haltonnotreleased`: no shim residue. |
| **GC-17** | S4 | **There is no embedder-facing lifecycle contract at all.** "Create engine, run, free" is the only documented pattern, and it leaves process-global state behind without saying so. Hosts compensate by poking the collector after each run — a workaround that belongs in the engine. | Publish `Create → Run → Dispose`, plus an optional `Shutdown` for process-lifetime state. State exactly what `Dispose` releases and what remains. | The contract is in the docs, and a test asserts it: after `Dispose`, only documented state remains; after `Shutdown`, none. |

### C. Build, packaging and compiler compatibility

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-18** | S3 | **Unit names collide with the FCL.** `source/shared/JSONParser.pas` is `unit JSONParser`; the FCL ships `fcl-json/jsonparser`. On a case-insensitive filesystem (macOS default) the engine's unit **shadows** the FCL one, so the moment the engine is linked, every host `GetJSON`/`TJSONData` call resolves to the wrong unit or fails to compile. **The failure is at a distance and silent**: JSON parsing in unrelated host features stops working, with no error at the engine boundary. `HashMap` and `TextSemantics` are the same class of risk — generic names in a flat namespace. | Namespace every unit under a package prefix (`Goccia.JSONParser`, …) and update the eight `uses` references. Audit **all** of `source/shared/` for names that could collide with RTL/FCL. | Full host build with the engine linked, exercising `fpjson` end to end. Plus a checked-in script listing every `unit` name and flagging duplicates against a known RTL/FCL list. |
| **GC-19** | S3 | **Does not compile under `-Sew`.** Unreachable code in `source/shared/HashMap.pas`, "constructor should be public" in `Goccia.Values.Primitives.pas`, `UnicodeString`→`AnsiString` conversions in `source/shared/TextSemantics.pas`. A host that treats warnings as errors cannot compile the engine with the same strictness it applies to its own code, so it must globally disable warnings — which hides its own future ones. | Fix the specific sites, or silence each with a **site-local** directive. Never a blanket `{$WARNINGS OFF}` in the shared include. | `fpc -Sew` over the engine: zero warnings. Then remove any blanket pragma and confirm the build still passes. |
| **GC-20** | S3 | **`constref` vs `const` in comparison callbacks.** Seven sites declare `{$IFDEF FPC}constref{$ELSE}const{$ENDIF}` for `TComparison<T>`; FPC 3.3.1 expects plain `const` and fails with *"Incompatible type … expected `TCOMPARISON<System.Int64>`"*. | Target the FPC versions you support, drop the `IFDEF`, and state the supported version in one place. | A CI job per supported FPC minor version compiling the engine. |
| **GC-21** | S3 | **Per-unit `{$mode delphiunicode}` with no single includable mode unit.** A host that passes `-Mdelphi` (or any global mode) clashes, and the FPC 3.3.1 **compiler crashes** — first a type error, then a nondeterministic `EAccessViolation`. The engine therefore dictates a build-wide rule to its host: *never pass a mode flag*. | Put the mode in one include (e.g. the existing `Shared.inc`) that every unit uses, and document it as the single source of truth. Then either make the units mode-agnostic or state plainly that a global `-M` flag is unsupported and why. | Compile with and without `-Mdelphi` from a clean unit dir; both must either succeed or fail with a *diagnostic*, never a compiler crash. |
| **GC-22** | S3 | **The debug build crashes the compiler.** With `-gl` (line info), `ppca64` dies with an internal `EAccessViolation`, at a **different unit each run** — nondeterministic, so it is heap/stack pressure rather than one construct. The engine builds only with its own production flags (`-O4 -dPRODUCTION`). Consequence: the library cannot be debugged with line info by its embedder, which is the tool you need to find S1 bugs. | Bisect the `-gl` crash: it is a compiler bug, but the engine can almost certainly be arranged to avoid triggering it (unit-count, generics depth, or one pathological construct). Even a documented "use `-gl` but not with `-O-`" is better than nothing. Then add `-gl` to CI. | A `-gl` build in CI on each supported platform and FPC version. |
| **GC-23** | S3 | **A circular unit cluster (~87 units) defeats precompiled-unit caching.** FPC recompiles the cycle on every build regardless of a prebuilt `.ppu` directory, and a consumer whose flags differ from the cache's crashes the compiler. Net effect: every host build recompiles the engine, and a shared cache is not viable. | Break the cycles in the core cluster (extract interfaces/types into leaf units). This is the only fix that makes caching work. | Build the engine into `-FU dir`, then build a consumer twice with no changes: second build compiles zero engine units. |
| **GC-24** | S3 | **The build requires codegen before it can compile.** `Goccia.Version.Generated.inc` is produced by `build.pas`; a plain source checkout does not compile. | Check the generated file in, or ship it in the release tarball, with a CI check that it is up to date. | Extract the release tarball into an empty dir and compile with no scripts run. |
| **GC-25** | S5 | **No documented, CI-verified flag matrix for embedders.** Which of `-Sew`, `-gl`, `-O`, `-O4 -dPRODUCTION`, `-gh` are supported is knowledge held in issues and comments, not in one place, and not enforced. | A table in the README plus a CI job per row. | The CI matrix exists and is green. |
| **GC-26** | S4 | **Footprint is all-or-nothing.** Release engine is ~8 MB. Intl's embedded CLDR is ~1.2 MB and is opt-*out* via a define (`GOCCIA_INTL_NO_EMBEDDED_CLDR`); TZ and UCD data are likewise included unless removed. There is no per-feature build configuration, so an embedder that needs expressions and functions also ships classes, modules, regex, BigInt, typed arrays, Intl and two executors (interpreter *and* bytecode VM). | A build-time feature matrix with named defines, documented per-feature size cost, and a CI job that builds the minimal configuration and runs the corpus with the excluded features' tests skipped. | Build the minimal set, run the corpus, measure with `size`; publish the numbers. |

### D. Public embedding API

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-27** | S4 | **There is no declared public embedding surface.** A host doing ordinary work ends up `uses`-ing the executor, the collector, the scope, the threading unit and a dozen `Goccia.Values.*` units — one observed integration facade pulled in 18. There is no `Goccia.pas` facade, no `internal` namespace convention, no statement of what is stable. Every refactor is therefore a host-visible breaking change, and a host's "one place to change on upgrade" facade is welded to internals — the opposite of its purpose. | Publish one facade unit exposing: create/dispose, `Run(source) → result`, an error type, capability configuration, resource limits, and the native-call hook. Everything else becomes explicitly internal. State a stability policy. | The facade's own `uses` closure is the API; a checked-in script asserts the public unit references only internal units. A host can then be written against the facade alone. |
| **GC-28** | S4 | **No documented hook for synchronous native functions.** The documented pattern is an **async** native that blocks inside its callback and returns an already-settled promise — i.e. the `fetch` shape. A host whose native calls are synchronous (a filesystem read, a key-value lookup, an RPC that blocks) must adopt a promise/concurrency model it does not need, purely to cross the boundary. | Provide a first-class synchronous native registration path with a documented calling convention (arguments in, value out, error as a thrown guest value), and make promises an optional layer above it rather than the only door. | A host-side test: register a sync native, call it from a script, get the value; no promise machinery involved. |
| **GC-29** | S4 | **No resource-accounting API.** Instruction limits and timeouts exist (`Goccia.InstructionLimit`, `Goccia.Timeout`), but there is no documented memory cap, no per-realm accounting, and no hook to refuse an allocation. A host running untrusted programs therefore cannot bound the resource it most needs to bound. | A limit struct covering wall clock, instructions, bytes allocated, and output bytes, all enforced in one place, all reported identically on breach (which limit, how much). | A test per limit that removes the enforcement and watches the test fail. A limit without such a test is a promise. |
| **GC-30** | S4 | **Capabilities are declarable but not verifiable.** `TGocciaCapabilities.None` exists and the model is right (deny-by-default, deny-wins), but nothing lets a host *demonstrate* that a given program had no ambient authority: no way to enumerate the globals a program actually touched, no test corpus asserting that each capability class is denied when off. | A conformance corpus: one test per capability (fs, network, exec, FFI, clock, env) asserting denial under `None`. Plus, optionally, an audit of globals defined/touched per run. | The corpus exists and runs in CI. |
| **GC-31** | S4 | **Guest errors and engine faults are not distinguished in the public API.** "The program threw" and "the runtime is in an undefined state" have different correct host responses (report it vs. discard the realm), but the boundary does not say which is which. Fault containment exists internally (`Goccia.EngineFault` catches them) but is not a contract. | Two documented outcomes: `GuestError` (safe to continue, safe to reuse) and `IntegrityFault` (realm must be discarded; the host should say so). Return them as distinct types. | A test that forces an integrity fault and asserts the API reports it as such, not as a guest error. |
| **GC-32** | S4 | **No deterministic mode.** Clock, randomness and time zone are not host-injectable in a documented way, and the timer queue is virtual — so the same program can behave differently under the test runner than under a host. Programs that read time are not reproducible. | Document the seams and let the host supply them: now(), random seed, TZ. Then the same injection makes the runner and the host agree. | Run a time/random-reading program twice with the same injected values: identical output. |
| **GC-33** | S4 | **Realm isolation is neither documented nor tested.** A program can mutate intrinsics; whether that is visible to a later `Execute` on the same engine is unstated, and hosts are told (implicitly) to create a fresh engine per program — at a cost of re-parsing and re-linking all builtins every time. | State the guarantee and test it both ways: either "an engine is one realm; intrinsics mutated by one run are visible to the next" (then provide a cheap realm reset), or "each run is isolated" (then make it true and cheap). | A test: run a program that patches `Array.prototype`, then a second program that asserts the patch is/isn't visible — per the documented rule. |

### E. Test and CI coverage

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-34** | S5 | **The leak gate runs on one platform.** The `memory-safety` job in `.github/workflows/fuzz.yml` runs `ubuntu-latest` only, and asserts **zero** unfreed blocks. On macOS, the same trivial test file reported **18,890** unfreed blocks. The gate's guarantee is therefore platform-specific: the worst defect in the AST area was invisible to it, and every macOS embedder inherited it. | Run the leak job on every supported platform. Expect it to fail at first — that is the point. | The job appears in the CI matrix and is required. |
| **GC-35** | S5 | **The gate's number is not meaningful.** The runner builds one engine per test file and **never collects between files**, so each file's realm graph is still live at exit: 6,010 blocks on a one-file corpus, 22,895 on the full language corpus. That is arguably the runner's choice, not a leak — but it means a real regression of a few hundred blocks is indistinguishable from the expected residue, and the "zero" assertion is only true because of the platform it happens to run on. | Make the runner collect (or dispose) between files so the expected number is a *characterised* small constant, then assert exactly that. Separate "process-lifetime state" from "leak" in the assertion, and test the lifecycle (GC-17) explicitly. | Run the full corpus; the unfreed count is a flat constant independent of file count. Then introduce a deliberate 10-block leak and confirm the gate fails. |
| **GC-36** | S5 | **The corpus does not cover the runner's own path.** A reproducible crash reached only through the combination of testing-library globals + module loader + shims. Three narrower probes (interpreter executor, bytecode executor, and bytecode + module source type + loader flag) each ran the failing file **cleanly**. Conclusion: if a code path is only reachable via the runner's setup, that setup is part of the exercised surface and must be documented and tested deliberately. | Write down the runner's setup as a supported configuration, and add a smoke test that exercises bare-embedding and runner-shaped embedding separately. | Both configurations have a test; a fault in either is caught by that test rather than by a corpus run. |
| **GC-37** | S5 | **No recovery-mode matrix.** Warning-recovery (unsupported syntax becomes a no-op warning) is configurable per corpus file (`goccia.json` → `"warning-unsupported-features": true`) and is the least-exercised mode — and it held four of the double frees (GC-05). | Run the **whole** corpus in recovery mode, not just the files that opt in; treat every diagnostic path as a testable mode. | The corpus runs twice: normal and recovery, both green under heaptrc. |
| **GC-38** | S5 | **No structural fuzzing of the parser/AST.** Behaviour fuzzing would not catch an ownership fault; it shows up as a crash or a leak, which needs those detectors. | A cheap generator of syntactically-plausible-but-broken programs (truncated, unbalanced, deep nesting, mixed constructs), each parsed and freed under heaptrc. Failures are crashes and non-flat counts, not output diffs. | The fuzzer runs a bounded budget in CI nightly. |
| **GC-39** | S5 | **No per-subsystem leak test.** A leak is only visible at whole-corpus scale, so attribution requires symbolising heaptrc output — the reason the AST work took six commits instead of one. | Small probes per subsystem (parse-only, interpreter-only, module-only, shim-only), each with its own flat-in-N assertion, all in the gate. | The probes exist; a leak in one names its subsystem. |

### F. Documentation and process

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-40** | S5 | **No ownership or architecture document.** The arena design had to be written up as an ADR *by an outside contributor*, in their tree, because upstream had no accepted record of who owns the AST. Any ownership question therefore requires reading 98 classes. | An `ARCHITECTURE.md` covering: the object model, who owns what, the lifetime of every process-global, the unit layering (and thus which `uses` are allowed), and the one legal direction of dependency. | It exists, it is short enough to be read, and a script checks the layering claim. |
| **GC-41** | S5 | **No support matrix.** Which FPC versions, platforms (CPU/OS), and flags are supported is not stated, which is why GC-20/21/22 were discovered by an embedder rather than by CI. | One table. CI enforces it. | The table exists; CI has a row per cell. |
| **GC-42** | S5 | **No embedding documentation.** The only worked examples are the build script and the test runner, both of which know the internals. An embedder has no "hello world" that links the library and runs a program with a native callback. | An `examples/embed/` program, ~50 lines, plus a page in the docs. | It builds in CI. |
| **GC-43** | S5 | **Process-lifetime state is not enumerated.** Pins, threadvar caches, class-var singletons and unit `finalization`s are decided implicitly, one at a time, in the code. | Enumerate them in one table in `ARCHITECTURE.md`, each with its lifetime and its teardown. Reject new ones without an entry. | The table exists; a grep for `Pin`, `threadvar` and `class var` finds no unlisted instance (script it). |
| **GC-44** | S5 | **No versioning or deprecation policy for the surface hosts `use`** — currently moot because there is no declared surface (GC-27), but it gates the value of declaring one. | Semantic versioning on the published facade; internal units explicitly unstable. | The policy is stated where the facade is documented. |

### G. Async and the event model

| ID | Sev | Symptom / root cause | Suggested fix | How to prove it is fixed |
| --- | --- | --- | --- | --- |
| **GC-45** | S5 | **The concurrency model is only discoverable by reading source.** `await` blocks the awaiting frame and drives a fixed set of continuation sources (microtasks, `fetch`, `Atomics.waitAsync`, a virtual timer queue), then throws if nothing settles the promise; there is no return to an event loop — **the host is the event loop**. That is a reasonable design and is documented in a source comment, but it is not in host-facing docs, and the host plug-in seam (`WaitForIdle` / `DiscardPending`) is a *runtime extension*, which is a different object from an engine. | A host-facing "async and the event loop" page: the model, the two hooks, where a host blocks, and what happens on a discarded job. Make the hook reachable from the engine, not only from a runtime extension. | A doc page plus an embedder test that supplies a hook and checks it is called. |
| **GC-46** | S4 | **Pending jobs and unhandled rejections are a cross-boundary correctness surface.** Scopes exist so nested engines do not run each other's jobs (and neither runs nor discards the caller's). But there is no host-facing "drain and report what was left" call, so a host cannot tell whether a finished run left work behind — which is both a leak and a "program did something after we stopped watching" risk. | A `Run` result that reports pending jobs and unhandled rejections, plus an explicit `Drain`/`Discard` the host chooses between. | A test: a script that leaves a pending promise; the result reports it; a second test that the host's choice is honoured. |
| **GC-47** | S4 | **Virtual timers make time behave differently under runner and host.** `setTimeout`/`setInterval` drive a virtual queue, so a program that measures elapsed time or depends on ordering behaves differently in the two configurations, and there is no documented clock injection (overlaps GC-32). | Same fix as GC-32: inject the clock; document that timers are virtual and what "now" means. | Same program, same injected clock, runner and host produce identical output. |

---

## 3. Gaps (things that do not exist)

Issues are bugs; these are absences. Each one is a reason the issues above were
found late or found by a stranger.

| # | Gap | Why it matters |
| --- | --- | --- |
| **G1** | **No ownership model, written down.** | Six of the twelve S1/S2 items in area A are consequences of an implicit ownership rule. The rule is not hard — "one owner per program" — it is just unwritten, so every new node class is a fresh decision. |
| **G2** | **No supported-platform matrix in CI.** | The single most severe defect (GC-01) was invisible on the one platform the gate ran on. |
| **G3** | **No leak gate per subsystem.** | Attribution required symbolising raw addresses; that cost is why a 12-item area took multiple rounds. |
| **G4** | **No public API.** | Every internal change is a breaking change, so the engine cannot converge on a shape, and hosts pin their own workarounds. |
| **G5** | **No capability conformance corpus.** | Capabilities are the security story; a security story without a test suite is a design statement. |
| **G6** | **No resource-limit surface** (memory in particular). | A host cannot bound the resource that a runaway program actually exhausts. |
| **G7** | **No deterministic mode** (clock, random, TZ). | Programs are not reproducible, and the runner and host disagree about time. |
| **G8** | **No embedder example in CI.** | The first thing any embedder writes, they write alone. |
| **G9** | **No error taxonomy.** | Guest errors vs. integrity faults is the difference between "report it" and "discard the realm", and it is not exposed. |
| **G10** | **No deprecation/versioning policy.** | Once G4 is closed, this becomes the deciding factor in whether anyone can safely upgrade. |

---

## 4. Reproduction recipes

These are the techniques that turned "it leaks" and "it crashes" into named lines.
They work on any FPC program and are worth checking in as scripts.

**Symbolise a heaptrc trace on macOS (PIE binaries).** Addresses in a heaptrc report
are raw; with PIE they need the slide.

1. Build the suspect with `-gh`.
2. `DYLD_PRINT_SEGMENTS=1 ./binary` → read the `__TEXT` segment's base address.
3. `atos -o <binary> -l <text-base> <addr>…` for the addresses in the report.
4. Group the resolved frames by the first frame in *your* units, then read one full
   trace rather than a thousand partial ones. Going from "18,890 blocks" to
   "`ParseObjectPattern` → `ScanIdentifier`" is one step once this is scripted.

**Bisect a crashing input by line count.** Truncate the failing file and re-run until
the fault falls between two line counts (60 → 100, 70 → 80, 74 → 76), then read the
construct there. Turned a 244-line crash into a four-line repro in five runs.

**Find unowned classes mechanically.** `grep -E '^\s+\w+ = class$'` lists every class
that is not a subclass — that is the audit set for base-class-keyed ownership (GC-04).
There is no way to find these by reading the tree.

**Classify every `Free` before an ownership change.** `grep -nE '\w+\.Free;'` over the
AST **and the parser**: each site is *container (keep)* or *node (drop)*. Recovery and
error paths are the ones you will miss (GC-05), and under a shared owner a wrong one
is a crash, not a leak.

**Prove a fix with a flat line, not a smaller number.** For any leak, the test is
"unfreed blocks do not vary with N", where N is statements, files, engines, or
threads depending on the subsystem. A reduced constant is what a partial fix looks
like.

---

## 5. Workstreams and sequencing

Seven workstreams. The order below is chosen so each one makes the next one
*verifiable*, not because it is the order of severity.

| # | Workstream | Covers | Why at this position | Effort |
| --- | --- | --- | --- | --- |
| 1 | **Observability** | GC-34, GC-35, GC-39, GC-37, GC-38, GC-36 | You cannot fix what you cannot see, and today's gate is single-platform and its number is not meaningful. Land this first even though it fixes no bug. | M |
| 2 | **Ownership** | GC-01 … GC-12, GC-40 (the doc) | The largest and most valuable. Design doc first, then the three-scope arena, then the audit of every `Free` in AST *and* parser. | L → XL |
| 3 | **Lifecycle** | GC-13 … GC-17, GC-43 | Follows ownership: once the tree has an owner, the process-global state is the remaining reason a leak checker cannot reach zero. Needs the `Shutdown` decision. | M |
| 4 | **Build and packaging** | GC-18 … GC-26, GC-41 | Independent of the above and immediately valuable: namespacing, `-Sew` cleanliness, `-gl`, the flag matrix, tarball reproducibility. Can run in parallel with 2. | M |
| 5 | **Public API** | GC-27 … GC-33, GC-44, GC-42 | Only meaningful once ownership and lifecycle have settled; publishing a facade over a moving surface locks in the wrong shape. | L |
| 6 | **Async surface** | GC-45, GC-46, GC-47, GC-32 (clock) | Depends on 5 (the hook belongs on the facade, not a runtime extension). | S → M |
| 7 | **Footprint** | GC-26, plus the feature matrix in GC-41 | Do last: it is a build configuration question, and the answer depends on what the API ended up requiring. | M |

**Dependencies.** 1 → 2 → 3 → 5 → {6, 7}. 4 is independent and should be interleaved
whenever the ownership work needs a break or a compile.

**A note on 2.** Do not start it as a patch. Write the ownership document first —
who owns the tree, who owns a program, the three scopes, what the collector owns, and
the `TGocciaLiteralExpression` handoff (GC-12). The first attempt at this area failed
precisely because the plan assumed one scope and the module loader and shim cache
made that wrong (GC-08); the design document is where that gets caught, not after
eighty-seven units are edited.

---

## 6. Embedder-readiness checklist

The acceptance test for "can a host link this library and trust it". Each row is a
pass/fail with a command; none is an opinion. Treat it as the definition of done for
workstreams 1–5.

| # | Criterion | Decides |
| --- | --- | --- |
| A1 | **Ownership is one nameable decision**, written down in ≤ 20 lines: who allocates, who frees, and how many owners exist for a parsed program. | GC-01, 02, 04, 08 |
| A2 | **Strict zero on every supported platform**, for: one engine created and freed; N engines in a loop (flat in N); the vendor's full corpus. | GC-13, 14, 34, 35 |
| A3 | **The corpus runs in the host's gate**, not on request — so a regression cannot land between releases. | GC-36, 37 |
| A4 | **Builds with the host's flags**, including `-gl` and `-Sew`, with no blanket pragma and no compiler crash. | GC-19, 21, 22 |
| A5 | **A small public surface**: a facade unit whose own `uses` closure is the API, plus an assertion that no internal unit leaks into it. | GC-27 |
| A6 | **No unit-name collisions** with the RTL/FCL: a host using `fpjson` still parses JSON correctly with the engine linked. | GC-18 |
| A7 | **Every `Pin*` has an `Unpin*`**, and a `Shutdown` exists for state that is deliberately process-lifetime. | GC-13, 14, 43 |
| A8 | **Malformed input never crashes** and never corrupts: guest errors come back as values; integrity faults are reported as such and quarantined. | GC-31, 38 |
| A9 | **A documented lifecycle**: create → run → dispose → (optional) shutdown, with no host poking the collector. | GC-17 |
| A10 | **Reproducible from a tarball**: pinned, checksummed, compiles offline with no scripts run first. | GC-24 |
| A11 | **Measured footprint**: binary size, startup, per-run memory, and the size of each optional feature, published rather than asserted. | GC-26 |
| A12 | **Declared limits**: clock, instructions, bytes, output — each with a test that fails when the limit is removed. | GC-29 |
| A13 | **Declared determinism**: clock, random and TZ injectable; runner and host agree for the same injected values. | GC-32, 47 |
| A14 | **Declared realm semantics**: same-engine successive runs either share or do not share mutated intrinsics, and the cheap correct path is available either way. | GC-33 |
| A15 | **A capability conformance corpus**: one test per denied capability. | GC-30 |

**A15 and A8 are the two that decide whether this is safe rather than merely
well-built.** The rest decide whether it is pleasant.

---

## 7. What I did not verify

Be adversarial with this document before relying on it.

- **Revision drift.** Everything above was observed at `ast-arena` tip `b5acee64` /
  upstream `531fb52`. Upstream `main` had diverged by ~230 source files. Re-run each
  *proof* before filing; some items may be fixed, and a fixed item filed upstream
  costs credibility for all the others.
- **Items I inferred rather than measured** are stated as such: GC-29 (memory cap —
  limit units exist, but I did not find a bytes cap; if one exists it is not
  discoverable), GC-30 (no global-usage auditing — I did not find it; absence of
  evidence), GC-33 (realm isolation — I did not find a documented guarantee, and did
  not construct the test either way), GC-46 (no drain-and-report — I read the
  microtask API, not the whole loader).
- **Line numbers are deliberately omitted.** They move; the file and symbol names
  do not.
- **Severity is judged from an embedder's perspective**, i.e. "does this stop me
  shipping". A pure interpreter reading the same code might rank things differently.

---

## 8. Fork and upstream hygiene

If this is followed through on a fork — which is the sensible path, since some items
(GC-08 in particular) are design changes rather than fixes:

**One commit per issue.** Not per area. A reviewer must be able to accept GC-05 and
reject GC-06, and a future rebase must be able to drop one. Prefix each commit with
the register ID in the subject line (`fix(ast): [GC-02] …`) so the fork's log *is*
the issue tracker.

**Every commit carries its gate.** The test from the *proof* column, in the same
commit. A fix without one has already regressed once.

**No reformatting.** Diffs must be readable against a fast-moving upstream; a
whitespace pass in a commit makes the next rebase a conflict across every file it
touched.

**Split upstreamable from fork-only, explicitly.** Rough split:

| Upstreamable as-is | Fork-only until a design decision lands |
| --- | --- |
| GC-18 (namespacing), GC-19 (warnings), GC-20 (`constref`), GC-24 (checked-in include), GC-02, GC-09, GC-10, GC-05, GC-34, GC-37, GC-39, GC-42, GC-45 | GC-01/08 (ownership model), GC-13/14 (lifetime policy), GC-21/22 (mode and `-gl`: needs an FPC-side answer first), GC-23 (cycle breaking), GC-27/28 (API shape), GC-32/33 (determinism and realm semantics) |

**Keep the fork rebasable.** One branch per workstream, rebased onto upstream `main`
regularly rather than merged. A fork that cannot rebase becomes a product, and then
the upstream PR never happens.

**File upstream in register order, cheapest first.** A maintainer's confidence is
built by a stream of small accepted fixes (GC-18, GC-19, GC-20, GC-24 all qualify)
before the argument for a redesign (GC-01) is made. The redesign is far easier to
land once the reporter has a track record of correct, tested, minimal patches.

**One thing to say in the ownership PR's description.** The reason a single-scope
arena is not enough is not obvious and was learned expensively: the module loader
frees programs at five sites and the shim cache holds one per shim for the thread's
lifetime, deliberately. Anyone reviewing a "just add an arena" patch needs that
context, or they will accept a patch that double-frees both.
