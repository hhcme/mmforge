#!/bin/bash
# MMForge Format Geometry Gate — fixture-based format verification
#
# Tests parse + geometry extraction for every detectable CAD format using
# real testdata fixtures.  Produces a machine-readable summary table on
# stdout and returns a structured exit code for preflight integration.
#
# OCCT detection: checks whether the OCCT C ABI shim static library exists
# and whether mmforge-geometry can link it.  If yes, builds CLI with
# --features occt and tests STEP/IGES with real geometry.  If no, builds
# without OCCT and expects STEP/IGES to return advisory errors.
#
# Exit codes (contract with preflight-check.sh section 10):
#   0 = PASS           — all formats REAL-GEOMETRY or 2D-ONLY
#   1 = FAIL           — hard ERROR on any non-OCCT format (STL/glTF/DXF)
#   2 = FAIL           — PLACEHOLDER (empty model from any format)
#   3 = ADVISORY       — STEP/IGES ERROR only; all non-OCCT formats OK
#
# Environment:
#   MMFORGE_NO_OCCT_ADVISORY=1  downgrade STEP/IGES errors to advisory
#
# Usage:
#   bash docs/scripts/format-geometry-gate.sh
#   MMFORGE_NO_OCCT_ADVISORY=1 bash docs/scripts/format-geometry-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADVISORY="${MMFORGE_NO_OCCT_ADVISORY:-0}"

# ---------------------------------------------------------------------------
# OCCT detection & shim build — unified entry point.
#
# Contract:
#   When OCCT_INCLUDE_DIR + OCCT_LIB_DIR are both set AND valid dirs,
#   we MUST build the shim, export MMFORGE_SHIM_DIR, and build the CLI
#   with --features occt.  Silent degradation to NO_OCCT is FORBIDDEN
#   when OCCT is explicitly configured — any failure is a hard error.
#
#   When OCCT is NOT configured, we probe the default shim path and
#   may fall back gracefully (STEP/IGES advisory).
# ---------------------------------------------------------------------------
BUILD_SHIM_SCRIPT="$ROOT/macos/scripts/build-occt-shim.sh"
SHIM_LIB="$ROOT/crates/mmforge-geometry/shim/build/libmmforge_occt_shim.a"
TESTDATA="$ROOT/testdata"
HAVE_OCCT=0

TARGET_DIR_FLAG=""
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  TARGET_DIR_FLAG="--target-dir $CARGO_TARGET_DIR"
fi

# ── Resolve CLI ──────────────────────────────────────────────────────────
if [ -n "${MMFORGE_CLI:-}" ]; then
  CLI="$MMFORGE_CLI"
  echo "# Using MMFORGE_CLI: $CLI (skipping build)" >&2
  # Detect OCCT from pre-built CLI.
  RUNTIME_OCCT=$("$CLI" info "$TESTDATA/stl/box.stl" --format json 2>/dev/null | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('occt_available') else 0)" 2>/dev/null || echo "0")
  if [ "$RUNTIME_OCCT" = "1" ]; then HAVE_OCCT=1; fi
else
  # ── Detect OCCT configuration ──────────────────────────────────────────
  OCCT_CONFIGURED=0
  if [ -n "${OCCT_INCLUDE_DIR:-}" ] && [ -n "${OCCT_LIB_DIR:-}" ]; then
    if [ -d "${OCCT_INCLUDE_DIR}" ] && [ -d "${OCCT_LIB_DIR}" ]; then
      OCCT_CONFIGURED=1
    fi
  fi

  if [ "$OCCT_CONFIGURED" -eq 1 ]; then
    # ── OCCT explicitly configured: build shim, then CLI with occt ───────
    echo "# OCCT configured — building shim via build-occt-shim.sh …" >&2
    export OCCT_INCLUDE_DIR OCCT_LIB_DIR
    export CARGO_MANIFEST_DIR="$ROOT/crates/mmforge-geometry"

    SHIM_PATH=""
    if ! SHIM_PATH=$(bash "$BUILD_SHIM_SCRIPT"); then
      echo "FATAL: OCCT shim build/verify failed.  Fix OCCT configuration or unset OCCT_INCLUDE_DIR/OCCT_LIB_DIR to build without OCCT." >&2
      exit 1
    fi
    if [ -z "$SHIM_PATH" ] || [ ! -f "$SHIM_PATH" ]; then
      echo "FATAL: build-occt-shim.sh returned invalid path: '${SHIM_PATH}'" >&2
      exit 1
    fi
    export MMFORGE_SHIM_DIR="$(dirname "$SHIM_PATH")"
    HAVE_OCCT=1

    echo "# Building CLI with --features occt (shim: ${SHIM_PATH}) …" >&2
    cargo build --release -p mmforge-cli --features occt \
      --manifest-path "$ROOT/Cargo.toml" $TARGET_DIR_FLAG || {
      echo "FATAL: CLI build with --features occt failed.  OCCT is configured — refusing to silently degrade." >&2
      exit 1
    }
  elif [ -f "$SHIM_LIB" ]; then
    # ── OCCT not configured, but shim exists at default path ─────────────
    echo "# OCCT shim detected at $SHIM_LIB (env vars not set) — attempting --features occt …" >&2
    if cargo build --release -p mmforge-cli --features occt \
      --manifest-path "$ROOT/Cargo.toml" $TARGET_DIR_FLAG 2>/dev/null; then
      HAVE_OCCT=1
      echo "# OCCT build succeeded." >&2
    else
      echo "# OCCT build failed — falling back to no-OCCT (STEP/IGES will be advisory)." >&2
      cargo build --release -p mmforge-cli \
        --manifest-path "$ROOT/Cargo.toml" $TARGET_DIR_FLAG || {
        echo "FATAL: cargo build failed" >&2; exit 1
      }
    fi
  else
    # ── No OCCT at all — build without ───────────────────────────────────
    echo "# No OCCT configured — building without OCCT (STEP/IGES will be advisory)." >&2
    cargo build --release -p mmforge-cli \
      --manifest-path "$ROOT/Cargo.toml" $TARGET_DIR_FLAG || {
      echo "FATAL: cargo build failed" >&2; exit 1
    }
  fi

  CLI="$ROOT/target/release/mmforge"
  if [ -n "$TARGET_DIR_FLAG" ]; then
    CLI="$CARGO_TARGET_DIR/release/mmforge"
  fi
