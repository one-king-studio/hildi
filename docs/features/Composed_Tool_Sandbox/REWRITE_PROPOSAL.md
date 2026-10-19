# Composed Tool Sandbox v2 — Rewrite Proposal and Handoff

**Status:** proposal, not a specification. Nothing here is approved.
**Audience:** the agent who may rebuild the composed tool sandbox on a fixed
GocciaScript.
**Written:** 2026-10-19, from the parked v1 (`cdf3afe`).

> **You are being handed a decision, not a task list.** The first job is not to
> write code — it is to run GocciaScript through the admission battery in
> [§5](#5-the-admission-battery-apply-this-before-writing-any-code) and report
> pass/fail. If it fails, the correct outcome is *leave it parked*, and that is a
> completable, valuable result.

---

## 1. What this document is, and what it is not

The v1 sandbox is parked (`FEATURE.md` → *Status: parked*). Its code, tests and
scripts are kept, working, in this directory; none of it is in the build. The
engine was detached from the binary and `deps/goccia` deleted.

The operator has since **forked GocciaScript** (`github.com/johnrcui/GocciaScript`,
branch `ast-arena`, final pin `b5acee64`) and intends to fix the engine's issues
**separately, upstream**. That changes the shape of the remaining question. It is
no longer "should we keep patching the engine?" — it is:

> *If the engine becomes trustworthy, what should the sandbox look like the second
> time, and what from v1 was actually ours rather than the engine's?*

The answer, argued below: **most of what we built is worth keeping and almost none
of it needed the engine to be good.** The harness-side design — a gated,
reason-carrying, registry-backed `tools` object with an invoker seam that a fake
can satisfy — is sound and fully testable with zero engine code. What went wrong
was that we let the engine's defects set our standards: a leak gate relaxed to a
floor, warnings silenced wholesale, a mode flag withdrawn from the whole build,
and a facade that `uses` 18 engine internals. Those are the things to get rid
of — not the security design.

**Not in scope here:** the engine fixes themselves (the operator owns them), the
shell gate (`Tree_Sitter/`, still the better answer to the *original* problem),
and any change to the harness outside the sandbox.

---

## 2. The full issue list

Four groups. Every item was observed, not inferred; the "evidence" column points
at where it is recorded so you can check it rather than trust this list.

### 2.1 Engine correctness — ownership defects (the reason it was parked)

All of these are the *same shape*: ownership declared in one place and violated
in another. They are invisible until a specific path runs.

| ID | Issue | Evidence |
| --- | --- | --- |
| **E1** | The whole AST leaked. `TGocciaASTNode` is a bare `TObject` the GC never sees; every node-to-node edge is a raw field with no owner. Parse-only: 13 unfreed blocks for 1 statement, 805 for 100 (~8/statement, unbounded in script size). | `goccia-ast-arena.md` → *Context* |
| **E2** | `TGocciaProgram` had **no destructor**, so its owned body list was never freed — one list per parsed script. | E1; *Deeper dig* §2 |
| **E3** | **Latent use-after-free.** A closure does not copy its body: `TGocciaFunctionValue.FBodyStatements` holds pointers into the AST, which was freed at end of run. On the documented long-lived-engine pattern (one `Execute` defines `f`, a later one calls it) that is a dangling pointer. The leak was the visible symptom; this was the dangerous one. | *Context* |
| **E4** | **Four node-holding classes never registered with the arena** because they do not descend from `TGocciaASTNode`: `TGocciaDestructuringProperty`, `TGocciaObjectMatchProperty`, `TGocciaMatchClause`, `TGocciaClassDefinition`. The last was worst — our flip had *dropped its free* on the assumption the arena owned it. | *Deeper dig* §1 |
| **E5** | **Four parser recovery paths freed arena-owned nodes** — a double free that crashed the test runner (`EBusError`/`EAccessViolation`). Only reachable in warning-recovery mode, which is why no single-file probe found it. | *RESOLVED: the warning-recovery integrity fault* |
| **E6** | `DefaultOptions` left the new `Arena` field **uninitialized** — callers passed a garbage pointer. This was the crash. | *Five bugs the ownership change exposed* §1 |
| **E7** | **Free-order bug:** the engine freed its arena *before* the builtins, interpreter, realm and module loader that parse into it. | same §3 |
| **E8** | Module result and tagged-template destructors freed arena-owned nodes; the object-literal parser orphaned its insertion-order temporary. | same §4, §5 |
| **E9** | **Three arena scopes, not one.** The module loader frees programs at five sites; the shim cache is a **threadvar** holding one parsed program per shim that is *deliberately never released* (its own comment records an earlier 1.1 MB-per-engine leak from exactly this). A single engine-scoped arena double-frees both. | *Update: the module loader and shims already depend on AST lifetime* |
| **E10** | **`PinSingletons` has no counterpart.** Primitive/hole/BigInt singletons and the per-realm prototype graph are pinned at construction and never unpinned, so nothing can free them. Harness floor: a flat **244** blocks. | `goccia-embedding-findings.md` §3; *The floor, fully characterized* |
| **E11** | **Residual retention** beyond the AST: lexer identifier strings reached from `ParseObjectPattern` (1,534 → 355 blocks on `language/asi`), scaling with file count. Tokens or destructuring keys held past the tree. | *Still open* |
| **E12** | The vendor's own heaptrc gate asserts **zero**, but runs `ubuntu-latest` only — so the macOS leak was untested upstream, and the engine's own runner reported 18,890 unfreed blocks on a trivial file. | `goccia-ast-arena.md` → *Context* |

**Cost:** six fork commits, and **five further defects found only by chasing the
first five**, each time by running the engine's own suite. That is the finding, not
the individual bugs.

### 2.2 Engine embedding — compatibility defects

| ID | Issue | Evidence |
| --- | --- | --- |
| **E13** | **Unit-name collision with the FCL.** The engine vendors `unit JSONParser`; so does `fcl-json`. On a case-insensitive filesystem the engine's shadows ours and **silently breaks the host's `fpjson`** — the file tools and the SQLite store stopped parsing, with no error at the engine boundary. | `goccia-embedding-findings.md` §1 |
| **E14** | **Does not compile under `-Sew`.** Unreachable code in `HashMap`, "constructor should be public" in `Primitives`, `UnicodeString`→`AnsiString` in `TextSemantics`. We injected `{$WARNINGS OFF}` into the engine's shared include to get it to build at all. | same §2 |
| **E15** | **`constref` vs `const`**: seven sites declare comparison callbacks `{$IFDEF FPC}constref{$ELSE}const{$ENDIF}`; FPC 3.3.1's `TComparison<Int64>` wants plain `const`. | `FEATURE.md` → *Two integration obstacles* #1 |
| **E16** | **`{$mode delphiunicode}` per unit.** Forcing `-Mdelphi` clashes and **crashes the compiler** (first a type error, then a nondeterministic `EAccessViolation`). The whole build had to stop passing `-Mdelphi` — a project-wide rule adopted to accommodate one dependency. | `FEATURE.md` #2; `AGENTS.md` → *FPC / Platform Notes* |
| **E17** | **The debug build crashes the compiler.** `-gl` makes `ppca64` die with an `EAccessViolation` at a *different unit each run*. The engine builds with its own production flags (`-O4 -dPRODUCTION`) and not with ours — and `make check` uses ours. Debugging through the boundary was therefore heaptrc-only, with no line info. | `FEATURE.md` #2 |
| **E18** | **A shared ppu cache never converged.** FPC recompiled the engine's circular core cluster (~87 units) every build regardless, and a consumer whose flags differed from the cache's crashed the compiler. Forced per-target compilation. | `Composed_Tool_Sandbox_v1.SPEC.md` → *Build integration* |
| **E19** | **Build-time codegen**: the engine expects `build.pas` to generate `Goccia.Version.Generated.inc`. We added `gen-goccia-version.sh` to fake it. | `scripts/gen-goccia-version.sh` |
| **E20** | **Footprint**: ~8 MB of engine against an 8 MB TUI (a doubling) in release; the runtime binary went 34 MB with the engine linked → 8 MB after detaching. | `FEATURE.md` → spike recommendation; parking commit `9e4e584` |

### 2.3 Our integration — the harness-side defects

These are ours, and they are the ones to *not repeat*.

| ID | Issue | Evidence |
| --- | --- | --- |
| **I1** | **We weakened a gate for a dependency.** The harness's leak gate is strict zero. With the engine linked it became a *floor*: 77,917 unfreed blocks at first link (2,481 after a post-run collect), then 2,588 → 400 → 244 as the arena and singleton work landed — a number written into the SPEC and this repo's docs as an allowance. A gate that cannot reach zero has stopped being a gate; it only catches *growth*. | `Makefile` history; `goccia-embedding-findings.md` §3 |
| **I2** | **The facade `uses` 18 engine units** — `Goccia.Executor.Interpreter`, `Goccia.GarbageCollector`, `Goccia.Scope`, `Goccia.Threading`, `Goccia.Values.*`, … The stated goal was "one place to change on upgrade"; the effect was a facade welded to internals, which is the opposite. | `src/hildegard.helper.script.pas` → `implementation uses` |
| **I3** | **We poked the collector from the host** — `TGarbageCollector.Instance.Collect` after every run — to paper over E10. A host reaching into a dependency's GC is a defect in the boundary, not a fix. | `goccia-embedding-findings.md` → *Harness workaround* |
| **I4** | **Promise machinery we did not need.** Tool calls were modelled as async natives that *block inside their callback* and return an already-settled promise, so the script could `await` them. It works, but it is a whole concurrency model crossing the boundary to express "a synchronous host call". | `gocciascript-async.md` → *TL;DR* |
| **I5** | **Our probes all passed while the real path crashed.** Single-file probes (interpreter, bytecode, module) each ran the failing file cleanly; only the vendor's own runner setup (testing-library globals + module loader + shims) reached E5. **A capability boundary you cannot test end-to-end is not a boundary.** | `goccia-ast-arena.md` → *What it is not* |
| **I6** | **The vendor's test corpus was not in `make check`.** We only ran it when chasing a symptom. That is why five defects arrived one at a time. | *Five bugs*; §5 of `vendored-engine-lessons.md` |

### 2.4 Process

| ID | Issue |
| --- | --- |
| **P1** | **The dependency set the standards.** Six fork commits, three build scripts, a project-wide compiler-flag rule, a relaxed gate and a silenced warning set — all to make a component fit. Each was locally reasonable; together they are the tell that the component was not ready. |
| **P2** | **Sunk cost nearly won.** The arena was correct and green when we parked; the temptation was to carry on because of what had already been spent. The reframing ("the problem was the shell, not the absence of a scripting tier") is what made stopping cheap. |
| **P3** | **The value was never measured against the goal.** The feature existed to stop the model hiding a loop inside one unobservable `bash` approval. A sandbox that runs a model-authored program *is* an unobservable interior — it is only safe because each sub-call is separately gated, which is exactly what gating the shell would also achieve. |

---

## 3. What is actually ours (keep this)

The part of v1 that had nothing to do with the engine. It is testable with a fake
invoker and no vendored code at all, and it should be ported essentially verbatim.

### 3.1 The security design — keep, unchanged

1. **Capability-free core.** `TGocciaCapabilities.None`; no filesystem, network,
   FFI, exec, or clock. The injected `tools` object is the only reachable surface.
2. **The tools object is a *view over the registry*, not a second registry.** Every
   `tools.*` call routes to the same registered tool, so the approval ref, the
   `reason` requirement, the audit row and the snapshot interception are identical
   to a direct call. *If any method bypassed that, the sandbox would be an ungated
   shell one level up.* This is the load-bearing decision of the whole feature.
3. **`run_command` is not injected. `recall_tool_result` is not injected.**
   `run_script` is not re-entrant. (`ScriptExcludedTools`.)
4. **The script's `reason` flows to every sub-call**, and each sub-call raises its
   **own** approval ask. A loop over 40 files is 40 asks (with the same options a
   direct call offers), not one.
5. **`script:run` is approved before the engine starts.** A denial runs nothing.
6. **Limits**: wall-clock timeout wired to the turn's cancel check, instruction
   cap, memory cap, output cap — with defaults 30 s / 50 M instructions /
   256 MiB / 32 KiB (`DefaultScript*`).
7. **Structured result**: stdout, return value, typed error. A guest fault is
   never a crash and never a raise; an **engine-integrity fault**
   (`EObjectCheck`, `EAccessViolation`, `EInvalidPointer`, `EDivByZero`,
   `EPrivilege`, `EExternalException`) is surfaced as a failed call, not swallowed.
8. **An engine per script** for realm isolation (a script can mutate intrinsics).
   Keep the *requirement*; consider the *mechanism* (see §4.2).
9. **`tools` naming**: snake_case, one global object, methods matching registry
   names one-for-one — so the model can transfer knowledge between a direct call
   and a scripted one.

### 3.2 The seam — keep, unchanged

```pascal
TScriptToolInvoker = function(const AName, AArgumentsJson,
  AReason: string; out AResult, AError: string): Boolean of object;
```

This one line is the whole architecture. It means:

- the security model is testable with a fake (v1's `tests/test_script.pas` drives
  `AInvoke` with a recording `TFakeInvoker` for name, args, reason and
  allow/deny — those tests are about the seam, and in v2's split they belong to
  L0, where no engine is linked at all);
- the engine is *replaceable*, and the replacement's job is bounded;
- approval, audit, snapshots and the registry need to know nothing about scripts.

**Protect it.** Any v2 change that makes the invoker aware of the engine, or the
engine aware of `TToolRegistry`, is a regression.

### 3.3 Pure helpers — keep

`IsScriptExcludedTool`, `FilterScriptTools`, the approval-ask construction
(`script:run`, one `once` option, `Persists := False`), the tool description and
its JSON schema (required `reason`), the argument/result marshalling at the JSON
boundary.

### 3.4 Method — keep, and it is the most valuable thing here

- **The symbolization loop**: build the suspect under `-gh` → `DYLD_PRINT_SEGMENTS=1`
  for the `__TEXT` base → `atos -o <bin> -l <base>` on raw heaptrc addresses →
  `leakcat.py` to group by first frame in *our* units → `trace_needle.py` for one
  full trace. Tools live in `build/script-check/`.
- **Line-count bisection** for a crashing input: truncate and re-run until the
  fault falls between two line counts, then read the construct.
- **Run the vendor's own suite under our sanitizer**, on **every** platform we
  ship. Not a courtesy; the only thing that found E5.
- **Pin a fork you can patch.** Fetch by SHA, verify SHA-256, and reduce the patch
  script to an *assertion* that the fetched tree carries the fixes — so a bad pin
  fails loudly. v1's scripts in `scripts/` are the template.
- **Fail safe, never fail open.** A gate's error budget is asymmetric: too many
  asks is a nuisance, too few is a breach.

### 3.5 Documents — keep as the archive

`Composed_Tool_Sandbox_v1.SPEC.md`, `..._v1.PARKED.md`,
`docs/research/goccia-ast-arena.md`, `goccia-embedding-findings.md`,
`gocciascript-async.md`, `gocciascript-embedding.md`, and
`docs/research/vendored-engine-lessons.md`. The last is the generalizable one; if
you read only one thing before starting, read it.

**Companion document:** `docs/research/gocciascript-embedder-issues.md` is this
issue list with all host-project references removed — a self-contained register of
47 items on the engine itself, plus workstream sequencing, a 15-point
embedder-readiness checklist, and fork/upstream hygiene. Use that one for engine
work; use this one for sandbox work. Keep them in sync when a new defect is found:
the engine doc is the artifact that should outlive this feature.

**Do not edit v1's docs to match v2.** They are a record of a decision. A v2 gets
its own files.

---

## 4. What to get rid of

### 4.1 Hard drops (do not rebuild these)

| Drop | Why |
| --- | --- |
| **The leak floor (I1).** No `LEAK_MAX_BLOCKS`, no documented floor. | If the suite cannot pass strict zero with the dependency linked, the dependency is not admissible. That is the whole point of the gate. |
| **Wholesale `{$WARNINGS OFF}` injection (E14).** | Either upstream silences *specific* warnings at their sites, or the engine is compiled without `-Sew` in a target whose output we never link into the test binary. A blanket pragma hides our own future warnings too. |
| **A host-side `GC.Collect` after each run (I3).** | A host reaching into a dependency's collector is a defect in the boundary. Demand a documented `Shutdown`/`Dispose` that unpins and frees (the counterpart `PinSingletons` never had). |
| **The `-Mdelphi`-withdrawal rule (E16) as a project-wide constraint.** | Drop the rule *if* the engine can be compiled under our mode; keep it as a documented vendored-dep rule only. It should not be a fact about our build. |
| **Per-target recompilation of ~87 units to work around a non-converging cache (E18).** | Either the engine's units resolve into a stable cache, or its build cost is measured and accepted as a stated number. "It never converged" is an unanswered question, not a build strategy. |
| **Promise-based tool calls (I4).** | Prefer a synchronous host call. Add a promise only where the host genuinely defers *and* the engine offers a documented host hook. Do not spend a concurrency model on "call a function and wait". |
| **`gen-goccia-version.sh` (E19).** | Ask upstream to ship the generated include, or make it a committed file. A build that runs codegen before it can compile is a build that cannot be reproduced from a tarball. |
| **Engine internals in the facade's `uses` (I2).** | v2's adapter may `use` only the engine's *public embedding surface*. If that surface is not enough to do the job, the missing method is an upstream request, not a host-side reach-in. Write that surface down as a prerequisite (§5 A5). |

### 4.2 Design questions to re-open (not automatically keep)

These were reasonable in v1 and are worth a fresh decision, because the reason we
chose them was engine weakness rather than product need.

1. **Engine per script, or one engine reused?** v1 recreated the engine per script
   because a script can mutate intrinsics. With a correct `Dispose` and documented
   realm isolation this may be a contract instead of a workaround — which is also
   much cheaper (v1 paid a full parse-and-link of builtins per call, plus a GC
   collect).
2. **The memory cap.** A cap with no test that fails when it is removed is a
   promise, not a limit. Either write the test that proves the engine enforces it,
   or delete the field from `TScriptLimits` and say so.
3. **`TypeScript-style type annotations` in the tool description.** v1 advertised
   them because the engine parsed them. They are not needed for the feature and
   are a promise about a dependency's surface. Advertise only what we test.
4. **In-process at all?** A separate script worker process would make "the engine
   cannot take down the harness" structural instead of aspirational, at the cost of
   an IPC hop per tool call (each still gated identically) and a second binary.
   **Recommendation: no** — it is a new boundary to secure, and the tools are
   already the only reachable surface. Record the rejected alternative, so the next
   agent does not re-litigate it from scratch.
5. **Does this feature still earn its place?** P3. Re-ask it after the engine
   passes admission. If `Tree_Sitter` has by then made the shell ask set correct,
   the "the model reaches for bash to hide a loop" pressure may be gone. The honest
   answer may be *keep it parked* — which is allowed.

---

## 5. The admission battery (apply this before writing any code)

This is the deliverable I would most want from you. It turns "we have a great
testable Pascal project" into a checklist a dependency must pass. Each item is
**pass/fail with a command**, not an opinion. Record results in a new
`docs/research/goccia-admission.md`.

| # | Criterion | How it is proven |
| --- | --- | --- |
| **A1** | **Ownership is one nameable decision.** Every heap allocation has a single documented owner; prefer a handle/arena model; no base-class-keyed ownership. | Read the model; write down "who frees what" in ≤ 20 lines. If you cannot, fail. |
| **A2** | **Strict zero leaks, both platforms.** The vendor's own suite under heaptrc on macOS **and** Linux, zero unfreed blocks. | `make test-leak` with the engine linked; the vendor runner under `-gh` on both. |
| **A3** | **Adopt the vendor's corpus into our gate.** Their suite runs in `make check`, not on demand. | New target, green in CI-equivalent local run. |
| **A4** | **Builds with *our* flags**, including `-gl`/`-Sew`, or is compiled in an isolated target whose output never reaches the test binary. | Compile the suite with the engine linked; no compiler crash, no blanket pragma. |
| **A5** | **A small public embedding surface.** The adapter `uses` only documented public units; ≤ 5 new engine units in the closure. | Count the adapter's engine `uses`; diff against a written API list. |
| **A6** | **No unit-name collisions** with RTL/FCL/our vendored deps. | Full build of the host with the engine linked; `fpjson` still works. |
| **A7** | **No process-global state without teardown.** Every `Pin*` has an `Unpin*` + a `Shutdown`, or is explicitly process-lifetime *and* accounted for. | Grep for `Pin`; construct/dispose N engines in a loop under heaptrc; flat. |
| **A8** | **Malformed input never crashes.** A fuzz corpus or equivalent; the boundary returns errors as values. | Run it. |
| **A9** | **A documented lifecycle**: create → run → dispose, no host GC pokes. | The facade has no collector reference. |
| **A10** | **Reproducible from a tarball**: pinned SHA + checksum, no network at build, no required codegen. | Fresh clone → `make check`, offline. |
| **A11** | **Stated footprint**: binary delta, startup, per-run memory — measured, against the value | Numbers in the SPEC, not adjectives. |
| **A12** | **A degraded mode, or an honest admission that there is none.** | Written down. A sandbox has no "more conservative" mode: a script runs or it does not. So it must not be the *sole* protection for any property. |

**A12 is the one that decides whether the feature is safe at all.** v1's gate was
correct because *each sub-call* is gated — the script adds orchestration, not
authority. A v2 must preserve that property and say so in one sentence, because it
is the answer to "why is an interpreter not a backdoor?".

**Exit gate:** A1–A12 all pass → proceed to §6. Any fail → write the result up,
leave the feature parked, and say which criterion failed. Do not start a v2 to fix
an A-item.

---

## 6. The v2 shape, if it passes

Four layers, strictly one-directional. The bottom two are pure Pascal with no
vendored code; the engine appears in exactly one unit.

```
L3  wiring          session registers run_script        (≈30 lines, from v1)
L2  tool            hildegard.helper.tool.script       (v1, essentially unchanged)
L1  adapter         hildegard.helper.script.engine     (NEW, ≤ ~200 lines, the only engine `uses`)
L0  contract        hildegard.helper.script            (v1's types + pure helpers; ENGINE-FREE)
```

**L0 — the contract.** `TScriptToolInvoker`, `TScriptCancelCheck`,
`TScriptLimits`, `TScriptResult`, `IsScriptExcludedTool`, `FilterScriptTools`, the
default constants, and a `TRunScript = function(...): TScriptResult` seam so L2
can be tested against a fake runner. **L0 must not `use` any engine unit, and the
Process Split test should assert that** — the same mechanism that keeps the TUI
engine-free (`tests/test_split.pas`).

**L1 — the adapter.** Implements `TRunScript` over the engine. Its whole job is
translation: build the realm, inject `tools`, run, map the result, dispose. Rules:

- no ownership decisions of its own — allocate nothing the engine's API doesn't
  hand back;
- no collector, no collector flags, no retries;
- no `{$WARNINGS OFF}`, no mode switching, no conditional-unit tricks;
- every line justified against a v1 line: if a line existed only because of
  E4–E10, it must not survive.

**L2 — the tool.** v1's `hildegard.helper.tool.script` is the model: parse args,
require `reason`, approve `script:run`, build the invoker over the registry, run,
format the result. Changed only to call L0's seam.

**Test plan (TDD, one test per requirement — this is the part to get right):**

| Test | Proves |
| --- | --- |
| pure compute returns its value | the seam works with no tools |
| syntax error → `Ok=False`, message, **no raise** | guest faults are values |
| console output captured; output cap truncates | output is bounded |
| injected call reaches the invoker with name + args + **script reason** | the reason flows |
| a denial inside the script is a script-level error naming tool + denial; the script may catch it | gate errors are recoverable |
| `run_command` / `recall_tool_result` / `run_script` are **absent** from the `tools` object | the exclusions hold (assert on the object, not on a filter list) |
| instruction cap stops a runaway; timeout stops a runaway; cancel stops a runaway | all three limits |
| engine recreated/isolated: a script mutating intrinsics does not affect the next | realm isolation — *whichever mechanism §4.2 picks* |
| integrity fault → failed call, harness survives the test process | the boundary is a boundary |
| **adversarial**: script attempts FS/network/exec/eval/host-global access and each fails | no ambient authority |
| the *real* registry path: a script calling `tools.file_read` triggers the same `file:read` ask and audit row as a direct call | the view-over-registry property — the one that matters |
| `make check` green at **strict zero** | A2/A11 |

The adversarial and registry-path tests are the two that v1's suite lacked in the
form that would have caught I5. Write them first.

**Phases, each with an exit gate:**

0. **Admission** (§5). Every artifact in `docs/research/goccia-admission.md`. *Gate:
   A1–A12.*
1. **L0 + fakes.** The whole security model, green, with no engine in the tree.
   *Gate: `make check` strict zero; Process Split asserts L0's closure is
   engine-free.*
2. **L1 adapter.** One unit; vendored code appears in the build for the first
   time. *Gate: the same L0 tests, now run against L1, unchanged; strict zero holds.*
3. **L2 + L3.** The tool and the wiring, from v1. *Gate: the registry-path test.*
4. **Re-ask P3.** Does the feature still earn its place now that `Tree_Sitter` may
   have landed? Write the answer down before advertising `run_script`.

**Stop rule.** At every gate, if the criterion fails, stop and park. v1's lesson is
that continuing past a failed gate is how one defect became six fork commits and
five more defects.

---

## 7. Invariants a v2 must not break

Cheap to state, expensive to lose.

1. `tools.*` is a **view** over the registry — never a cache, never a shadow.
2. The **reason** is the script's, and it reaches every sub-call.
3. The **engine cannot reach the shell**, directly or indirectly.
4. Nothing is **approved twice** and nothing runs **unapproved**.
5. Strict-zero leak gate; no floor, no exception.
6. The **TUI links no engine** (and, more generally, no agent/tool unit) — asserted
   by `tests/test_split.pas`, not by convention.
7. The **vendored tree is exactly a pinned revision**, and the patch script asserts
   rather than mutates.
8. Every acceptance criterion has a **named test** that fails if it breaks. A
   promise without a test is not a limit.
9. A **guest fault never takes down the harness**; an **integrity fault is never
   swallowed**.
10. The engine's own corpus runs in **our** gate, on **both** platforms.

---

## 8. Reading order

1. `docs/research/vendored-engine-lessons.md` — nine transferable lessons; the
   reason the shell, not a runtime, is the right place to fix the original problem.
2. `docs/features/Composed_Tool_Sandbox/FEATURE.md` → *Status: parked* — why we
   stopped, and what "park" means (code kept, not built).
3. `Composed_Tool_Sandbox_v1.SPEC.md` — the security design in full; keep §*Contracts
   & Interfaces* and §*The `tools` object*.
4. `docs/research/goccia-ast-arena.md` — the ownership story end to end; read *The
   transferable method* even if you skip the rest.
5. `docs/research/goccia-embedding-findings.md` — E13–E15, and the pin-a-fork
   pattern.
6. `docs/research/gocciascript-async.md` — only if §4.2 item 1 (engine reuse) or
   §4.1's promise question goes the other way from what I suggest.
7. `docs/features/Tree_Sitter/FEATURE.md` — the surviving answer to the original
   problem; read it to answer P3 honestly.
8. `AGENTS.md` → *FPC / Platform Notes* — the constraints that are now *general*,
   including the detached-engine record.

---

## 9. Open questions for the operator

1. **Scope of "re-create".** This proposal rebuilds the *integration* on a fixed
   engine, assuming the engine's issues are fixed upstream. If the intent is instead
   to re-create *the engine*, read §10 first: it turns the defect list inside out
   into design rules, and it is a much larger decision than §6.
2. **Which platform is the leak gate's truth?** v1's macOS leak was invisible
   upstream because the vendor's heaptrc job is Linux-only. A2 requires both. Is
   that affordable in the vendor's CI?
3. **Is a floor ever acceptable for a vendored dep?** My answer is no, and I1 is the
   evidence. Worth confirming, because it is the criterion most likely to be
   negotiated down under schedule pressure.
4. **Does the feature still earn its place if `Tree_Sitter` lands first?** (P3, §4.2
   item 5.)
5. **Is a small, correct scripting tier a product goal in its own right** — a
   re-runnable artifact a reviewer can keep (the SPEC's *reviewer* user story) — or
   only ever a means to stop the model reaching for `bash`? If the former, the
   admission bar is worth paying; if the latter, `Tree_Sitter` probably finishes the
   job and this stays parked.

---

## 10. Appendix: if "from scratch" means the *engine*, not the sandbox

§6 assumes the engine gets fixed upstream and we rebuild the integration. If the
real intent is to write a scripting engine from nothing, the defect list in §2 is
effectively a design document — read backwards. Each engine issue implies a rule:

| Defect | Design rule it forces |
| --- | --- |
| E1–E5, E8, E9 (ownership) | **Value semantics for the tree, or one owner per program.** Nodes are offsets into one arena buffer (`struct`-like), not objects with fields pointing at objects. One `Free` per parsed program, called by the code that owns it, and *no* class-keyed registration — a registration hook is a hole per class that forgets it. |
| E3 (dangling closure) | **A function value must not point into a freed tree.** Either copy the body it captures, or tie the tree's lifetime to the value that reaches into it, and make that visible in the type. A closure holding a raw pointer into an AST is a use-after-free waiting for a second `Execute`. |
| E6, E7 (init order) | **One constructor, one teardown, in reverse.** No "extra field added later" — a record with a lifetime gets an explicit `Init`/`Done` pair, and the compiler is not trusted to zero it. |
| E10, E12 (pin without unpin) | **Every process-global singleton is either freed in a `finalization` or documented as process-lifetime and counted.** No `Pin` without an `Unpin`. |
| E13 (unit collision) | **Namespace every unit** (`Engine.*`), including vendored shared helpers. Never `JSONParser`, `Types`, `Utils`. |
| E14 (`-Sew`) | **Ship clean under the strictest flags a host is likely to use**, or state the flags in one line at the top of the README with a CI job that proves it. |
| E15, E16 (mode) | **One mode, declared in an `.inc` the build includes once.** No per-unit `{$mode}` drift and no `{$IFDEF FPC}constref{$ENDIF}` — target the FPC you support and say which. |
| E17 (debug build crash) | **The debug build is the development build.** If `-gl` crashes the compiler, the library is out of reach of the tooling that finds its bugs. |
| E18 (cache) | **No circular unit graph in the core cluster.** Circular units force recompilation forever and were the root of the ppu cache never converging. |
| E19 (codegen) | **Check in generated version files.** A library that cannot compile from its own tarball is not releasable. |
| E11 (residual strings) | **Identifiers are interned into one arena too**; nothing in the lexer outlives the parse except the intern table, which the program owns. |
| I4 (promises) | **Do not build a concurrency model to serve one host pattern.** Ship a synchronous native-call hook first; promises are for the language's users, not for the embedder. |
| I5 (probes passed) | **The vendor's suite is the spec.** If a path is only reachable through the test runner's own setup, that setup *is* part of the API and must be documented. |
| I3 (host GC poke) | **Publish a lifecycle**: `Create` → `Run` → `Dispose`, and guarantee `Dispose` returns everything but documented process-lifetime state. |

**A from-scratch engine should be much smaller than GocciaScript**, and that is
the strongest argument for it: the features we need are expressions, statements,
functions, objects/arrays, `try`/`catch`, and *synchronous host calls*. Every one
of the twelve ownership defectors above lives in a feature we do not use — modules,
shims, regex, Intl (CLDR), typed arrays, BigInt, tagged templates, classes,
async/promises. An embeddable script tier for an agent harness is **not** a
JavaScript implementation; it is a small language with a gated FFI and a good
error surface. If the engine is re-created, scope it to that and put the admission
battery in `make check` from commit one.

**The honest warning.** v1 cost six fork commits and five further defects on a
*mature* third-party engine with its own test corpus. A from-scratch engine has no
corpus until you write one, which is the same work with less to lean on. Do it only
if the small-language scope above is a real product need that `Tree_Sitter` cannot
satisfy — not because the fork is annoying.

---

## 11. What I would say if asked for a bottom line

Keep the design, keep the seam, keep the method, keep the tests. Drop every
accommodation we made for the engine, and treat the admission battery — not the
feature — as the thing to build first. The most likely correct outcome is that
the battery is the whole deliverable and the sandbox stays parked; the second most
likely is a small `run_script` built in a week on top of a boundary that is
finally testable. Either is a good result. What is *not* a good result is a v2
that starts with the engine and works backwards.
