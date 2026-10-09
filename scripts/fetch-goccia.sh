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

GOCCIA_SHA="531fb523efe10375858ac29faf3da5dd15195418"
GOCCIA_SHA256="c0a97fe9282df598e94b1e7c8b2bf32dc4bd353bfb3138f3ddaf49e38f64aef5"

DEST="deps/goccia"
TARBALL="GocciaScript-${GOCCIA_SHA}.tar.gz"
URL="https://github.com/frostney/GocciaScript/archive/${GOCCIA_SHA}.tar.gz"

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
