#!/bin/bash
# MMForge Preflight Geometry Gating — Real Gate Contract Tests
#
# Detects runtime OCCT availability via the CLI's JSON output, then
# asserts the correct exit code from format-geometry-gate.sh:
#   WITH OCCT     → exit 0 (PASS — all five fixtures real-geometry)
#   NO OCCT + advisory=1 → exit 3 (ADVISORY)
#   NO OCCT + advisory=0 → exit 1 (FAIL)
#
# Never hardcodes "no OCCT" — adapts to the actual build environment.
#
# Environment honoured by the gate:
#   MMFORGE_NO_OCCT_ADVISORY
#   MMFORGE_CLI
#   CARGO_TARGET_DIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$ROOT/docs/scripts/format-geometry-gate.sh"
PASS=0
FAIL=0

green() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
red()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info()  { printf '  \033[36mINFO\033[0m %s\n' "$*"; }

echo "=== Preflight Geometry Gating — Real Gate Contract Tests ==="
echo "Gate script: $GATE_SCRIPT"
echo ""

# ---------------------------------------------------------------------------
# 1. Detect runtime OCCT availability via the CLI
# ---------------------------------------------------------------------------
echo "--- Detect OCCT availability ---"
CLI="${MMFORGE_CLI:-$ROOT/target/release/mmforge}"

# Build CLI if needed
if [ ! -x "$CLI" ]; then
  info "CLI not found at $CLI — building..."
  cargo build --release -p mmforge-cli --manifest-path "$ROOT/Cargo.toml" || {
    red "CLI build failed"
    exit 1
  }
  CLI="$ROOT/target/release/mmforge"
fi

# Detect OCCT by querying the CLI on a known fixture
RUNTIME_OCCT=0
STL_FIXTURE="$ROOT/testdata/stl/box.stl"
if [ -f "$STL_FIXTURE" ]; then
  OCCT_RAW=$(set +e; "$CLI" info "$STL_FIXTURE" --format json 2>/dev/null | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('occt_available') else 0)" 2>/dev/null)
  if [ "$OCCT_RAW" = "1" ]; then
    RUNTIME_OCCT=1
  fi
fi

if [ "$RUNTIME_OCCT" -eq 1 ]; then
  info "OCCT IS available — expecting exit 0 (all five fixtures PASS)"
else
  info "OCCT NOT available — STEP/IGES will be advisory/error"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Test advisory mode (MMFORGE_NO_OCCT_ADVISORY=1)
# ---------------------------------------------------------------------------
echo "--- Test 1: Advisory mode ---"
set +e
TABLE_ADV=$(MMFORGE_NO_OCCT_ADVISORY=1 bash "$GATE_SCRIPT" 2>/dev/null)
RC_ADV=$?
set -e

if [ "$RUNTIME_OCCT" -eq 1 ]; then
  # With OCCT: expect exit 0
  if [ "$RC_ADV" -eq 0 ]; then
    green "advisory mode exit 0 (PASS — OCCT present)"
  else
    red "advisory mode exit $RC_ADV (expected 0 with OCCT)"
  fi
else
  # Without OCCT: expect exit 3
  if [ "$RC_ADV" -eq 3 ]; then
    green "advisory mode exit 3 (ADVISORY — no OCCT)"
  else
    red "advisory mode exit $RC_ADV (expected 3 without OCCT)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Test non-advisory mode
# ---------------------------------------------------------------------------
echo "--- Test 2: Non-advisory mode ---"
set +e
TABLE=$(bash "$GATE_SCRIPT" 2>/dev/null)
RC=$?
set -e

if [ "$RUNTIME_OCCT" -eq 1 ]; then
  if [ "$RC" -eq 0 ]; then
    green "non-advisory mode exit 0 (PASS — OCCT present)"
  else
    red "non-advisory mode exit $RC (expected 0 with OCCT)"
  fi
else
  if [ "$RC" -eq 1 ]; then
    green "non-advisory mode exit 1 (FAIL — STEP/IGES ERROR, no OCCT)"
  else
    red "non-advisory mode exit $RC (expected 1 without OCCT)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Table format validation
# ---------------------------------------------------------------------------
echo "--- Test 3: Table format ---"
TABLE="${TABLE_ADV:-$TABLE}"
if echo "$TABLE" | grep -q "| FORMAT |"; then
  green "table has FORMAT header"
else
  red "table missing FORMAT header"
fi

for fmt in STL glTF DXF STEP IGES; do
  if echo "$TABLE" | grep -q "| $fmt "; then
    green "  table contains $fmt"
  else
    red "  table MISSING $fmt"
  fi
done

# STL + glTF must always be REAL-GEOMETRY
if echo "$TABLE" | grep "STL" | grep -q "REAL-GEOMETRY"; then
  green "  STL = REAL-GEOMETRY"
else
  red "  STL is not REAL-GEOMETRY"
fi
if echo "$TABLE" | grep "glTF" | grep -q "REAL-GEOMETRY"; then
  green "  glTF = REAL-GEOMETRY"
else
  red "  glTF is not REAL-GEOMETRY"
fi
if echo "$TABLE" | grep "DXF" | grep -q "2D-ONLY"; then
  green "  DXF = 2D-ONLY"
else
  red "  DXF is not 2D-ONLY"
fi

# With OCCT, STEP + IGES should be REAL-GEOMETRY
if [ "$RUNTIME_OCCT" -eq 1 ]; then
  if echo "$TABLE" | grep "STEP" | grep -q "REAL-GEOMETRY"; then
    green "  STEP = REAL-GEOMETRY (OCCT present)"
  else
    red "  STEP is not REAL-GEOMETRY (OCCT present but parse failed)"
  fi
  if echo "$TABLE" | grep "IGES" | grep -q "REAL-GEOMETRY"; then
    green "  IGES = REAL-GEOMETRY (OCCT present)"
  else
    red "  IGES is not REAL-GEOMETRY (OCCT present but parse failed)"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Runtime OCCT: $([ "$RUNTIME_OCCT" -eq 1 ] && echo YES || echo NO)"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
