#!/bin/bash
# MMForge macOS Performance Baseline
# Run: bash docs/scripts/perf-baseline.sh
#
# Compatible with macOS /bin/bash 3.2 (no associative arrays).
# Requires: cargo, mmforge-cli built
#
# Exit codes:
#   0  PASS — all formats REAL-GEOMETRY or 2D-ONLY (no ERROR, no PLACEHOLDER).
#   1  FAIL — one or more formats hard ERROR (not downgradable).
#   2  FAIL — one or more formats PLACEHOLDER (empty model).
#   3  ADVISORY — STEP/IGES no-OCCT ERROR downgraded (MMFORGE_NO_OCCT_ADVISORY=1);
#       no non-OCCT ERROR, no PLACEHOLDER. Geometry for STEP/IGES not verified.
#
# Advisory downgrade rules (MMFORGE_NO_OCCT_ADVISORY=1):
#   - Only STEP and IGES no-OCCT errors are downgraded to advisory (exit 3).
#   - STL, glTF, or DXF ERROR always hard-fails (exit 1).
#   - Any PLACEHOLDER always hard-fails (exit 2).
#   - Without advisory flag, any ERROR exits 1.

set -euo pipefail

ADVISORY_NO_OCCT="${MMFORGE_NO_OCCT_ADVISORY:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Use release binary if OCCT is available (--features requires release build).
# Fall back to debug `cargo run` otherwise.
if [ -n "${OCCT_INCLUDE_DIR:-}" ] && [ -n "${OCCT_LIB_DIR:-}" ] && [ -n "${MMFORGE_SHIM_DIR:-}" ]; then
  if [ -x "$ROOT/target/release/mmforge" ]; then
    CLI="$ROOT/target/release/mmforge"
  else
    CLI="cargo run --release -p mmforge-cli --features mmforge-bridge/occt --"
  fi
else
  CLI="cargo run -p mmforge-cli --"
fi

echo "# MMForge Performance Baseline"
echo "# Date: $(date '+%Y-%m-%d %H:%M')"
echo "# Platform: $(uname -m)"
echo "# Bash: $(/bin/bash --version 2>&1 | head -1)"
echo ""

# Fixture list: paired format-name file-path
# Format: FMT name on even indices, path on odd indices.
FIXTURES=(
  "STEP"  "$ROOT/crates/mmforge-geometry/testdata/PQ-04909-A.STEP"
  "IGES"  "$ROOT/crates/mmforge-geometry/testdata/box.igs"
  "STL"   "$ROOT/testdata/stl/box.stl"
  "glTF"  "$ROOT/testdata/gltf/box.gltf"
  "DXF"   "$ROOT/crates/mmforge-format-dxf/testdata/test.dxf"
)

