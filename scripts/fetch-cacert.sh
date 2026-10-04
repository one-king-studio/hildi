#!/usr/bin/env bash
# Fetch the pinned Mozilla CA bundle into deps/cacert/.
#
# The harness embeds a known CA bundle in the binary so a clean device needs no
# system trust store. curl.se republishes Mozilla's roots periodically; this
# script pins the exact bundle by SHA-256, so updating it is a deliberate pin
# change (like SQLite).
#
# Usage: scripts/fetch-cacert.sh
#
# Idempotent: exits early when the file is already present.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

CACERT_SHA256="a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505"

DEST="deps/cacert"
FILE="cacert.pem"
URL="https://curl.se/ca/cacert.pem"

if [ -f "$DEST/$FILE" ]; then
  echo "cacert: $DEST/$FILE already present"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "cacert: openssl is required to verify the download" >&2
  exit 1
fi

mkdir -p "$DEST"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cacert-fetch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "cacert: downloading $URL"
curl -fsSL -o "$tmp/$FILE" "$URL"

actual="$(openssl dgst -sha256 "$tmp/$FILE" | awk '{print $NF}')"
if [ "$actual" != "$CACERT_SHA256" ]; then
  echo "cacert: checksum mismatch" >&2
  echo "  expected $CACERT_SHA256" >&2
  echo "  actual   $actual" >&2
  echo "  (the bundle was republished; update CACERT_SHA256 deliberately)" >&2
  exit 1
fi
echo "cacert: checksum ok ($CACERT_SHA256)"

cp "$tmp/$FILE" "$DEST/$FILE"
echo "cacert: installed $DEST/$FILE"
