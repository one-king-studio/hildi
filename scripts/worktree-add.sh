#!/usr/bin/env bash
# Create a buildable git worktree.
#
# A bare `git worktree add` produces a checkout with no deps/ and no build/, so it
# cannot compile: deps/sqlite3/sqlite3.c, deps/mbedtls/ and deps/cacert/ are all
# gitignored, and the integration suites additionally need
# build/bin/hildegard-helper-agent built. Without it ~36 tests fail for a reason
# unrelated to the code under test - which is why a pristine worktree reports
# spurious failures.
#
# Usage:
#   scripts/worktree-add.sh <path> [branch]
#   scripts/worktree-add.sh .worktrees/foo -b newbranch
#
# What it does, and deliberately does NOT do:
#   - creates the worktree (git worktree add, arguments passed through)
#   - shares deps/ by symlink from the primary worktree (read-only, identical)
#   - creates an EMPTY build/  (never shared - compiler output is per-source)
#   - reports what still needs building
#
# It does NOT run make: fetching mbedTLS and compiling SQLite takes minutes and
# needs the network. Preparing and reporting is the job; deciding to build is not.

set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[ $# -lt 1 ] && usage 1
case "$1" in -h|--help) usage 0 ;; esac

WT_PATH="$1"
shift

# The primary worktree is the one holding the common git dir's parent. Deriving it
# this way means the script works when run FROM a worktree, not just from main.
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
PRIMARY="$(cd "$COMMON_DIR/.." && pwd)"

if [ ! -d "$PRIMARY/deps" ]; then
  echo "error: $PRIMARY/deps does not exist." >&2
  echo "       Build the primary tree first (make deps), then re-run." >&2
  exit 1
fi

# --- create the worktree -------------------------------------------------
# Pass the remaining arguments straight to git so -b / --detach / a commit-ish all
# behave exactly as they do for plain `git worktree add`.
echo "creating worktree at $WT_PATH"
git worktree add "$WT_PATH" "$@"

# Resolve to an absolute path for the symlinks below.
WT_ABS="$(cd "$WT_PATH" && pwd)"

# --- share the fetched libraries ----------------------------------------
# NOT the deps/ directory itself: deps/.gitkeep and deps/sqlite3/README.md are
# TRACKED, so a fresh worktree already has a real deps/ and symlinking it would
# be refused. What is missing is the gitignored payload, so link those entries
# individually. Read-only by convention and identical across worktrees, so a
# symlink is both correct and free.
shared=0
for entry in deps/sqlite3/sqlite3.c deps/sqlite3/sqlite3.h \
             deps/sqlite3/sqlite3ext.h deps/mbedtls deps/cacert; do
  src="$PRIMARY/$entry"
  dst="$WT_ABS/$entry"
  [ -e "$src" ] || continue
  # The tracked entry (e.g. deps/sqlite3) exists; its gitignored children do not.
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    continue                      # already a real file; leave it
  fi
  ln -sfn "$src" "$dst"
  shared=$((shared + 1))
done
if [ "$shared" -gt 0 ]; then
  echo "linked $shared deps entr(ies) -> $PRIMARY/deps"
else
  echo "note: no deps payload found in $PRIMARY/deps; run 'make deps' there first"
fi

# --- its own build/ ------------------------------------------------------
# NEVER shared. Compiler output is keyed to the source it was built from, and two
# worktrees on different branches writing one build/units would overwrite each
# other's .ppu files - producing a binary that does not match its source.
mkdir -p "$WT_ABS/build"
echo "created an empty build/ (not shared: output is per-source)"

# --- report --------------------------------------------------------------
cat <<EOF

Ready to build. Next:

  cd $WT_PATH
  make deps          # only if you have not built them before; shared, so fast
  make check

Two things worth knowing:

  This worktree has its OWN database (.hildegard/), so its board, task list and
  sessions are separate from the primary tree. That is deliberate - worktrees are
  tested independently - but it means an empty board here is NOT "no coordination
  happening", it is a different workspace.

  The integration suites need build/bin/hildegard-helper-agent. Without it about
  36 tests fail for a reason unrelated to the code under test. 'make check' builds
  it as part of the gate; a bare '\$(BIN)/hildegard-helper-tests' run does not.
EOF
