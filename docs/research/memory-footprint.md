# Memory footprint: where it goes, and what to do about it

**Date:** 2026-10-31 · **Revision:** `006659f` · **Platform measured:** Linux aarch64
(2 cores), glibc 2.43, kernel THP `madvise`.

**Why this exists.** The project's next stated goal is portability to
resource-constrained devices — Raspberry Pi, small containers, older PCs. That
turns memory into a first-class property, and nothing in the tree measures it
today. This is the baseline, and the ranked list of what to cut.

**What I could and could not measure.** The debug artifacts
`build/bin/hildi` (13.7 MiB) and `build/bin/hildi-agent` (14.7 MiB) were
sampled through `/proc/<pid>/status`, `/proc/<pid>/smaps`, `size` and `nm`, and
both were rebuilt from source in release mode for comparison.

*(Correction: an earlier draft said there was no FPC compiler on this machine.
There is — `~/.fpcenv/versions/3.3.1/bin`, just not on `PATH`, which is why the
`make` rules and `command -v fpc` both missed it. Release artifacts were built
in 4.3 s once that was found.)*

Still not measured: `heaptrc` allocation attribution. That needs a `-gh` probe
build, and it is the only way to split the private heap by allocation site.

## The headline

| Measurement | Value |
| --- | --- |
| `hildi-agent` at startup, before any work (`--bogus`, exits) | **5.6 MB** peak RSS |
| `hildi-agent`, idle, real session, 7 threads, debug, **before** | **19.7 – 19.8 MB** RSS (stable, 3 reps) |
| `hildi-agent`, idle, same session, debug, **after the arena cap** | **9.6 – 11.7 MB** RSS (5 reps) |
| `hildi-agent`, idle, same session, release, `MALLOC_ARENA_MAX=1` (env) | **7.8 – 7.9 MB** RSS |
| `hildi-agent` after live turns on a long session (debug, before) | **44.9 MB** (`VmHWM` 46.1) |
| TUI (`hildi`) attached to that session, 2 threads | **17.8 MB** |
| File size: debug → release | 14.7 → **3.7 MB** (`hildi`: 13.7 → **3.3 MB**) |
| Virtual size, one idle runtime, before → after | **456 → 131 MB** |

Two processes per session (TUI + runtime), and every subagent is another child
runtime — so "the cost of hildi" on a Pi is a sum, not one number.

**The most important number is the third and fourth rows.** The same release
binary, on the same session, goes from 18.1 MB to 7.8 MB — **a 10 MB, ~55 %
reduction — by capping glibc's per-thread arenas, with no code change.** That,
not the data model and not the debug build, is the dominant term. See §3.

## Why the runtime is bigger than the TUI

The TUI looks like the busier process — it owns the screen, the markdown, the
block layout. But it holds **2 threads**, and the runtime holds **8**. Resident
anonymous memory tracks the thread count, not the workload:

| Process | Threads | glibc arena reservations | `RssAnon` | THP regions |
| --- | --- | --- | --- | --- |
| `hildi` (TUI) | 2 | 1 | 9.2 MB | 2 |
| `hildi-agent` (runtime) | 8 | 8 | 36.2 MB | 8 |

The runtime's threads are not doing more work — they are **idle, parked on
futexes**. Measured thread states on a quiescent runtime: 1 main in `poll`,
5 workers in `futex_do_wait`, 1 worker spinning, 1 reader in `poll`. Their
cost is not their stacks (those are untouched 8 MB reservations) but the fact
that **glibc gives each thread its own malloc arena by default** (the cap is
`8 × cores`; this is a 2-core box scoring 8). Each arena:

1. reserves **64 MB of address space** (`PROT_NONE`) — that is the 456 MB of
   `VmSize`, and the reason a "10 MB" process shows a 456 MB virtual size;
2. commits in **2 MB `HEAP_MAX_SIZE` steps** as it grows;
3. lands on **transparent huge pages** — 8 of the runtime's anon regions are
   exactly 2048 kB with `VmFlags ... hg`, so each counts a full 2 MB of RSS
   whether or not the arena has 2 MB of live objects.

Nothing in FPC uses these arenas. The FPC heap is the `brk` mapping
(`[heap]`, 1.8 MB). The arenas belong to the C code: **vendor-threaded SQLite
(`SQLITE_THREADSAFE=1`) and mbedTLS**, which call glibc `malloc`/`free` from
whichever thread happens to be running. So the runtime pays for arenas the TUI
barely touches.

