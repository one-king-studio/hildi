#!/usr/bin/env bash
# Fetch the pinned GocciaScript source into deps/goccia/.
#
# The project vendors a known-good GocciaScript (an MIT, FPC-native ECMAScript
# engine) rather than depending on a moving upstream. The source is downloaded
# (not committed) to keep the repository light; this script pins the commit and
# verifies the archive's SHA-256 before extracting.
#
# Usage: scripts/fetch-goccia.sh
#
# Idempotent: exits early when the expected source is already present.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

GOCCIA_SHA="312ddd1988954189b96b058af148d572e380080d"
GOCCIA_SHA256="272ec3342f89887f4d2ddffc57251751b67abce20cf6188894cb3fd86fbfddca"

DEST="deps/goccia"
TARBALL="GocciaScript-${GOCCIA_SHA}.tar.gz"
# The fork, not upstream: our FPC-compatibility fixes live on its `hildegard`
# branch as three commits (see docs/research/goccia-embedding-findings.md).
# Keeping the fixes in the fork rather than in patch-goccia.sh means the sed
# script can go away and `deps/goccia` is exactly a fork commit.
URL="https://github.com/johnrcui/GocciaScript/archive/${GOCCIA_SHA}.tar.gz"

if [ -d "$DEST/source/units" ]; then
  echo "goccia: source already present in $DEST"
  exit 0
fi

if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  echo "goccia: shasum or sha256sum is required to verify the download" >&2
  exit 1
fi

mkdir -p "$DEST"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/goccia-fetch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "goccia: downloading $URL"
curl -fsSL -o "$tmp/$TARBALL" "$URL"

got="$(sha256 "$tmp/$TARBALL")"
if [ "$got" != "$GOCCIA_SHA256" ]; then
  echo "goccia: checksum mismatch" >&2
  echo "  expected $GOCCIA_SHA256" >&2
  echo "  got      $got" >&2
  exit 1
fi

echo "goccia: extracting into $DEST"
tar -xzf "$tmp/$TARBALL" -C "$tmp"
# The archive has one top-level directory; copy its contents into DEST.
cp -R "$tmp/GocciaScript-${GOCCIA_SHA}/." "$DEST"/
echo "goccia: done ($DEST)"
