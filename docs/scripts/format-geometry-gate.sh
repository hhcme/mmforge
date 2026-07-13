#!/bin/bash
# MMForge Format Geometry Gate — fixture-based format verification
#
# Tests parse + geometry extraction for every detectable CAD format using
# real testdata fixtures.  Produces a machine-readable summary table on
# stdout and returns a structured exit code for preflight integration.
#
# Exit codes (contract with preflight-check.sh section 10):
#   0 = PASS           — all formats REAL-GEOMETRY or 2D-ONLY
#   1 = FAIL           — hard ERROR on any non-OCCT format (STL/glTF/DXF)
#   2 = FAIL           — PLACEHOLDER (empty model from any format)
#   3 = ADVISORY       — STEP/IGES ERROR only; all non-OCCT formats OK
#
# Environment:
#   MMFORGE_NO_OCCT_ADVISORY=1  downgrade STEP/IGES errors to advisory
#   MMFORGE_CLI                override path to mmforge binary
#
# Usage:
#   bash docs/scripts/format-geometry-gate.sh
#   MMFORGE_NO_OCCT_ADVISORY=1 bash docs/scripts/format-geometry-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADVISORY="${MMFORGE_NO_OCCT_ADVISORY:-0}"
CLI="${MMFORGE_CLI:-}"

# Build CLI from source if no override
if [ -z "$CLI" ]; then
  echo "# Building CLI from source (cargo build --release -p mmforge-cli)" >&2
  cargo build --release -p mmforge-cli --manifest-path "$ROOT/Cargo.toml" || {
    echo "FATAL: cargo build failed" >&2
    exit 1
  }
  CLI="$ROOT/target/release/mmforge"
fi

"$CLI" version >/dev/null 2>&1 || {
  echo "FATAL: CLI binary check failed" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Fixtures: format -> extension, path, min_tris, is_2d
# Format: "FMT|ext|path|min_tris|is_2d"
# ---------------------------------------------------------------------------
TESTDATA="$ROOT/testdata"
GEOM_TESTDATA="$ROOT/crates/mmforge-geometry/testdata"
DXF_TESTDATA="$ROOT/crates/mmforge-format-dxf/testdata"

fixture_info() {
  case "$1" in
    STL)  echo "stl|$TESTDATA/stl/box.stl|1|0" ;;
    glTF) echo "gltf|$TESTDATA/gltf/box.gltf|1|0" ;;
    DXF)  echo "dxf|$DXF_TESTDATA/test.dxf|0|1" ;;
    STEP) echo "stp|$GEOM_TESTDATA/assembly.stp|1|0" ;;
    IGES) echo "igs|$GEOM_TESTDATA/box.igs|1|0" ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse a single fixture and output a structured row.
# Row: | FORMAT | STATUS | NODE_COUNT | GEOM_COUNT | TRI_COUNT |
# ---------------------------------------------------------------------------
check_format() {
  local fmt="$1"
  local info ext path min_tris is_2d
  info=$(fixture_info "$fmt")
  ext=$(echo "$info" | cut -d'|' -f1)
  path=$(echo "$info" | cut -d'|' -f2)
  min_tris=$(echo "$info" | cut -d'|' -f3)
  is_2d=$(echo "$info" | cut -d'|' -f4)

  if [ ! -f "$path" ]; then
    printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "$fmt" "FIXTURE_MISSING" "-" "-" "-"
    return
  fi

  local json_output rc
  set +e
  json_output=$("$CLI" info "$path" --format json 2>/dev/null)
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    if [ "$is_2d" = "1" ]; then
      printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "$fmt" "2D-ONLY" "-" "-" "-"
      return
    fi
    printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "$fmt" "ERROR" "-" "-" "-"
    return
  fi

  local triangle_count node_count geom_count
  triangle_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('triangle_count',0))" 2>/dev/null || echo "0")
  node_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_count',0))" 2>/dev/null || echo "0")
  geom_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('geometry_count',0))" 2>/dev/null || echo "0")

  local status
  if [ "$is_2d" = "1" ]; then
    if [ "$geom_count" -gt 0 ] 2>/dev/null; then
      status="2D-ONLY"
    else
      status="ERROR"
    fi
  elif [ "$triangle_count" -gt 0 ] 2>/dev/null; then
    status="REAL-GEOMETRY"
  elif [ "$node_count" -gt 0 ] 2>/dev/null; then
    status="PLACEHOLDER"
  else
    status="ERROR"
  fi

  printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "$fmt" "$status" "$node_count" "$geom_count" "$triangle_count"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "# Format Geometry Gate — $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "# CLI: $CLI" >&2
echo "" >&2

printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "FORMAT" "STATUS" "NODES" "GEOMS" "TRIANGLES"
printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "-------" "---------------" "------" "------" "-----------"

TABLE=$(mktemp -t mmforge_gate.XXXXXX)
trap "rm -f $TABLE" EXIT

for fmt in STL glTF DXF STEP IGES; do
  check_format "$fmt" | tee -a "$TABLE"
done

echo "" >&2

# ---------------------------------------------------------------------------
# Compute verdict
# ---------------------------------------------------------------------------
had_occt_error=0
had_non_occt_error=0
had_placeholder=0
had_fixture_missing=0

while IFS='|' read -r _ rawfmt rawstatus _ _; do
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
    FIXTURE_MISSING) had_fixture_missing=1 ; had_non_occt_error=1 ;;
  esac
done < "$TABLE"

if [ "$had_non_occt_error" -eq 0 ] && [ "$had_placeholder" -eq 0 ] && [ "$had_occt_error" -eq 0 ]; then
  echo "# VERDICT: PASS" >&2
  exit 0
elif [ "$had_fixture_missing" -eq 1 ]; then
  echo "# VERDICT: FAIL (fixture missing)" >&2
  exit 1
elif [ "$had_non_occt_error" -eq 1 ]; then
  echo "# VERDICT: FAIL (non-OCCT format ERROR)" >&2
  exit 1
elif [ "$had_placeholder" -eq 1 ]; then
  echo "# VERDICT: FAIL (PLACEHOLDER)" >&2
  exit 2
elif [ "$had_occt_error" -eq 1 ]; then
  if [ "$ADVISORY" = "1" ]; then
    echo "# VERDICT: ADVISORY (STEP/IGES require OpenCASCADE)" >&2
    exit 3
  else
    echo "# VERDICT: FAIL (STEP/IGES ERROR)" >&2
    exit 1
  fi
fi

exit 1
