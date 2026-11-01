# FPC Gotchas

Free Pascal and RTL traps that cost real debugging time. These are about the
*language and runtime*, not a particular OS — for OS-conditional behaviour see
`platform-support.md`, and for test-specific findings see `testing.md`.

Each entry has the same shape: the symptom, the cause, the rule.

## Unicode

- **`cthreads` must be the first unit** in any Unix program, or threading and
  synchronization are broken at runtime. Not "slow" — broken.
- **`cwstring` immediately after it** in any program that handles non-ASCII text.
  Without it the RTL uses an ASCII-only widestring manager, so implicit
  `AnsiString`↔`UnicodeString` conversions (fpjson, tool arguments, command
  strings) replace each non-ASCII code unit with `?`.
- **`cwstring` present is not enough: the implicit `UnicodeString`→`string`
  conversion is still lossy in this build.** The *decode* direction
  (`UnicodeString(s)`, `UTF8Decode`) is fine, but `string(U)` / `AnsiString(U)`
  writes `?` for non-ASCII. The widestring manager is not a UTF-8 encoder here,
  and `SetMultiByteConversionCodePage(CP_UTF8)` does **not** fix it.

  Encode explicitly with `UTF8Encode(U)`, assign the `RawByteString` result to a
  `string`, and the receiving `UnicodeString(string)` decode reads it back
  correctly. The rule is: **`UTF8Encode` at every encode boundary.** This bit the
  session title, the compose's submitted prompt, and the modal's filter/rename.

## Containers

- **`TDictionary`'s `D[key] := value` setter raises `EListError` when the key is
  absent.** Use `AddOrSetValue`. The default property looks like an upsert and
  is not one.

## Units and compilation

- **Every unit self-declares `{$mode delphi}{$H+}`.** The build therefore does
  **not** pass `-Mdelphi`; it is redundant.
- **A vendored FPC library can use a different `{$mode}` than ours.** A vendored
  engine (the parked GocciaScript one did) may be `{$mode delphiunicode}` per
  unit; forcing `-Mdelphi` on it clashes and the compiler **crashes** — first a
  type error, then a nondeterministic `EAccessViolation`. Let any vendored FPC
  library set its own mode.
- **`{$R name.res}` resolves against the unit's OUTPUT dir, not its source dir.**
  A unit using `{$R Generated.X.res}` needs the `.res` findable — copied next to
  the `.ppu`, or on the unit search path.
- **FPC reuses a precompiled unit only when the consumer's flags match and the
  source is still on the search path.** The ppu records the *relative* source
  path, so `-FU` (output) and `-Fu` (search) must point at the **same** directory
  and the defines must match. A mismatch silently invalidates every ppu and can
  crash the compiler. This is why a vendored engine is better compiled **per
  target** than from a shared cache: a cache never converged in practice, and FPC
  recompiled the engine's circular core cluster on every build regardless.

## Warnings are errors

Tests compile with `-Sew`, so every warning fails the build. The one that bites
most often: **handle every `case` branch explicitly** — no bare `else` to silence
an unhandled enum value, and no relying on the compiler's coverage.

## Threads and memory

- **Always `WaitFor`/`Free` threads and their owned objects.** `make test-leak`
  enforces this (exit 203 on any remainder).
- Managed records and managed locals have their own traps, including a leak from
  `FillChar`; see `testing.md`, which collects them with the symptoms.

## Vendored dependencies

- **Pin a fork you can patch, and checksum it.** The parked sandbox's fixes ended
  up as commits on a fork, fetched by SHA and checksummed, with the patch script
  reduced to an *assertion* that the tree carries them. That beats `sed` patches:
  the tree is exactly a revision, a re-fetch cannot lose the fixes, and the diff
  is the upstream PR.
- **Read `docs/research/vendored-engine-lessons.md` before adopting another
  vendored parser or runtime.** It carries the nine lessons (ownership, fail-safe,
  the heaptrc + `atos` method, prefer the boundary you already have) into the
  Tree-Sitter work.

## Related

- `platform-support.md` — OS-conditional code and build flags.
- `testing.md` — the gates, and the FPC/FCL findings specific to tests.
- `tui-rendering.md` — measure/arrange and event-loop invariants.
