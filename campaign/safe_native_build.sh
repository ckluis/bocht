#!/bin/bash
# Safe authoritative native build for the campaign.
#   1. Runs preflight (bend + clang + disk); aborts if it fails.
#   2. Builds to <out>.new with FULL unpiped output to <prefix>_full.log.
#   3. Replaces <out> ONLY on exit 0. A failed build can NEVER delete
#      the working binary (this exact failure orphaned med_native_r3 on 2026-09-20).
#   4. Writes <prefix>_meta.txt with true exit code, duration, hashes.
# Usage: safe_native_build.sh <src.bend> <out-binary> [log-prefix]
#        (run from the directory that should hold the binary and logs)
set -u
SRC="$1"; OUT="$2"; PREFIX="${3:-build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/preflight.sh" || { echo "SAFE_BUILD ABORT: preflight failed"; exit 2; }
export BEND_NO_TELEMETRY=1
export PATH="$HOME/.bend/bin:$PATH"
rm -f "${OUT}.new"
start=$(date +%s%N)
bend "$SRC" -o "${OUT}.new" > "${PREFIX}_full.log" 2>&1
exit_code=$?
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
if [ $exit_code -eq 0 ] && [ -f "${OUT}.new" ]; then
  mv -f "${OUT}.new" "$OUT"
  note="BINARY_REPLACED"
else
  rm -f "${OUT}.new"
  note="BINARY_UNCHANGED (build failed; previous binary kept if any)"
fi
{
  echo "CMD: bend $SRC -o $OUT"
  echo "EXIT_CODE: $exit_code"
  echo "DURATION_MS: $duration_ms"
  echo "BUILD_NOTE: $note"
  echo "SOURCE_SHA256: $(sha256sum "$SRC" | cut -d' ' -f1)"
  if [ -f "$OUT" ]; then
    echo "BINARY_SHA256: $(sha256sum "$OUT" | cut -d' ' -f1)"
    echo "BINARY_SIZE: $(stat -c %s "$OUT")"
    echo "BINARY_FILE: $(file "$OUT" | cut -c1-120)"
  else
    echo "BINARY: MISSING (no previous binary and build failed)"
  fi
  echo "FINISHED_UTC: $(date -u +%FT%TZ)"
} > "${PREFIX}_meta.txt"
echo "SAFE_BUILD_DONE rc=$exit_code note=$note"
exit "$exit_code"