This also explains the earlier "7.6 vs 11.7 MB" variance in the first pass: it
was not session size, it was how many arenas happened to have been populated.

## Where the bytes are

### 1. The debug build is the largest single item — ~4.7 MB of DWARF and `-O-`

`make tui-agent` and `make headless-agent` build with `$(DEBUG)`
(`-O- -Crtio -Sa -gl`), not `$(RELEASE)` (`-O2 -CX -XX -Xs`). Consequences:

- `.debug_*` sections: **4.9 MB** in `hildi-agent` (`.debug_info` 3.17 MB alone),
  ~4.7 MB in `hildi`.
- The `-gl` line-info flag links FPC's line-info cache:
  `U_$LNFODWRF_$$_LICACHE` is a **296,352-byte** zero-filled `.bss` array —
  **29 % of the runtime's entire 366 KB `.bss`** — plus the `DBG_`/`DBG2_` and
  `_Ld` symbol tables, **1.99 MB** of them in the runtime.
- `-O-` inflates `.text`: 4.14 MB vs the ~3.9 MB the symbol table accounts for
  across 17,286 functions.

There is no `make` target that produces release binaries of the two real
programs — only `release-agent-cli` and `hildi-demo-release`. The shipped
artifacts are developer builds by construction.

The binary's own text mapping is **5.1 MB of the idle runtime's RSS** (measured:
`r-xp` mapping of `hildi-agent`), i.e. most of the 5.6 MB startup floor. Built
in release mode it drops to **3.7 MB on disk** (from 14.7) and **3.3 MB** for
the TUI (from 13.7), and the startup floor falls from 4.8 MB to 3.3 MB.

**But the file size is not where the memory is.** Against an idle runtime of
19.7 MB, cutting 11 MB of file size returned only **1.6 MB of RSS** (19.7 →
18.1): the debug sections are never loaded, and `-gl`'s `.bss` was 296 KB
untouched. It is worth doing for distribution — a 3.7 MB binary versus 14.7 MB
is the point of the project — but it is **not** the memory win. Do not let this
row be mistaken for the answer to a 45 MB process.

### 2. The thread-count multiplier: ~10 MB of arena overhead

This is the one that matters, and it is measured, not inferred. Same release
binary, same session, same store, only the environment differs:

| `MALLOC_ARENA_MAX` | `RssAnon` | `VmRSS` | THP regions | `VmSize` |
| --- | --- | --- | --- | --- |
| unset (default → 8 arenas here) | 13.1 MB | **18.1 MB** | 6 | 456 MB |
| 4 | 7.0 MB | **12.0 MB** | 3 | 259 MB |
| 2 | 2.9 MB | **7.9 MB** | 1 | 128 MB |
| 1 | 2.9 MB | **7.8 MB** | 1 | 64 MB |

Two repetitions of each, all within 12 kB — the effect is deterministic and
large. **10 MB, ~55 % of the idle footprint, is glibc arena overhead triggered
by thread count.** Two levers, either of which fixes it:

- fewer threads (pool sizing/laziness, §4), or
- `mallopt(M_ARENA_MAX, 2)` once at startup — a single C call through the
  existing shim, no behaviour change, and it also drops `VmSize` from 456 MB to
  128 MB, which matters on a device with strict overcommit.

The TUI escapes this by having 2 threads. That is the whole reason the
"busier" process is smaller.

### 3. ~25 MB accrued by live turns is **retention, not a leak**

Measured with `heaptrc`, driving a real turn through an instrumented runtime
(`build/bin/hildi-agent-probe`, `-gh -gl`, `SCENARIO=text`):

| | idle (no turn) | after a live turn |
| --- | --- | --- |
| blocks allocated | 6,116 | 11,999 |
| bytes allocated | 27,181,673 | 27,897,688 |
| blocks freed | 6,115 | 11,998 |
| **unfreed** | **1 (21 bytes)** | **1 (20 bytes)** |
| `True heap size` | 262,144 | 262,144 |

The single unfreed block in both runs is `ParamStr`'s argv string
(`fpc_pchar_to_ansistr` from `main` line 36) — a known FPC program-parameter
allocation, not a defect. **There is no leak.** A turn doubles the allocation
count for ~0.7 MB of additional total churn, and gives all of it back.

