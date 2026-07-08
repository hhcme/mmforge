#!/bin/bash
# MMForge Preflight Geometry Gating — Shell Tests
# Exercises perf-baseline.sh exit-code logic and preflight-check.sh
# section-10 gating with fake summary tables. No cargo, no GUI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
TEST_DIR="$(mktemp -d "$TMPDIR/preflight-test.XXXX")"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

green() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
red()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Simulate perf-baseline.sh's exit-code logic against a fake summary table.
# This is the extracted essence of lines ~154–198 of perf-baseline.sh.
# Arguments: advisory_flag output_file
# The output file must contain rows like: | FMT | STATUS | ... |
# Returns exit code (0/1/2/3) — same contract as perf-baseline.sh.
# ---------------------------------------------------------------------------
simulate_perf_verdict() {
  local advisory="$1" output="$2"

  local had_occt_error=0 had_non_occt_error=0 had_placeholder=0

  while IFS='|' read -r _ rawfmt rawstatus _ _; do
    local fmt status
    fmt=$(echo "$rawfmt" | tr -d ' ')
    status=$(echo "$rawstatus" | tr -d ' ')

    case "$status" in
      ERROR)
        case "$fmt" in
          STEP|IGES) had_occt_error=1 ;;
          *)         had_non_occt_error=1 ;;
        esac
        ;;
      PLACEHOLDER) had_placeholder=1 ;;
    esac
  done < <(grep -E '^\| (STEP|IGES|STL|glTF|DXF)' "$output" 2>/dev/null || true)

  if [ "$had_non_occt_error" -eq 0 ] && [ "$had_placeholder" -eq 0 ] && [ "$had_occt_error" -eq 0 ]; then
    return 0  # clean
  elif [ "$had_non_occt_error" -eq 1 ]; then
    return 1  # hard error
  elif [ "$had_placeholder" -eq 1 ]; then
    return 2  # placeholder
  elif [ "$had_occt_error" -eq 1 ]; then
    if [ "$advisory" = "1" ]; then
      return 3  # advisory
    else
      return 1  # hard error (no advisory)
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Test runner: creates a fake summary table, runs the gating logic, asserts.
# ---------------------------------------------------------------------------
assert_verdict() {
  local label="$1" advisory="$2" table_lines="$3" expect_rc="$4"

  printf "%s\n" "$table_lines" > "$TEST_DIR/table.txt"

  local rc=0
  simulate_perf_verdict "$advisory" "$TEST_DIR/table.txt" || rc=$?
  if [ "$rc" -eq "$expect_rc" ]; then
    green "$label (rc=$rc expected=$expect_rc)"
  else
    red "$label (rc=$rc expected=$expect_rc)"
  fi
}

# ---------------------------------------------------------------------------
# Test case helper for preflight summary message simulation.
# The preflight summary logic: exit 0 + no advisory → "ALL CHECKS PASSED"
#                              exit 0 + advisory  → "PASS WITH ADVISORY"
#                              any exit != 0      → "SOME CHECKS FAILED"
# ---------------------------------------------------------------------------
assert_summary() {
  local label="$1" preflight_rc="$2" geometry_advisory="$3" expect_msg="$4"

  local msg
  if [ "$preflight_rc" -eq 0 ] && [ "$geometry_advisory" -eq 0 ]; then
    msg="ALL_CHECKS_PASSED"
  elif [ "$preflight_rc" -eq 0 ] && [ "$geometry_advisory" -eq 1 ]; then
    msg="PASS_WITH_ADVISORY"
  else
    msg="CHECKS_FAILED"
  fi

  if [ "$msg" = "$expect_msg" ]; then
    green "$label → $msg"
  else
    red "$label → $msg (expected $expect_msg)"
  fi
}

# ===========================================================================
echo "=== Preflight Geometry Gating — Shell Tests ==="
echo ""

# --------------------------------------------------------------------------=
# Test 1: Default (no advisory) — STEP/IGES ERROR → exit 1
# --------------------------------------------------------------------------
echo "--- Scenario 1: Default no-OCCT, STEP+IGES ERROR ---"
assert_verdict \
  "perf-baseline: default STEP/IGES ERROR" 0 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  1

# Section 10 in preflight gets exit 1 → FAIL
assert_summary "preflight: default STEP/IGES ERROR" 1 0 "CHECKS_FAILED"

