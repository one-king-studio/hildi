#!/bin/sh
# Collect commits in range, one line each: <short-hash><TAB><prefix><TAB><subject>
#
# Exists so the skill demonstrates a bundled script. A skill that ships files
# lists them in its activation payload but never has their CONTENTS inlined -
# the model runs them with its own tools, which is why relative paths resolve
# against the skill's directory.
set -eu

FROM="${1:-}"
TO="${2:-HEAD}"

if [ -z "$FROM" ]; then
  echo "usage: collect.sh <from> [to]" >&2
  exit 2
fi

git log --no-merges --format='%h%x09%s' "$FROM..$TO" |
  awk -F'\t' '
    {
      subject = $2
      prefix = ""
      if (match(subject, /^[a-z]+(\([^)]*\))?: /)) {
        prefix = substr(subject, 1, RLENGTH - 2)
        subject = substr(subject, RLENGTH + 1)
      }
      printf "%s\t%s\t%s\n", $1, prefix, subject
    }
  '
