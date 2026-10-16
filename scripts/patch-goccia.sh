#!/usr/bin/env bash
# Apply the harness's compatibility patches to the vendored GocciaScript tree.
#
# These fix engine code that does not compile against FPC 3.3.1 (they are engine
# bugs against this toolchain, not changes to our code). Kept separate from
# fetch-goccia.sh so the fetch stays a clean upstream pin and every patch is
# visible here. Idempotent: re-running is a no-op.
#
# Usage: scripts/patch-goccia.sh

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

GOCCIA="deps/goccia"
if [ ! -d "$GOCCIA/source/units" ]; then
  echo "patch-goccia: $GOCCIA is not fetched; run scripts/fetch-goccia.sh first" >&2
  exit 1
fi

# 1. Comparison callbacks are declared `{$IFDEF FPC}constref{$ELSE}const{$ENDIF}`,
#    but this FPC's TComparison<T> wants plain `const`; `constref` fails with
#    "Incompatible type ... expected TCOMPARISON<System.Int64>". Seven sites.
patched=0
while IFS= read -r f; do
  before="$(grep -c 'IFDEF FPC}constref' "$f" || true)"
  sed -i '' 's/{\$IFDEF FPC}constref{\$ELSE}const{\$ENDIF}/const/g' "$f" 2>/dev/null \
    || sed -i 's/{\$IFDEF FPC}constref{\$ELSE}const{\$ENDIF}/const/g' "$f"
  after="$(grep -c 'IFDEF FPC}constref' "$f" || true)"
  if [ "$before" != "$after" ]; then
    patched=$((patched + before))
  fi
done < <(grep -rl 'IFDEF FPC}constref' "$GOCCIA/source" 2>/dev/null || true)

echo "patch-goccia: constref -> const ($patched sites)"
echo "patch-goccia: done"
