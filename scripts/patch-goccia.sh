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

# 2. The engine does not compile clean under -Sew (warnings-as-errors): its own
#    code has benign warnings (unreachable code in HashMap, "Constructor should
#    be public", UnicodeString->AnsiString conversions in TextSemantics). The
#    harness builds with -Sew for OUR units, but the engine must be allowed its
#    warnings. Silence them for the engine by injecting {$WARNINGS OFF} into the
#    include every engine unit pulls in (Goccia.inc -> Shared.inc), right after
#    the mode switch. This lets the engine compile with the SAME flags the
#    consumer uses, so no separate cache dir and no flag juggling is needed.
shared="$GOCCIA/source/shared/Shared.inc"
if grep -q '{\$WARNINGS OFF}' "$shared"; then
  echo "patch-goccia: warnings-off already present"
else
  sed -i '' 's#^\(  {\$mode delphiunicode} {\$H+}\)$#\1\n  {$WARNINGS OFF}#' "$shared" 2>/dev/null \
    || sed -i 's#^\(  {\$mode delphiunicode} {\$H+}\)$#\1\n  {$WARNINGS OFF}#' "$shared"
  echo "patch-goccia: injected warnings-off into Shared.inc"
fi

# 3. The engine vendors a unit literally named `JSONParser`, which collides with
#    the FCL's `jsonparser` — the unit ~10 harness units use via `fpjson`. On a
#    case-insensitive filesystem (macOS) the two cannot coexist, and the
#    engine's unit shadows the FCL one, so every harness `TJSONData`/`GetJSON`
#    call breaks (silently: the file tools fail, the store fails). Rename the
#    engine's unit to `Goccia.JSONParser` and rewrite its `uses` references. A
#    genuine vendored-tree fix, like the constref patch.
jp_dir="$GOCCIA/source/shared"
if [ -f "$jp_dir/JSONParser.pas" ]; then
  mv "$jp_dir/JSONParser.pas" "$jp_dir/Goccia.JSONParser.pas"
  sed -i '' 's/^unit JSONParser;/unit Goccia.JSONParser;/' \
    "$jp_dir/Goccia.JSONParser.pas" 2>/dev/null \
    || sed -i 's/^unit JSONParser;/unit Goccia.JSONParser;/' \
      "$jp_dir/Goccia.JSONParser.pas"
  while IFS= read -r f; do
    sed -i '' -E 's/^([[:space:]]*)JSONParser([[:space:]]*[,;])/\1Goccia.JSONParser\2/' "$f" 2>/dev/null \
      || sed -i -E 's/^([[:space:]]*)JSONParser([[:space:]]*[,;])/\1Goccia.JSONParser\2/' "$f"
  done < <(grep -rlE '^[[:space:]]*JSONParser[[:space:]]*[,;]' "$GOCCIA/source" --include=*.pas 2>/dev/null || true)
  echo "patch-goccia: renamed JSONParser -> Goccia.JSONParser (FCL collision)"
else
  echo "patch-goccia: JSONParser already renamed"
fi

echo "patch-goccia: done"
