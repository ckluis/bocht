#!/bin/bash
# Pinned-binary backup canary (Fresh Round 3, item 181).
#
# Verifies the item-180 hardening is intact:
#   (a) the pinned backup exists at ~/workspace/backups/bocht-pinned/
#   (b) the backup's SHA-256 matches its .sha256 sidecar
#   (c) the sidecar SHA matches the LIVE pinned binary's SHA
#   (d) the live binary's SHA matches the ledger-pinned SHA
#
# The pinned binary name + expected SHA are parsed from the ledger's
# "Binary SHA-256:" line (authoritative), not hardcoded.
#
# Exit 0 on PASS, 1 on ANY failure. Output is loud by design — the hourly
# job surfaces a FAIL as a red flag, never buried.
#
# Usage: check_pinned_backup.sh
#   Optional env overrides (for the item-181 corruption simulation only):
#     CANARY_BACKUPDIR, CANARY_TESTDIR, CANARY_LEDGER

set -u

LEDGER="${CANARY_LEDGER:-$HOME/workspace/bocht/.test_runs/hardening_status.md}"
TESTDIR="${CANARY_TESTDIR:-$HOME/workspace/bocht/.test_runs/fresh-r1}"
BACKUPDIR="${CANARY_BACKUPDIR:-$HOME/workspace/backups/bocht-pinned}"

# --- Parse pinned binary from ledger -------------------------------------
LINE="$(grep -m1 '^- Binary SHA-256:' "$LEDGER" 2>/dev/null)" || LINE=""
if [ -z "$LINE" ]; then
  echo "CANARY FAIL: no 'Binary SHA-256' line found in ledger ($LEDGER)"
  echo "RESULT: PASS=0 FAIL=1"
  exit 1
fi
SHA="$(echo "$LINE" | grep -oE '[0-9a-f]{64}' | head -1)"
RTAG="$(echo "$LINE" | grep -oE '\(r[0-9]+, promoted' | grep -oE 'r[0-9]+' | head -1)"
if [ -z "$SHA" ] || [ -z "$RTAG" ]; then
  echo "CANARY FAIL: could not parse pinned binary name/SHA from ledger line:"
  echo "  $LINE"
  echo "RESULT: PASS=0 FAIL=1"
  exit 1
fi
BIN="med_native_$RTAG"

LIVE="$TESTDIR/$BIN"
BACKUP="$BACKUPDIR/$BIN"
SIDECAR="$BACKUPDIR/$BIN.sha256"

# --- Existence checks ------------------------------------------------------
FAIL=0
[ -f "$BACKUP" ]  || { echo "CANARY FAIL: backup missing: $BACKUP"; FAIL=1; }
[ -f "$SIDECAR" ] || { echo "CANARY FAIL: sidecar missing: $SIDECAR"; FAIL=1; }
[ -f "$LIVE" ]    || { echo "CANARY FAIL: live pinned binary missing: $LIVE"; FAIL=1; }

# --- SHA agreement checks --------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  BACKUP_SHA="$(sha256sum "$BACKUP" | cut -d' ' -f1)"
  SIDECAR_SHA="$(tr -d ' \t\n\r' < "$SIDECAR")"
  LIVE_SHA="$(sha256sum "$LIVE" | cut -d' ' -f1)"

  [ "$BACKUP_SHA" = "$SIDECAR_SHA" ] \
    || { echo "CANARY FAIL: backup SHA != sidecar SHA"; echo "  backup:  $BACKUP_SHA"; echo "  sidecar: $SIDECAR_SHA"; FAIL=1; }
  [ "$SIDECAR_SHA" = "$LIVE_SHA" ] \
    || { echo "CANARY FAIL: sidecar SHA != live binary SHA"; echo "  sidecar: $SIDECAR_SHA"; echo "  live:    $LIVE_SHA"; FAIL=1; }
  [ "$LIVE_SHA" = "$SHA" ] \
    || { echo "CANARY FAIL: live binary SHA != ledger-pinned SHA"; echo "  live:   $LIVE_SHA"; echo "  ledger: $SHA"; FAIL=1; }
fi

# --- Verdict ----------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  echo "CANARY PASS: pinned $BIN intact — backup==sidecar==live==ledger ($SHA)"
  echo "RESULT: PASS=1 FAIL=0"
  exit 0
else
  echo "CANARY RESULT: FAIL — pinned-binary protection is BROKEN, investigate immediately"
  echo "RESULT: PASS=0 FAIL=1"
  exit 1
fi
