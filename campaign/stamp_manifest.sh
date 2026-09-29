#!/bin/bash
# Bind a regression run's result files to the exact binary they tested.
# A "N/N PASS" claim is only verifiable if the results are tied to a binary
# hash that exists on disk. Run this right after the regression loop, from
# the test directory, passing the binary FIRST then every result file that
# was part of the run.
# Usage: stamp_manifest.sh <binary> <result-file>...
# Writes manifest_<UTC-ts>.txt with binary sha + per-file PASS/FAIL + totals.
set -u
BIN="$1"; shift
TS=$(date -u +%Y%m%dT%H%M%SZ)
MAN="manifest_${TS}.txt"
[ -f "$BIN" ] || { echo "MANIFEST ABORT: binary $BIN not found"; exit 1; }
{
  echo "BINARY: $BIN"
  echo "BINARY_SHA256: $(sha256sum "$BIN" | cut -d' ' -f1)"
  echo "RUN_UTC: $TS"
  total_p=0; total_f=0
  for r in "$@"; do
    if [ ! -f "$r" ]; then echo "FILE: $r MISSING"; continue; fi
    line=$(grep -h "RESULT: PASS=" "$r" 2>/dev/null | tail -1)
    p=$(echo "$line" | grep -oE "PASS=[0-9]+" | grep -oE "[0-9]+")
    f=$(echo "$line" | grep -oE "FAIL=[0-9]+" | grep -oE "[0-9]+")
    p=${p:-0}; f=${f:-0}
    if [ -z "$line" ]; then echo "FILE: $r NO_RESULT_LINE (PASS/FAIL unreadable)"; fi
    echo "FILE: $r PASS=$p FAIL=$f"
    total_p=$((total_p+p)); total_f=$((total_f+f))
  done
  echo "TOTAL_PASS: $total_p"
  echo "TOTAL_FAIL: $total_f"
} > "$MAN"
echo "MANIFEST: $MAN TOTAL_PASS=$total_p TOTAL_FAIL=$total_f"