run_one() {
  local FMT="$1"
  local FILE="$2"

  if [ ! -f "$FILE" ]; then
    echo "### $FMT: SKIPPED — fixture not found: $FILE"
    RESULT_LINES+=("$FMT|SKIPPED|—|—|—")
    echo ""
    return
  fi

  local FILE_SIZE
  FILE_SIZE=$(du -h "$FILE" | cut -f1 2>/dev/null || echo "?")
  echo "### $FMT ($FILE_SIZE) — $FILE"
  echo '```'

  # Benchmark
  set +e
  local BENCH_OUT
  BENCH_OUT=$(cd "$ROOT" && $CLI benchmark "$FILE" --format text --iterations 3 2>&1)
  local BENCH_RC=$?
  set -e

  if [ $BENCH_RC -ne 0 ]; then
    echo "benchmark: FAILED"
    echo "$BENCH_OUT" | head -5
  else
    echo "$BENCH_OUT"
  fi

  echo ""

  # Info — capture output for geometry validation
  set +e
  local INFO_OUT
  INFO_OUT=$(cd "$ROOT" && $CLI info "$FILE" --format text 2>&1)
  local INFO_RC=$?
  set -e

  echo "$INFO_OUT"

  # Parse geometry stats from info output
  local GEOM_COUNT=0
  local TRI_COUNT=0
  local ND_COUNT="—"
  ND_COUNT=$(echo "$INFO_OUT" | awk '/^nodes/ {print $NF}' || echo "—")
  GEOM_COUNT=$(echo "$INFO_OUT" | awk '/^geoms/ {print $NF}' || echo "0")
  TRI_COUNT=$(echo "$INFO_OUT" | awk '/^triangles:/ {print $NF}' || echo "0")

  # Ensure we have integers for comparison
  local geoms_int=${GEOM_COUNT##*[!0-9]}
  local tris_int=${TRI_COUNT##*[!0-9]}
  [ -z "$geoms_int" ] && geoms_int=0
  [ -z "$tris_int" ] && tris_int=0

  # Determine real-geometry status
  local GEO_STATUS
  if [ "$INFO_RC" -ne 0 ]; then
    GEO_STATUS="ERROR"
  elif [ "$geoms_int" -gt 0 ] && [ "$tris_int" -gt 0 ]; then
    GEO_STATUS="REAL-GEOMETRY"
  elif [ "$geoms_int" -gt 0 ]; then
    GEO_STATUS="2D-ONLY"
  else
    GEO_STATUS="PLACEHOLDER"
  fi

  RESULT_LINES+=("$FMT|$GEO_STATUS|$ND_COUNT|$GEOM_COUNT|$TRI_COUNT")

  echo '```'
  echo ""
}

# Accumulator for summary table
RESULT_LINES=()

echo "## Parse + Info Benchmarks"
echo ""

LEN=${#FIXTURES[@]}
for ((i=0; i<LEN; i+=2)); do
  FMT="${FIXTURES[$i]}"
  FILE="${FIXTURES[$((i+1))]}"
  run_one "$FMT" "$FILE"
done

echo "---"
echo ""
echo "## Geometry Status Summary"
echo ""
echo "| Format | Status | Nodes | Geoms | Triangles |"
echo "|--------|--------|-------|-------|-----------|"
for line in "${RESULT_LINES[@]}"; do
  IFS='|' read -r FMT STATUS NDS GMS TRIS <<< "$line"
  printf "| %-6s | %-13s | %5s | %5s | %9s |\n" "$FMT" "$STATUS" "$NDS" "$GMS" "$TRIS"
done
# Compute exit code from worst status across all formats.
# Priority (worst→best): non-OCCT ERROR > PLACEHOLDER > OCCT ERROR(advisory) > clean.
HAD_ERROR=0
HAD_PLACEHOLDER=0
HAD_NON_OCCT_ERROR=0
HAD_OCCT_ERROR=0

for line in "${RESULT_LINES[@]}"; do
  IFS='|' read -r FMT STATUS NDS GMS TRIS <<< "$line"
  case "$STATUS" in
    ERROR)
      if [ "$FMT" = "STEP" ] || [ "$FMT" = "IGES" ]; then
        HAD_OCCT_ERROR=1
      else
        HAD_NON_OCCT_ERROR=1
      fi
      HAD_ERROR=1
      ;;
    PLACEHOLDER) HAD_PLACEHOLDER=1 ;;
  esac
done

echo ""
echo "> REAL-GEOMETRY: geoms > 0 AND triangles > 0 — pipeline produces renderable mesh data."
echo "> 2D-ONLY: geoms > 0 but triangles == 0 — 2D format, no triangulation (expected for DXF)."
echo "> PLACEHOLDER: geoms == 0 — parser returned empty model (format parser not wired or feature missing)."
echo "> ERROR: parser returned a hard error (feature not enabled, file invalid, etc)."
echo ""

# Determine final exit
FINAL_EXIT=0
GEOMETRY_VERDICT="PASS"

if [ "$HAD_ERROR" -eq 1 ]; then
  if [ "$ADVISORY_NO_OCCT" = "1" ] \
     && [ "$HAD_NON_OCCT_ERROR" -eq 0 ] \
     && [ "$HAD_PLACEHOLDER" -eq 0 ] \
     && [ "$HAD_OCCT_ERROR" -eq 1 ]; then
    echo "> ADVISORY: STEP/IGES geometry NOT verified (no OpenCASCADE)."
    echo ">           Only STL, glTF, and DXF are fully verified."
    echo ">           MMFORGE_NO_OCCT_ADVISORY=1 downgrades these known gaps."
    GEOMETRY_VERDICT="ADVISORY"
    FINAL_EXIT=3
  else
    if [ "$ADVISORY_NO_OCCT" = "1" ] && [ "$HAD_NON_OCCT_ERROR" -eq 1 ]; then
      echo "> NOTE: non-OCCT format(s) also in ERROR — advisory does not cover these."
    fi
    FINAL_EXIT=1
  fi
elif [ "$HAD_PLACEHOLDER" -eq 1 ]; then
  FINAL_EXIT=2
fi

echo "---"
echo "Generated by docs/scripts/perf-baseline.sh"
echo "GEOMETRY_VERDICT: $GEOMETRY_VERDICT"
exit $FINAL_EXIT