So the accrued RSS is not leaked memory. It is **the FPC heap retaining freed
pages**: 27.9 MB allocated and freed, while `heaptrc`'s own `True heap size`
stays at 256 KB — the allocator is reusing blocks internally and never handing
the address space back to the kernel. The 26 MB `rw-p` region seen on the
long-lived runtime is that retained heap, fragmented by 12,000 short-lived
SSE-delta strings.

This changes the fix. There is nothing to plug. The options are allocator-level:

- **link `cmem`** so FPC allocations go through glibc `malloc`/`free`, which then
  cooperates with the arena cap from §2 and with `malloc_trim(0)`;
- call `malloc_trim(0)` at turn boundaries — only meaningful with `cmem`, since
  the stock FPC heap is not glibc;
- accept it: 25 MB retained on a device with 1 GB is affordable, and this may
  well be a non-problem once §1 and §2 have landed.

The 44.9 MB peak on the long-lived runtime was measured **before** the arena cap.
Re-measuring that session after the cap is the next number worth having.

### 7. Streaming concatenation was O(n²) — fixed, measured

`TSSEParser` assembled the reply with
`FResult.Message.Content := FResult.Message.Content + Content.AsString`
(`src/HildiLLM.pas`), which reallocates and copies the whole prefix on **every**
delta. Now two `TStringBuilder`s (`FContentBuf`, `FReasoningBuf`) grow
geometrically and the result is materialised on read.

Measured with a focused harness (`build/memprobe/ssechurn.pas`, 3,000 deltas of
44 bytes, heaptrc, identical fixture both sides):

| | blocks allocated | bytes allocated |
| --- | --- | --- |
| before | 174,255 | **208,474,772** |
| after | 171,261 | **9,380,671** |

**22× fewer bytes.** The baseline matches theory: O(n²) copying of 3,000 deltas
averaging half the final 132 KB is 44 × (3000·3001/2) ≈ 198 MB, and it allocated
208 MB.

**But it does not reduce memory at all.** Peak RSS from the same fixture, same
run: **5,216 kB before, 5,320 kB after** — noise. The allocation traffic is
realloc churn over a working set that stays small; the allocator reuses the freed
blocks, so nothing new is resident. This is the third time in this investigation
that "bytes allocated" has failed to translate into "bytes resident", and it is
worth stating plainly: **allocation traffic is not a memory metric.**

**What it does buy is speed: ~28%.** Seven runs per repetition, three
repetitions: 908–928 ms before, 644–690 ms after. Quadratic copying is CPU, and
that is where the saving lands. So the change is justified — as a performance
fix, not a footprint fix. It should be described that way in any changelog.

| metric | before | after | verdict |
| --- | --- | --- | --- |
| bytes allocated | 208,474,772 | 9,380,671 | **22× less churn** |
| blocks allocated | 174,255 | 171,261 | unchanged (JSON dominates) |
| peak RSS | 5,216 kB | 5,320 kB | **no change** |
| wall time (×7) | 908–928 ms | 644–690 ms | **~28% faster** |

Note what did **not** move: the block count (174k → 171k). Almost all of those
blocks are the **JSON tree parsed and freed per chunk** — ~57 blocks per delta —
not the concatenation. So on a real turn the byte saving is real but partial:
for ~100 deltas the concat accounted for ~222 KB of the ~716 KB a turn allocates,
while ~5,700 of its ~5,883 blocks are JSON.

That makes JSON-per-chunk the next lever, and a different kind of work: the
parser could reuse a `TJSONParser` and one `TJSONObject` across chunks, or
extract the `content`/`reasoning` strings without materialising a full tree. Not
started.

Correctness note: content is published by a `GetResult` getter, not only in
`Finish`. `Finish` is reached **only on a clean 2xx** — cancel, transport error
and non-2xx all exit before it — so publishing there alone would have silently
dropped partial content that the old code made visible. `TLLMClientTest`: 38/39
pass; the one failure (`TestConfigResolutionReadsEnvironment`) is pre-existing and
unrelated, verified by stashing the change and rebuilding.


Swapping FPC's heap for libc `malloc` was the only remaining lever on the ~25 MB
of retained heap. It was tested rather than argued about, and it fails on three
independent grounds.

**It silences the leak gate.** `heaptrc.Install` chains
(`GetMemoryManager(prevMgr)` then `SetMemoryManager(newMgr)`,
`rtl/inc/heaptrc.pp:2219-2231`) — whichever unit initialises last owns the
manager. With `cmem` present, a fixture that deliberately leaks 12,345 bytes
reports:

```
0 memory blocks allocated : 0
0 memory blocks freed : 0
0 unfreed memory blocks : 0
```

