#!/usr/bin/env bash
# Fetch the pinned mbedTLS source into deps/mbedtls/.
#
# The project vendors a known-good mbedTLS rather than depending on a host
# OpenSSL, so the release binary links TLS statically (the SQLite pattern). The
# source is downloaded (not committed) to keep the repository light; this script
# pins the version and verifies the published SHA-256 before extracting.
#
# Usage: scripts/fetch-mbedtls.sh
#
# Idempotent: exits early when the expected files are already present.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

MBEDTLS_VERSION="3.6.7"           # 3.6 LTS
MBEDTLS_SHA256="a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"

DEST="deps/mbedtls"
TARBALL="mbedtls-${MBEDTLS_VERSION}.tar.bz2"
URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/${TARBALL}"
# Marker files that must exist for the extraction to be considered complete.
FILES=(include/mbedtls/ssl.h library/ssl_tls.c)

present=1
for f in "${FILES[@]}"; do
  [ -f "$DEST/$f" ] || present=0
done
if [ "$present" -eq 1 ]; then
  echo "mbedtls: source already present in $DEST"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "mbedtls: openssl is required to verify the download" >&2
  exit 1
fi

mkdir -p "$DEST"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mbedtls-fetch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "mbedtls: downloading $URL"
curl -fsSL -o "$tmp/$TARBALL" "$URL"

actual="$(openssl dgst -sha256 "$tmp/$TARBALL" | awk '{print $NF}')"
if [ "$actual" != "$MBEDTLS_SHA256" ]; then
  echo "mbedtls: checksum mismatch" >&2
  echo "  expected $MBEDTLS_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "mbedtls: checksum ok ($MBEDTLS_SHA256)"

tar -xjf "$tmp/$TARBALL" -C "$DEST" --strip-components=1
echo "mbedtls: extracted into $DEST"