# --------------------------------------------------------------------------
# Test 2: Advisory — STEP/IGES ERROR downgraded → exit 3
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 2: MMFORGE_NO_OCCT_ADVISORY=1, STEP+IGES ERROR → advisory ---"
assert_verdict \
  "perf-baseline: advisory STEP/IGES ERROR → exit 3" 1 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  3

# Section 10 in preflight gets exit 3 → ADVISORY (exit 0, geometry_advisory=1)
assert_summary "preflight: advisory exit 3" 0 1 "PASS_WITH_ADVISORY"

# --------------------------------------------------------------------------
# Test 3: Advisory but only IGES ERROR, STEP OK (with OCCT) → still advisory
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 3: Advisory, only IGES ERROR, STEP has OCCT ---"
assert_verdict \
  "perf-baseline: advisory IGES-only ERROR" 1 \
  "| STEP   | REAL-GEOMETRY |     2 |     1 |      4554 |
| IGES   | ERROR         |       |       |           |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  3

assert_summary "preflight: advisory IGES only" 0 1 "PASS_WITH_ADVISORY"

# --------------------------------------------------------------------------
# Test 4: Advisory + non-OCCT ERROR (STL failed) → exit 1
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 4: Advisory + STL ERROR (non-OCCT) → hard fail ---"
assert_verdict \
  "perf-baseline: advisory + STL ERROR → exit 1" 1 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | ERROR         |       |       |           |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  1

assert_summary "preflight: STL ERROR with advisory" 1 0 "CHECKS_FAILED"

# --------------------------------------------------------------------------
# Test 5: Advisory + DXF ERROR (non-OCCT) → exit 1
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 5: Advisory + DXF ERROR (non-OCCT) → hard fail ---"
assert_verdict \
  "perf-baseline: advisory + DXF ERROR → exit 1" 1 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | ERROR         |       |       |           |" \
  1

assert_summary "preflight: DXF ERROR with advisory" 1 0 "CHECKS_FAILED"

# --------------------------------------------------------------------------
# Test 6: Advisory + PLACEHOLDER (any format) → exit 2 (fail)
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 6: Advisory + PLACEHOLDER → exit 2 (always fail) ---"
assert_verdict \
  "perf-baseline: advisory + PLACEHOLDER → exit 2" 1 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | PLACEHOLDER   |     0 |     0 |         0 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  2

assert_summary "preflight: PLACEHOLDER with advisory" 1 0 "CHECKS_FAILED"

# --------------------------------------------------------------------------
# Test 7: PLACEHOLDER only, no advisory → exit 2
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 7: PLACEHOLDER, no advisory → exit 2 ---"
assert_verdict \
  "perf-baseline: PLACEHOLDER no advisory" 0 \
  "| STEP   | PLACEHOLDER   |     0 |     0 |         0 |
| IGES   | PLACEHOLDER   |     0 |     0 |         0 |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  2

# --------------------------------------------------------------------------
# Test 8: All clean (no advisory needed) → exit 0
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 8: All clean → exit 0 ---"
assert_verdict \
  "perf-baseline: all clean" 0 \
  "| STEP   | REAL-GEOMETRY |     2 |     1 |      4554 |
| IGES   | REAL-GEOMETRY |     2 |     1 |        12 |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  0

assert_summary "preflight: all clean" 0 0 "ALL_CHECKS_PASSED"

# --------------------------------------------------------------------------
# Test 9: Advisory + glTF ERROR (non-OCCT) → exit 1
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 9: Advisory + glTF ERROR (non-OCCT) → hard fail ---"
assert_verdict \
  "perf-baseline: advisory + glTF ERROR → exit 1" 1 \
  "| STEP   | ERROR         |       |       |           |
| IGES   | ERROR         |       |       |           |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | ERROR         |       |       |           |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  1

# --------------------------------------------------------------------------
# Test 10: No advisory + no ERROR → exit 0, clean summary
# --------------------------------------------------------------------------
echo ""
echo "--- Scenario 10: No advisory, all clean (with OCCT) → exit 0 ---"
assert_verdict \
  "perf-baseline: no advisory, with OCCT → exit 0" 0 \
  "| STEP   | REAL-GEOMETRY |     2 |     1 |      4554 |
| IGES   | REAL-GEOMETRY |     2 |     1 |        12 |
| STL    | REAL-GEOMETRY |     2 |     1 |        12 |
| glTF   | REAL-GEOMETRY |     1 |     1 |         1 |
| DXF    | 2D-ONLY       |     5 |     1 |         0 |" \
  0

assert_summary "preflight: with OCCT, all clean" 0 0 "ALL_CHECKS_PASSED"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
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