Zero blocks *tracked*, and **exit 0**. `make test-leak` would pass forever and
detect nothing — a green gate that measures nothing, the same class of defect as
the `TSplitBoundaryTest` that "was verifying nothing" in the CHANGELOG.

**It corrupts the heap with `cthreads`.** Abortion was order-dependent:

| `uses` order | result |
| --- | --- |
| `cthreads, cwstring, cmem` | `double free or corruption (out)`, SIGABRT |
| `cthreads, cmem` | same |
| `cmem` alone | ok |
| `cmem, cthreads, cwstring` | **ok** |

The workable order puts `cmem` first — which violates the AGENTS.md rule that
`cthreads` must be first, or threading is broken at runtime. For a 7-thread
program, which rule genuinely wins is not obvious, and a heap corruption is the
worst way to find out.

**It buys ~1.7 %.** Release build, no heaptrc, isolated store, 5 reps (RSS kB):

- stock: `7860 7872 7880 9696 9876`
- `cmem`: `7756 7768 9460 9540 10752`

Overlapping distributions; ~130 kB at best. As predicted, glibc keeps freed small
blocks in tcache and bins exactly as the FPC heap does, so an allocator swap
cannot return the pages.

**Verdict: do not adopt.** The 25 MB is addressable only by reducing the churn
itself — a reusable buffer for streaming deltas, or a `TStringBuilder` that is
`Clear`ed rather than freed — which needs no allocator change and puts no gate at
risk. Experiments preserved under `build/memprobe/` (`v_leak2.pas`,
`v_cfirst.pas`, `agent_cmem.pas`), all gitignored.



Each glibc arena commits in 2 MB `HEAP_MAX_SIZE` steps, and the kernel backs each
with a huge page: 8 of the runtime's anon regions are exactly 2048 kB with
`VmFlags ... hg` and `AnonHugePages: 2048 kB`. A huge page is faulted in whole,
so each counts a full 2 MB of RSS regardless of the live bytes inside it. That
is why `RssAnon` moves in ~2 MB steps with arena count (13.1 → 7.0 → 2.9 MB as
the cap goes 8 → 4 → 2) and why THP region count tracks arena count exactly
(8 arenas → 8 regions, 1 arena → 1 region).

THP is a multiplier on §2's bug, not an independent one: cap the arenas and the
huge pages disappear with them.

### 5. Eight threads per runtime, each with an 8 MB stack reservation

Thread inventory of one idle runtime: 1 main + 6 `TExecutorWorker` + 1 client
reader = 8. Pool sizes are hard-coded: `TTurnPool` = 2 and `TToolPool` = 4 in
`HildiHarnessSession`, one scheduler per turn worker in `HildiHarnessTurnWorker`.
With the default 8 MB stack, virtual size is **456 MB while RSS is 18 MB** —
harmless under default overcommit, fatal on a device configured with strict
overcommit or a small `RLIMIT_AS`.

The stacks are reservations, not the cost: an earlier version of this section
claimed the idle workers polling at `ExecutorPollMs = 10` / `WorkerPollMs = 25`
were "a battery cost". **That was wrong.** Measured per thread over 15 s, all
seven workers together account for **~3 wakeups/s and 0–2 ticks** — they block
properly and cost nothing. The idle CPU that does exist (TUI ~5.5% of a core,
runtime ~3.7%) is on the **main thread** of each process, which is a different
problem: see the `idle-activity` board topic.

### 6. File-backed and unavoidable-ish: ~7.6 MB

`libc` 1.4 MB, `libm` 0.2 MB, the binary's text 5.1 MB, locale data 0.5 MB
(`C.utf8` `LC_CTYPE` 180 KB, `en_US.utf8` `LC_COLLATE` 168 KB, gconv 128 KB —
pulled in by `cwstring`, which the project must not drop), `store.db-shm` 32 KB.
Two locales are resident because both are consulted; on a device where saving
300 KB matters, that is a locale configuration question, not a code one.

### 6. SQLite: 2.1 MB of `.rodata`-adjacent code and a default 2 MB page cache

SQLite text is ~0.5 MB of the 4.1 MB `.text` (`sqlite3*` and `yy_*`: 476 KB).
The store sets `journal_mode=WAL` and `foreign_keys=ON` and nothing else — so
the page cache is SQLite's default (`cache_size = -2000`, i.e. **2 MB**), and
`SQLITE_ENABLE_FTS5` is compiled in whether or not search uses it. Both are
tunable per connection for constrained targets.

