#!/usr/bin/env bash
# memprobe.sh - sample a session runtime's memory against a THROWAWAY copy of a
# store.
#
# Why a copy at all: a live store is in WAL mode and a plain `cp` can catch it
# mid-checkpoint, producing a torn database. SQLite's backup API takes a
# consistent snapshot of a database that another process is actively using,
# which is what this uses. Nothing here ever opens the original for writing,
# and the runtime is pointed at the copy -- so a probe can never contest the
# socket lease of, or lose writes from, a live session.
#
# It also never resolves a PID with `pgrep -f`. That pattern matches EVERY
# process for a session id, including the operator's own runtime, which is
# exactly the mistake this script exists to prevent: it uses $! only.
#
# Usage:
#   scripts/memprobe.sh [--store PATH] [--binary BIN] [--reps N] [--arena N]
#
# Defaults: --store  ${HILDI_STORE_PATH:-$XDG_DATA_HOME/hildi/store.db}
#           --binary build/bin/hildi-agent (fall back to -release if present)
#           --reps   3
#           --arena  unset (measure the binary as it ships). 1 or 2 measures a
#                    capped run for comparison.
#
# Reports VmRSS / RssAnon / VmSize / Threads and the glibc arena reservation
# count (the 64 MB PROT_NONE blocks) per repetition.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

STORE="${HILDI_STORE_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/hildi/store.db}"
BINARY=""
REPS=3
ARENA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --store)  STORE="$2";  shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --reps)   REPS="$2";   shift 2 ;;
    --arena)  ARENA="$2";  shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "memprobe: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$STORE" ]; then
  echo "memprobe: no store at $STORE" >&2
  exit 1
fi

if [ -z "$BINARY" ]; then
  if [ -x build/bin/hildi-agent-release ]; then
    BINARY=build/bin/hildi-agent-release
  elif [ -x build/bin/hildi-agent ]; then
    BINARY=build/bin/hildi-agent
  else
    echo "memprobe: no runtime built; run 'make headless-agent'" >&2
    exit 1
  fi
fi
if [ ! -x "$BINARY" ]; then
  echo "memprobe: not executable: $BINARY" >&2
  exit 1
fi

WORK=$(mktemp -d -t hildi-memprobe-XXXXXX)
# The workspace is a scratch dir too: a probe should not write into the repo
# (or wherever the operator's real workspace is) as a side effect of measuring.
mkdir -p "$WORK/ws"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Consistent snapshot of a possibly-live WAL database. Read-only, and the
# source is never locked for the duration.
python3 - "$STORE" "$WORK/store.db" <<'PY'
import sqlite3, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
dst = sqlite3.connect(dst_path)
with dst:
    src.backup(dst)
dst.close(); src.close()
PY

# A session id that exists in the COPY and is not currently leased by a running
# runtime. The runtime's lease is the socket bind, so a rival on a live session
# correctly exits immediately -- which looks like a crash rather than a skipped
# run. Picking a non-live session avoids that collision entirely.
SESSION=$(python3 - "$WORK/store.db" <<'PY'
import sqlite3, subprocess, sys

# Sessions currently held by a running runtime (do not touch the operator's).
live = set()
try:
    out = subprocess.run(["pgrep", "-af", "hildi-agent"],
                         capture_output=True, text=True, timeout=5).stdout
    for line in out.splitlines():
        parts = line.split()
        if "--session-runtime" in parts:
            i = parts.index("--session-runtime")
            if i + 1 < len(parts):
                live.add(parts[i + 1])
except Exception:
    pass

c = sqlite3.connect(sys.argv[1])
rows = [r[0] for r in c.execute("select id from sessions order by rowid desc")]
c.close()

for s in rows:
    if s not in live:
        print(s)
        break
else:
    print("")   # every session in the copy is live
PY
)
if [ -z "$SESSION" ]; then
  echo "memprobe: every session in the store is currently live; stop one first," >&2
  echo "          or point --store at a store with a non-live session." >&2
  exit 1
fi

echo "memprobe: store=$STORE (copied)  binary=$BINARY  session=$SESSION  reps=$REPS  arena=${ARENA:-unset}"

PIDS=""
for i in $(seq 1 "$REPS"); do
  if [ -n "$ARENA" ]; then
    MALLOC_ARENA_MAX="$ARENA" "$BINARY" --session-runtime "$SESSION" \
      --workspace "$WORK/ws" --store "$WORK/store.db" --idle-ms 4000 \
      >/dev/null 2>&1 &
  else
    "$BINARY" --session-runtime "$SESSION" --workspace "$WORK/ws" \
      --store "$WORK/store.db" --idle-ms 4000 >/dev/null 2>&1 &
  fi
  PID=$!
  PIDS="$PIDS $PID"
  sleep 2.2
  if [ ! -r "/proc/$PID/status" ]; then
    echo "rep$i: runtime exited early (no /proc/$PID)"
    continue
  fi
  ARENAS=$(awk '
    /^[0-9a-f]+-[0-9a-f]+ /{ split($1,a,"-"); sz=(strtonum("0x"a[2])-strtonum("0x"a[1]))/1024; perm=$2; nm=$6 }
    /^Rss:/{ if (nm=="" && perm=="---p" && sz>60000) c++ }
    END { print c+0 }' "/proc/$PID/smaps")
  awk -v i="$i" -v ar="$ARENAS" '
    /VmRSS:/{r=$2} /RssAnon:/{a=$2} /VmSize:/{v=$2} /Threads:/{t=$2}
    END { printf "rep%d  rss=%-7s anon=%-7s vsz=%-8s threads=%s arenas=%s\n", i, r, a, v, t, ar }' \
    "/proc/$PID/status"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
done

# Belt and braces: nothing this script started may outlive it.
for p in $PIDS; do kill "$p" 2>/dev/null || true; done
