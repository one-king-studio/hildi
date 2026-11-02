#!/usr/bin/env bash
# Sync this checkout with origin/main: fast-forward when possible, rebase when not.
#
# Written because the sync loop is now routine, and doing it by hand has two
# failure modes that have both bitten us:
#
#   1. `git merge --ff-only` silently cannot apply once local is ahead, so the
#      approach has to be chosen BEFORE acting, not after it fails.
#   2. `git diff HEAD origin/main` on a branch with unpushed commits shows your
#      OWN work in reverse -- additions read as deletions -- so "upstream
#      reverted this" is a false conclusion it invites. This script never uses
#      that form, and only reports what upstream commits actually changed.
#
# Usage:
#   scripts/sync.sh              sync; stop before running the gate
#   scripts/sync.sh --check      sync, then run `make check`
#   scripts/sync.sh -h|--help
#
# What it does:
#   - refuses to run on a dirty tree (a rebase with uncommitted work loses it)
#   - fetches, and reports ahead/behind
#   - nothing behind        -> says so and stops
#   - nothing ahead         -> fast-forward
#   - both ahead and behind -> backs up local commits to a bundle, then rebases
#   - reports which files both sides touched, and which upstream commits landed
#
# What it deliberately does NOT do:
#   - push, or force anything
#   - commit, or touch the working tree beyond the rebase
#   - assume the rebase worked: a clean textual rebase proves nothing about
#     whether it compiles, which is why --check exists and why the reminder is
#     printed when it is not used

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

BACKUP=.git/sync-backup.bundle
RUN_CHECK=0

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage 0 ;;
    --check)   RUN_CHECK=1 ;;
    *) echo "sync: unknown argument: $arg" >&2; usage 2 ;;
  esac
done

# A rebase replays commits; uncommitted work is not part of that and would be
# left behind or clobbered. Refuse rather than stash silently -- a stash the
# caller did not ask for is easy to forget and hard to notice.
if [ -n "$(git status --porcelain)" ]; then
  echo "sync: working tree is dirty - commit or stash first:" >&2
  git status --short >&2
  exit 1
fi

echo "sync: fetching origin"
git fetch origin --quiet

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "sync: on '$BRANCH', not 'main' - refusing to rebase a feature branch" >&2
  echo "       (rebase it onto main yourself, or check it out first)" >&2
  exit 1
fi

# --left-right --count prints "<ahead>\t<behind>".
COUNTS=$(git rev-list --left-right --count HEAD...origin/main)
AHEAD=$(printf '%s' "$COUNTS" | cut -f1)
BEHIND=$(printf '%s' "$COUNTS" | cut -f2)

echo "sync: $AHEAD ahead, $BEHIND behind origin/main"

if [ "$BEHIND" -eq 0 ]; then
  echo "sync: already up to date"
  exit 0
fi

if [ "$AHEAD" -eq 0 ]; then
  echo "sync: fast-forwarding"
  git merge --ff-only origin/main
else
  # Both sides moved, so a fast-forward is impossible. Report the conflict
  # surface first: it is the difference between a rebase that lands cleanly and
  # one that needs attention, and knowing it beforehand is the point.
  OVERLAP=$(comm -12 \
    <(git diff --name-only origin/main...HEAD | sort) \
    <(git diff --name-only HEAD...origin/main | sort))

  if [ -n "$OVERLAP" ]; then
    echo "sync: files touched on both sides (possible conflicts):"
    printf '%s
' "$OVERLAP" | sed 's/^/        /'
  else
    echo "sync: no files touched on both sides"
  fi

  # What is actually landing. Capped, because a long gap is mostly noise and the
  # point is orientation, not a changelog.
  echo "sync: upstream commits landing:"
  git log --oneline HEAD..origin/main | head -10 | sed 's/^/        /'
  MORE=$(( $(git rev-list --count HEAD..origin/main) - 10 ))
  if [ "$MORE" -gt 0 ]; then
    echo "        ... and $MORE more"
  fi

  # Back up every local commit before rewriting history. A bundle is a real
  # rollback: `git fetch .git/sync-backup.bundle main`.
  git bundle create "$BACKUP" origin/main..HEAD >/dev/null 2>&1
  echo "sync: local commits backed up to $BACKUP"

  if ! git rebase origin/main; then
    echo >&2
    echo "sync: REBASE CONFLICT - resolve, then 'git rebase --continue'" >&2
    echo "      or abort with 'git rebase --abort'" >&2
    echo "      rollback: git fetch $BACKUP main" >&2
    exit 1
  fi
fi

NEW_AHEAD=$(git rev-list --left-right --count HEAD...origin/main | cut -f1)
echo "sync: now $NEW_AHEAD ahead, 0 behind - tree $(git status --porcelain | wc -l | tr -d ' ') modified"

# A clean rebase proves the patches applied, not that they compile. Say so
# loudly rather than letting a green-looking 'sync: done' imply verification.
if [ "$RUN_CHECK" -eq 1 ]; then
  echo "sync: running make check"
  make check
else
  echo "sync: run 'make check' before trusting this tree"
fi