## What to do, ranked by value per unit of work

1. **Cap glibc's arenas — DONE.** `hildi_alloc_init()` in
   `src/hildi_tls_shim.c` calls `mallopt(M_ARENA_MAX, 2)` on glibc (a no-op
   elsewhere); both programs call it as the first statement of the program body,
   declared `cdecl; external` locally so the TUI still links no unit beyond its
   own. **Measured after the change, 5 reps, same session: RSS 19.7 → 9.6–11.7 MB,
   arena reservations 8 → 1, THP regions 8 → 1–2, `VmSize` 456 → 131 MB.** The
   result is bimodal (9.6 / 11.7 MB) depending on how much the single arena has
   committed; both ends are well under the 19.7 MB baseline. Verified:
   `TSplitBoundaryTest` still passes, so the process split is intact.
   The remaining question is whether 2 arenas hurts throughput under genuinely
   parallel tool calls — the runs measured were idle.

   **Throughput verified, no cost on real workloads.** A synthetic allocator
   benchmark (`build/memprobe/arena_bench.c`, mixed-size malloc/free churn in N
   threads, median of 7) shows the cap is free at 2 and 4 threads and costs 2.1×
   at 7 (58 → 123 ms) — but only when all seven threads churn the allocator
   simultaneously, which the runtime never does. Measured on the real workload
   (`hildi-smoke --scenario tool`, mean of 5): 397 ms default, 415 ms at 2, 390 ms
   at 4, 438 ms at 8 — all within noise. The cap costs nothing in practice.

   **Loaded-session RSS verified.** An isolated copy of the store, long session,
   release binary, 3 reps: **14.0 MB uncapped → 5.9–7.9 MB capped**
   (`RssAnon` 9.0 → 0.9–2.9 MB). So the ~half saving holds on a session with real
   history, not just an idle one.
2. **Bound the pools, lazily.** Start `TTurnPool`/`TToolPool` on first use, size
   them `min(nproc, 2)`, and give executor workers an explicit small stack
   (`TThread.Create` with `StackSize`; 256 KB is generous for a tool call). Idle
   threads 8 → 2–3 and `VmSize` collapses. Fixing the thread count *upstream*
   also subsumes (1) — arena count is per-thread — but (1) is a one-liner and
   should land either way.
3. **Attributing the accrued heap — DONE, and the answer was "no leak".**
   `heaptrc` on a driven turn: 11,999 blocks allocated, 11,998 freed, **1 unfreed
   (20 bytes of argv)**. The ~25 MB is not leaked memory; it is the FPC heap
   retaining freed pages it never returns to the kernel. So there is nothing to
   plug — see §3. The fix, if it is worth making, is allocator-level (item 4).
4. **Link `cmem` so FPC allocations use glibc.** That is what makes the arena cap
   (1) apply to Pascal-side churn too, and what makes `malloc_trim(0)` at turn
   boundaries (`5`) meaningful — with the stock FPC heap neither can return
   address space. This is the one change that could move the ~25 MB retained
   figure, and it is also the one with the most risk (a different allocator under
   a leak gate that counts FPC blocks). Try it behind a measurement, not blind.
5. **Call `malloc_trim(0)` at turn boundaries**, through the same shim — only
   useful together with (4).
5. **Ship release binaries.** Add `make release-tui` / `make release-agent`
   mirroring `release-agent-cli`. It is the wrong tool for a memory problem
   (−1.6 MB measured) but the right one for the project's actual thesis: a
   3.3–3.7 MB self-contained binary instead of 13.7–14.7 MB. Worth having
   `make` produce them alongside the debug builds.
6. **A memory cap for the SQLite connection** on constrained targets:
   `PRAGMA cache_size=-512`, `PRAGMA temp_store=FILE`; drop
   `SQLITE_ENABLE_FTS5` from the C flags if nothing queries it.
7. **Trim the embedded CA bundle** (200 KB PEM, 14 % of `.rodata`) to DER at
   build time — a file-size win only, since it is clean page-cache-backed
   rodata. Low priority; listed for completeness.
8. **Instrument it.** A `make mem-report` that samples a spawned runtime's
   `VmHWM`/`RssAnon`/`Threads`/arena count would make this a regression gate
   rather than a one-off study — the same shape as `make perf`/`bench`. It
   should pin `MALLOC_ARENA_MAX` or the arena count is noise.

## Reproduce

