# GocciaScript embedding findings (harness-side)

> **Historical (2026-10-18).** The findings below are folded into the standalone
> register at [gocciascript-embedder-issues.md](gocciascript-embedder-issues.md)
> — read that first. `deps/goccia` no longer exists and the scripts referenced
> here now live in `docs/features/Composed_Tool_Sandbox/scripts/`. This record is
> kept because it is the pin-a-fork rationale and the upstream PR body.

Observations from embedding the vendored engine (`deps/goccia`, pinned
`531fb52`) in the harness. Each is a candidate upstream issue/PR; the harness
works around them in `scripts/patch-goccia.sh`.

## 1. `JSONParser` unit name collides with the FCL — breaks the host

The engine vendors `source/shared/JSONParser.pas` as `unit JSONParser`. The FCL
ships a unit of the same name (`fcl-json/jsonparser`), which any host using
`fpjson` (for `TJSONData`/`GetJSON`) also links. On a case-insensitive
filesystem (macOS, default) the two cannot coexist: the engine's unit shadows
the FCL one, so the moment the engine is linked, every host `GetJSON` call
fails to compile / resolves to the wrong unit.

Symptom in the harness: linking the engine silently broke the file tools and
the SQLite store (their JSON parsing), with no error at the engine boundary.

**Suggested fix:** rename the engine unit to a namespaced name
(`Goccia.JSONParser`) and update its eight `uses` references. The harness does
exactly this in `patch-goccia.sh`. It is a pure rename — no API change.

## 2. The engine does not compile under `-Sew` (warnings-as-errors)

The engine's own code emits warnings that a host building with `-Sew` treats as
errors: unreachable code in `source/shared/HashMap.pas`, "Constructor should be
public" in `Goccia.Values.Primitives.pas`, and `UnicodeString`→`AnsiString`
conversions in `source/shared/TextSemantics.pas`. A host cannot compile the
engine with the same strictness it applies to its own units.

**Suggested fix:** either silence these specific warnings at their sites, or
document that the engine must be compiled without `-Sew`. The harness injects
`{$WARNINGS OFF}` into the engine's shared include (`Goccia.inc` →
`Shared.inc`) via `patch-goccia.sh`.

## 3. Process-global singletons are pinned at engine construction, never unpinned

`TGocciaEngine.PinSingletons` (called from the constructor) pins the primitive
singletons (`UndefinedValue`, `NullValue`, `TrueValue`, `FalseValue`), the hole
value, and eagerly creates the BigInt singletons. There is **no** `UnpinObject`
call for any of them anywhere in the engine — the pin has no counterpart.

Under heaptrc, constructing and freeing an engine therefore leaves a fixed
block count unfreed (the singleton graph plus per-realm intrinsics the pin keeps
alive). It does not grow per engine (it is a one-time process cost), but it
means a host that runs its own test suite under heaptrc cannot reach zero.

The engine's own heaptrc gate (`.github/workflows/fuzz.yml`, `memory-safety`)
asserts **zero** unfreed blocks — but it runs **Linux-only** (`ubuntu-latest`),
so this macOS behaviour is untested upstream. Running the engine's own runner
under heaptrc on macOS reports ~18,890 unfreed blocks on a single trivial test.

**Suggested fix:** decide the intended lifetime of the pinned singletons. If
they are process-lifetime by design, unpin (do not free) them at a host-callable
teardown so heaptrc can account for them; if they should be freed, add the
`UnpinObject` calls to `TGocciaEngine.Destroy`. Extending the heaptrc CI to
macOS would have caught this.

### Harness workaround

The facade calls `TGarbageCollector.Instance.Collect` after freeing each
engine, which releases the destroyed realm's now-unpinned intrinsic graph. That
drops the harness suite's unfreed count from 77,917 to a fixed 2,481 (independent
of how many scripts run). The harness's leak gate (`Makefile`, `test-leak`)
allows that documented floor and fails on any count above it, so a new per-run
leak still fails the gate.

## The fork (2026-10-17)

The three compatibility fixes now live in a **fork**, not in `patch-goccia.sh`:

- Fork: <https://github.com/johnrcui/GocciaScript>
- Branch: `hildegard`, based on upstream `531fb52`
- Commit pinned by the harness: `312ddd19`

```
92775fda  fix(fpc):   constref -> const for FPC 3.3.1's TComparison<T>
88b0cb5c  build:      silence the engine's own warnings under -Sew
312ddd19  fix(units): rename JSONParser to Goccia.JSONParser
```

`scripts/fetch-goccia.sh` now fetches
`https://github.com/johnrcui/GocciaScript/archive/312ddd19....tar.gz` and
verifies its SHA-256
(`272ec3342f89887f4d2ddffc57251751b67abce20cf6188894cb3fd86fbfddca`).
`scripts/patch-goccia.sh` is reduced to an **assertion**: it checks the fetched
tree actually carries all three fixes, so a bad pin fails loudly instead of
silently building an unpatched engine. A re-fetch can no longer lose the fixes.

Why a fork rather than `scripts/patches/*.patch`: the harness's own reason for
the fixes is FPC-3.3.1 compatibility, not upstream adoption, and the fork keeps
them as reviewable commits against the exact base. The upstream PR, when we
choose to send it, is a rebase of these commits onto current `main` — the
findings above are its body.

### Still ours to finish (the AST leak)

The arena work is unchanged and unstarted in the tree; see
`docs/research/goccia-ast-arena.md` for the decision, the three-scope
correction (entry / module / shim), the resume steps and the WIP location.
When it lands it becomes a fourth commit on `hildegard`.
