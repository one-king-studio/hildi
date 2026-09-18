#!/usr/bin/env bash
# Fetch the pinned SQLite amalgamation into deps/sqlite3/.
#
# The project vendors a known-good SQLite rather than depending on whatever
# libsqlite3 the host provides. The source is downloaded (not committed) to keep
# the repository light; this script pins the version and verifies the published
# SHA3-256 before extracting.
#
# Usage: scripts/fetch-sqlite.sh
#
# Idempotent: exits early when the expected files are already present.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

SQLITE_VERSION="3530400"          # 3.53.4
SQLITE_YEAR="2026"
SQLITE_SHA3="628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e"

DEST="deps/sqlite3"
ZIP="sqlite-amalgamation-${SQLITE_VERSION}.zip"
URL="https://www.sqlite.org/${SQLITE_YEAR}/${ZIP}"
FILES=(sqlite3.c sqlite3.h sqlite3ext.h)

present=1
for f in "${FILES[@]}"; do
  [ -f "$DEST/$f" ] || present=0
done
if [ "$present" -eq 1 ]; then
  echo "sqlite: ${FILES[*]} already present in $DEST"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "sqlite: openssl is required to verify the download" >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "sqlite: unzip is required to extract the amalgamation" >&2
  exit 1
fi

mkdir -p "$DEST"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sqlite-fetch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "sqlite: downloading $URL"
curl -fsSL -o "$tmp/$ZIP" "$URL"

actual="$(openssl dgst -sha3-256 "$tmp/$ZIP" | awk '{print $NF}')"
if [ "$actual" != "$SQLITE_SHA3" ]; then
  echo "sqlite: checksum mismatch" >&2
  echo "  expected $SQLITE_SHA3" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "sqlite: checksum ok ($SQLITE_SHA3)"

unzip -q -j -o -d "$DEST" "$tmp/$ZIP" "${FILES[@]}"
echo "sqlite: extracted ${FILES[*]} into $DEST"