fi

"$CLI" version >/dev/null 2>&1 || {
  echo "FATAL: CLI binary check failed ($CLI)" >&2
  exit 1
}

# Confirm runtime OCCT from the CLI we just built.
# (Double-check: the build may have succeeded with occt but linked against
#  a broken shim — the runtime query is the final truth.)
if [ "$HAVE_OCCT" -eq 0 ]; then
  RUNTIME_OCCT=$("$CLI" info "$TESTDATA/stl/box.stl" --format json 2>/dev/null | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('occt_available') else 0)" 2>/dev/null || echo "0")
  if [ "$RUNTIME_OCCT" = "1" ]; then HAVE_OCCT=1; fi
fi

# ---------------------------------------------------------------------------
# Fixtures: format -> extension, path, min_tris, is_2d
# ---------------------------------------------------------------------------
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
# Parse a single fixture via CLI info --format json.
# Row: | FORMAT | STATUS | NODE_COUNT | GEOM_COUNT | TRI_COUNT |
#
# Key fix: the CLI now outputs errors as valid JSON on stdout
# (with "error" field) when --format json is used.  This guarantees
# the gate can always parse the output without stderr contamination.
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

  # Capture stdout only — the CLI guarantees JSON on stdout for --format json.
  local json_output
  json_output=$("$CLI" info "$path" --format json 2>/dev/null) || true

  # Parse JSON — handle both success and error responses.
  local triangle_count node_count geom_count has_error error_msg
  triangle_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('triangle_count',0))" 2>/dev/null || echo "0")
  node_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_count',0))" 2>/dev/null || echo "0")
  geom_count=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('geometry_count',0))" 2>/dev/null || echo "0")
  has_error=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(1 if d.get('error') else 0)" 2>/dev/null || echo "0")
  error_msg=$(echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

  # If JSON parsing completely failed (no valid JSON at all), treat as ERROR.
  if [ "$node_count" = "0" ] && [ "$triangle_count" = "0" ] && [ "$has_error" = "0" ] && [ "$is_2d" = "0" ]; then
    printf '| %-6s | %-14s | %6s | %6s | %10s |\n' "$fmt" "JSON_PARSE_FAIL" "-" "-" "-"
    return
  fi

  # Determine status from JSON response.
  local status
  if [ "$has_error" = "1" ]; then
    # CLI returned a JSON error response — check if it's an OCCT advisory.
    if echo "$error_msg" | grep -qi "occt\|opencascade"; then
      if [ "$HAVE_OCCT" -eq 1 ]; then
        status="ERROR"
      else
        status="NO_OCCT"
      fi
    else
      status="ERROR"
    fi
  elif [ "$is_2d" = "1" ]; then
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
echo "# OCCT: $([ "$HAVE_OCCT" -eq 1 ] && echo "YES (shim detected)" || echo "NO (advisory mode)")" >&2
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
# Compute verdict from the table
# ---------------------------------------------------------------------------
had_occt_error=0
had_non_occt_error=0
had_placeholder=0
had_json_parse_fail=0

while IFS='|' read -r _ rawfmt rawstatus _ _; do
  fmt=$(echo "$rawfmt" | tr -d ' ')
  status=$(echo "$rawstatus" | tr -d ' ')

  case "$status" in
    NO_OCCT)
      # STEP/IGES with no OCCT — advisory-able
      case "$fmt" in
        STEP|IGES) had_occt_error=1 ;;
      esac
      ;;
    ERROR|JSON_PARSE_FAIL)
      case "$fmt" in
        STEP|IGES)
          # With OCCT installed, STEP/IGES ERROR is real.
          # Without OCCT, NO_OCCT status handles it.
          if [ "$HAVE_OCCT" -eq 1 ]; then
            had_non_occt_error=1
          else
            had_occt_error=1
          fi
          ;;
        *) had_non_occt_error=1 ;;
      esac
      ;;
    PLACEHOLDER) had_placeholder=1 ;;
  esac
done < "$TABLE"

if [ "$had_non_occt_error" -eq 0 ] && [ "$had_placeholder" -eq 0 ] && [ "$had_occt_error" -eq 0 ]; then
  echo "# VERDICT: PASS (all formats REAL-GEOMETRY or 2D-ONLY)" >&2
  exit 0
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
    echo "# VERDICT: FAIL (STEP/IGES ERROR, set MMFORGE_NO_OCCT_ADVISORY=1)" >&2
    exit 1
  fi
fi

exit 1
