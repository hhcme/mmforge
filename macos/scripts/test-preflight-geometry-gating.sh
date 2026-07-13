#!/bin/bash
# MMForge Preflight Geometry Gating — Real Gate Contract Tests
#
# Exercises the REAL format-geometry-gate.sh with both advisory and
# non-advisory modes.  Verifies the exit code contract (0/1/2/3)
# and the summary table format.
#
# Environment variables honoured by the gate:
#   MMFORGE_NO_OCCT_ADVISORY=1   downgrade STEP/IGES to advisory
#   MMFORGE_CLI                  override path to mmforge binary
#   CARGO_TARGET_DIR             override cargo target directory
#
# These injections are preserved for CI reproducibility but do NOT
# weaken the real gate — the gate still runs against real fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$ROOT/docs/scripts/format-geometry-gate.sh"
PASS=0
FAIL=0

green() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
red()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "=== Preflight Geometry Gating — Real Gate Contract Tests ==="
echo "Gate script: $GATE_SCRIPT"
echo ""

# ---------------------------------------------------------------------------
# Test 1: Advisory mode — STEP/IGES no-OCCT → exit 3
# ---------------------------------------------------------------------------
echo "--- Test 1: Advisory mode → exit 3 ---"
set +e
MMFORGE_NO_OCCT_ADVISORY=1 bash "$GATE_SCRIPT" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  green "advisory mode exit 3 (ADVISORY)"
else
  red "advisory mode exit $rc (expected 3)"
fi

# ---------------------------------------------------------------------------
# Test 2: Non-advisory mode — STEP/IGES no-OCCT → exit 1
# ---------------------------------------------------------------------------
echo "--- Test 2: Non-advisory mode → exit 1 ---"
set +e
bash "$GATE_SCRIPT" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  green "non-advisory mode exit 1 (FAIL — STEP/IGES ERROR)"
else
  red "non-advisory mode exit $rc (expected 1)"
fi

# ---------------------------------------------------------------------------
# Test 3: Table format — advisory mode produces valid table
# ---------------------------------------------------------------------------
echo "--- Test 3: Table format validation ---"
TABLE=$(MMFORGE_NO_OCCT_ADVISORY=1 bash "$GATE_SCRIPT" 2>/dev/null || true)
# Must have header row.
if echo "$TABLE" | grep -q "| FORMAT |"; then
  green "table has FORMAT header"
else
  red "table missing FORMAT header"
fi
# Must have all five formats.
for fmt in STL glTF DXF STEP IGES; do
  if echo "$TABLE" | grep -q "| $fmt "; then
    green "  table contains $fmt"
  else
    red "  table MISSING $fmt"
  fi
done
# STL must be REAL-GEOMETRY.
if echo "$TABLE" | grep "STL" | grep -q "REAL-GEOMETRY"; then
  green "  STL = REAL-GEOMETRY"
else
  red "  STL status is not REAL-GEOMETRY"
fi
# glTF must be REAL-GEOMETRY.
if echo "$TABLE" | grep "glTF" | grep -q "REAL-GEOMETRY"; then
  green "  glTF = REAL-GEOMETRY"
else
  red "  glTF status is not REAL-GEOMETRY"
fi
# DXF must be 2D-ONLY.
if echo "$TABLE" | grep "DXF" | grep -q "2D-ONLY"; then
  green "  DXF = 2D-ONLY"
else
  red "  DXF status is not 2D-ONLY"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