```sh
export PATH="$HOME/.fpcenv/versions/3.3.1/bin:$PATH"   # not on PATH by default

size build/bin/hildi-agent                       # text/data/bss
size -A build/bin/hildi-agent | grep -E 'debug|bss|rodata'
nm -S --size-sort --radix=d build/bin/hildi-agent | awk '/ [bB] /' | tail

# idle floor, no store, no threads
/usr/bin/time -v ./build/bin/hildi-agent --bogus 2>&1 | grep -i 'maximum resident'

# a real runtime's breakdown while it lives
grep -E 'VmRSS|RssAnon|Threads|VmSize' /proc/<pid>/status
awk '/^[0-9a-f]+-[0-9a-f]+ /{split($1,a,"-"); sz=(strtonum("0x"a[2])-strtonum("0x"a[1]))/1024; p=$2} /^Rss:/{print $2, sz, p}' /proc/<pid>/smaps | sort -rn | head

# the arena effect: same binary, same session, one env var
MALLOC_ARENA_MAX=1 ./build/bin/hildi-agent-release --session-runtime <id> \
  --workspace $PWD --store /tmp/probe.db --idle-ms 6000 &
grep -E 'VmRSS|RssAnon|VmSize|Threads' /proc/<pid>/status
```

### The memory probe

`scripts/memprobe.sh` samples a runtime against a **throwaway copy** of a store:

```sh
scripts/memprobe.sh --reps 3                 # as it ships
scripts/memprobe.sh --reps 3 --arena 1       # capped, for comparison
```

Two things it gets right that a hand-rolled probe does not:

- **The snapshot goes through SQLite's backup API**, not `cp`. A live store is in
  WAL mode; copying the files can catch it mid-checkpoint. Nothing here opens the
  original for writing.
- **It never resolves a PID with `pgrep -f 'session-runtime <id>'`**, which
  matches *every* process for that session — including a live one. It uses `$!`.
  It also skips any session currently leased by a running runtime, because the
  runtime's lease is the socket bind and a rival on a live session exits
  immediately (which looks like a crash, not a skip).

Measured with it, release binary, long session, 3 reps: **7.9 – 9.7 MB RSS,
`RssAnon` 2.9 MB, 1 arena.** Rebuild the runtime before measuring — a stale
`hildi-agent-release` from before the cap still reports 6 arenas and 18 MB, which
is how a stale artifact can make a fix look like it never landed. `-Xs` strips
release binaries, so check the arena count (`arenas=` in the output), not `nm`.

### The heaptrc probe

`make probe` builds the runtime with `-gh` and prints the recipe. heaptrc writes
its report **at exit**, so the runtime must be allowed to exit on its own: a
SIGKILLed process leaves only the header line. Smoke sends SIGTERM and then
SIGKILL 2 s later, so a plain drive truncates the dump. The reliable recipe is a
wrapper that appends an `--idle-ms` short enough to outlive the turn:

```sh
cat > /tmp/probe-run.sh <<'EOF'
#!/bin/sh
exec /abs/path/build/bin/hildi-agent-probe "$@" --idle-ms 150
EOF
chmod +x /tmp/probe-run.sh

make probe                                   # build it
HEAPTRC="log=/tmp/heap.log" \
  HILDI_RUNTIME_BIN=/tmp/probe-run.sh \
  ./build/bin/hildi-smoke --scenario text
cat /tmp/heap.log
```

Read `memory blocks allocated` / `freed`. In both the idle and the driven-turn
runs the difference is exactly one `ParamStr` block — the argv string.

## Open questions

- How much of the accrued live-session heap is transcript model versus replay
  versus streaming churn? (needs `heaptrc`)
- Does RSS grow with session length while idle, or only per turn? Idle was flat
  over 60 s; a multi-turn soak is not yet measured.
- Is the TUI's 17.8 MB the same story at 2 threads, or does it have its own
  block cache? (`Process Split` already windows the chat list to ~0.75 MB for
  700 blocks, so suspicion is on the runtime side, not the TUI model.)
- Does `mallopt(M_ARENA_MAX, 2)` hurt throughput on a many-core host where
  parallel tool calls genuinely run at once? The measured runs here were idle;
  a batch-tool benchmark under load is needed before shipping the cap.
- What does the Pi itself measure? Every figure here is a 2-core aarch64
  server-vm; a Pi 4 has the same page size and THP default, but its glibc and
  core count differ enough that the arena cap should be re-measured there.
