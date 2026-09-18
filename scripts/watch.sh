#!/usr/bin/env bash
# Portable TDD watch loop: re-run a make target whenever sources change.
# No external dependencies (works without fswatch/entr).
#
#   scripts/watch.sh [make-target]     # default target: test
#
# Stop with Ctrl-C.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

TARGET="${1:-test}"
STAMP="$(mktemp "${TMPDIR:-/tmp}/hildegard-helper-watch.XXXXXX")"
WATCH_PATHS=(src tests examples Makefile .gitignore)

cleanup() { rm -f "$STAMP"; }
on_signal() { exit 130; }   # let the EXIT trap do the cleanup, then quit
trap cleanup EXIT
trap on_signal INT TERM

touch "$STAMP"
printf 'hildegard-helper watch: \033[1mmake %s\033[0m on changes under %s\n' "$TARGET" "${WATCH_PATHS[*]}"
printf 'Press Ctrl-C to stop.\n\n'

# Initial run so you start from a known state.
make "$TARGET"

while true; do
  if find "${WATCH_PATHS[@]}" -type f -newer "$STAMP" -print -quit 2>/dev/null | grep -q .; then
    touch "$STAMP"
    printf '\n\033[1m--- %s: change detected, running: make %s ---\033[0m\n' \
      "$(date '+%H:%M:%S')" "$TARGET"
    make "$TARGET"
  fi
  sleep 1
done
