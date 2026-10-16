#!/usr/bin/env bash
# Write the engine's generated version include (build.pas normally generates it).
# Kept as a script so the Makefile recipe does not fight shell quoting.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
out="deps/goccia/source/units/Goccia.Version.Generated.inc"
if [ ! -d deps/goccia/source/units ]; then
  echo "gen-goccia-version: goccia is not fetched" >&2
  exit 1
fi
cat > "$out" <<'EOF'
// Generated for the harness build — do not edit.
const
  BAKED_VERSION = '0.0.0';
  BAKED_COMMIT = 'vendored';
  BAKED_BUILD_DATE = '2026-10-16';
EOF
echo "gen-goccia-version: wrote $out"

# The umbrella program: compiling it precompiles the full closure the harness
# facade needs (the engine + both executors), into the cached unit dir.
umb="build/goccia-gen/engine_closure.pas"
mkdir -p build/goccia-gen
cat > "$umb" <<'EOF'
program engine_closure;
{ Compiling this precompiles the GocciaScript closure the harness facade uses. }
{$mode delphi}
uses
  Goccia.Engine, Goccia.Executor, Goccia.Executor.Interpreter;
begin
end.
EOF
echo "gen-goccia-version: wrote $umb"
