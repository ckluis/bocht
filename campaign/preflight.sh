#!/bin/bash
# Campaign pre-flight: fail fast if the toolchain is broken.
# Checks: bend on PATH, clang present (auto-installs if running as root),
# workspace disk space. Reports :18081/:18080 listener state (informational).
# Usage: preflight.sh   (exit 0 = go, exit 1 = stop)
set -u
FAIL=0
export BEND_NO_TELEMETRY=1
export PATH="$HOME/.bend/bin:$PATH"

if ! command -v bend >/dev/null 2>&1; then
  echo "PREFLIGHT FAIL: bend not on PATH ($HOME/.bend/bin)"; FAIL=1
else
  echo "PREFLIGHT OK: bend $(bend --version 2>/dev/null | head -1)"
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "PREFLIGHT WARN: clang missing; attempting apt-get install"
  if [ "$(id -u)" = "0" ]; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq clang >/dev/null 2>&1
  else
    echo "PREFLIGHT WARN: not root, cannot auto-install clang"
  fi
  if ! command -v clang >/dev/null 2>&1; then
    echo "PREFLIGHT FAIL: clang still missing after install attempt"; FAIL=1
  else
    echo "PREFLIGHT OK: clang installed ($(clang --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
  fi
else
  echo "PREFLIGHT OK: clang $(clang --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi

avail=$(df -m "$HOME/workspace" 2>/dev/null | awk 'NR==2{print $4}')
echo "PREFLIGHT INFO: workspace disk available ${avail:-?}MB"
if [ -n "$avail" ] && [ "$avail" -lt 500 ]; then echo "PREFLIGHT FAIL: <500MB disk free"; FAIL=1; fi

echo "PREFLIGHT INFO: :18081 listeners: $(ss -tlnp 2>/dev/null | grep -c ':18081')"
echo "PREFLIGHT INFO: :18080 listeners: $(ss -tlnp 2>/dev/null | grep -c ':18080')"

if [ $FAIL -ne 0 ]; then echo "PREFLIGHT: FAILED"; exit 1; fi
echo "PREFLIGHT: PASSED"
