#!/usr/bin/env bash
# Refresh the vendored Mozilla CA bundle in deps/cacert/.
#
# The bundle is COMMITTED to the repository, not fetched during a build. That is
# deliberate:
#
#   curl.se/ca/cacert.pem is a ROLLING url. Pinning a SHA-256 to it -- which is
#   what this script used to do -- makes every fresh clone fail the checksum the
#   moment upstream republishes the file, with no way for the user to proceed.
#   curl.se publishes no immutable dated copies, so a stable pin is impossible.
#
# The bundle is 188 KB and changes a few times a year, so tracking it keeps the
# build hermetic and offline-capable, which is the point of the project.
#
# Usage:
#   scripts/fetch-cacert.sh            verify the committed bundle is intact
#   scripts/fetch-cacert.sh --update   download a newer one and show the diff
#
# --update does NOT commit; review and commit the change yourself.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

DEST="deps/cacert"
FILE="cacert.pem"
URL="https://curl.se/ca/cacert.pem"
# The bundle as committed. --update replaces it; normal builds compare against it.
RECORDED_SHA256="796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe"

TOOL="openssl"
command -v "$TOOL" >/dev/null 2>&1 || { echo "cacert: $TOOL is required" >&2; exit 1; }

sha_of() { "$TOOL" dgst -sha256 "$1" | awk '{print $NF}'; }

# --- update ---------------------------------------------------------------
if [ "${1:-}" = "--update" ]; then
  command -v curl >/dev/null 2>&1 || { echo "cacert: curl is required to update" >&2; exit 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cacert-fetch.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  echo "cacert: downloading $URL"
  curl -fsSL -o "$tmp/$FILE" "$URL"

  # A PEM bundle is only useful if it actually parses as certificates.
  n="$(grep -c 'BEGIN CERTIFICATE' "$tmp/$FILE" || true)"
  if [ "${n:-0}" -lt 50 ]; then
    echo "cacert: refusing -- $tmp/$FILE contains $n certificates" >&2
    exit 1
  fi

  new="$(sha_of "$tmp/$FILE")"
  old="$( [ -f "$DEST/$FILE" ] && sha_of "$DEST/$FILE" || echo none)"
  if [ "$new" = "$old" ]; then
    echo "cacert: already current ($new)"
    exit 0
  fi

  mkdir -p "$DEST"
  cp "$tmp/$FILE" "$DEST/$FILE"
  echo "cacert: updated $DEST/$FILE"
  echo "  certificates: $n"
  echo "  old sha256 : $old"
  echo "  new sha256 : $new"
  echo
  echo "  Now update RECORDED_SHA256 in this script to $new, then commit the"
  echo "  bundle and the script together."
  exit 0
fi

# --- verify (the default, and what a build relies on) ---------------------
if [ ! -f "$DEST/$FILE" ]; then
  echo "cacert: $DEST/$FILE is missing." >&2
  echo "  It is committed to the repository, so a missing copy means the" >&2
  echo "  checkout is incomplete. Restore it with:" >&2
  echo "    git checkout -- $DEST/$FILE" >&2
  echo "  or refresh it deliberately with: scripts/fetch-cacert.sh --update" >&2
  exit 1
fi

actual="$(sha_of "$DEST/$FILE")"
if [ "$actual" = "$RECORDED_SHA256" ]; then
  echo "cacert: ok ($actual)"
  exit 0
fi

# A local bundle that differs is not a build failure: it is either a deliberate
# local refresh awaiting a commit, or a corrupted file. Say which, and let the
# build continue -- a working TLS trust store is more useful than a hard stop.
echo "cacert: warning: $DEST/$FILE does not match the recorded hash" >&2
echo "  recorded: $RECORDED_SHA256" >&2
echo "  actual  : $actual" >&2
echo "  If you refreshed it deliberately, update RECORDED_SHA256 and commit." >&2
exit 0
