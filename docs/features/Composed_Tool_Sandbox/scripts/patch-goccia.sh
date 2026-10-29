#!/usr/bin/env bash
# The harness's vendored-engine patches now live in the FORK, not here.
#
# `scripts/fetch-goccia.sh` fetches a pinned commit from
# https://github.com/johnrcui/GocciaScript (branch `hildi`), whose three
# commits carry the FPC-compatibility fixes that used to be sed'd in here:
#
#   92775fda  fix(fpc):   constref -> const for FPC 3.3.1's TComparison<T>
#   88b0cb5c  build:      silence the engine's own warnings under -Sew
#   312ddd19  fix(units): rename JSONParser to Goccia.JSONParser
#
# Keeping them as commits means the vendored tree is exactly a fork revision,
# the fixes are reviewable diffs, and a re-fetch cannot lose them. This script
# stays only to (a) assert the fetched tree really carries them, so a bad pin
# fails loudly, and (b) leave the `libgoccia` recipe unchanged.
#
# Usage: scripts/patch-goccia.sh

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

GOCCIA="deps/goccia"
if [ ! -d "$GOCCIA/source/units" ]; then
  echo "patch-goccia: $GOCCIA is not fetched; run scripts/fetch-goccia.sh first" >&2
  exit 1
fi

fail=0

# 1. constref -> const (no `{$IFDEF FPC}constref` may remain).
if grep -rq 'IFDEF FPC}constref' "$GOCCIA/source" 2>/dev/null; then
  echo "patch-goccia: FAIL: constref sites remain (fork patch 92775fda missing?)" >&2
  fail=1
fi

# 2. Warnings silenced for a -Sew host.
if ! grep -q '{\$WARNINGS OFF}' "$GOCCIA/source/shared/Shared.inc"; then
  echo "patch-goccia: FAIL: Shared.inc lacks {\$WARNINGS OFF} (fork patch 88b0cb5c missing?)" >&2
  fail=1
fi

# 3. JSONParser renamed so it cannot shadow the FCL's unit.
if [ -f "$GOCCIA/source/shared/JSONParser.pas" ]; then
  echo "patch-goccia: FAIL: JSONParser.pas not renamed (fork patch 312ddd19 missing?)" >&2
  fail=1
fi

if [ "$fail" != "0" ]; then
  exit 1
fi

echo "patch-goccia: vendored tree carries the fork's fixes"
