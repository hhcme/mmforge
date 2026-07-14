#!/bin/bash
# test-git-archive-occt-gate.sh — Git archive clean-room OCCT gate test
#
# Creates a temporary git-archive copy of the repository, builds the
# OCCT shim from scratch (no pre-built artifacts), then builds the CLI
# with --features occt and runs the format geometry gate.
#
# REQUIREMENT: OCCT_INCLUDE_DIR and OCCT_LIB_DIR must be set and valid.
# This test PROVES that a fresh checkout (no pre-built shim/.a/.fingerprint)
# can produce STEP/IGES REAL-GEOMETRY.
#
# Usage:
#   OCCT_INCLUDE_DIR=/path/to/occt/include OCCT_LIB_DIR=/path/to/occt/lib \
#     bash macos/scripts/test-git-archive-occt-gate.sh
#
# Exit: 0 = STEP/IGES REAL-GEOMETRY achieved, 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*" >&2; }
bold()   { printf '\033[1m%s\033[0m\n' "$*" >&2; }
info()   { printf '  %s\n' "$*" >&2; }

# ── Pre-flight: OCCT must be configured ─────────────────────────────────
if [ -z "${OCCT_INCLUDE_DIR:-}" ] || [ -z "${OCCT_LIB_DIR:-}" ]; then
    red "FATAL: OCCT_INCLUDE_DIR and OCCT_LIB_DIR must both be set."
    red "  OCCT_INCLUDE_DIR=${OCCT_INCLUDE_DIR:-unset}"
    red "  OCCT_LIB_DIR=${OCCT_LIB_DIR:-unset}"
    exit 1
fi

if [ ! -d "${OCCT_INCLUDE_DIR}" ] || [ ! -d "${OCCT_LIB_DIR}" ]; then
    red "FATAL: OCCT directories not found."
    red "  OCCT_INCLUDE_DIR=${OCCT_INCLUDE_DIR} -> $( [ -d "${OCCT_INCLUDE_DIR}" ] && echo OK || echo MISSING )"
    red "  OCCT_LIB_DIR=${OCCT_LIB_DIR} -> $( [ -d "${OCCT_LIB_DIR}" ] && echo OK || echo MISSING )"
    exit 1
fi

bold "=== Git Archive OCCT Gate — Clean-Room Test ==="
info "OCCT_INCLUDE_DIR: ${OCCT_INCLUDE_DIR}"
info "OCCT_LIB_DIR:     ${OCCT_LIB_DIR}"
info "Repo root:        ${ROOT}"

# ── Create temp workspace ───────────────────────────────────────────────
WORKDIR=$(mktemp -d /tmp/mmforge_archive_gate.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

info "Workspace: $WORKDIR"

# Export a git archive of HEAD (source only, no build artifacts).
info "Creating git archive from HEAD …"
cd "$ROOT"
git archive --format=tar HEAD | (cd "$WORKDIR" && tar xf -)

# Verify the archive has the essential files.
for f in Cargo.toml \
         crates/mmforge-geometry/shim/CMakeLists.txt \
         crates/mmforge-geometry/shim/mmforge_occt_shim.cpp \
         crates/mmforge-geometry/shim/mmforge_occt_shim.h \
         macos/scripts/build-occt-shim.sh \
         docs/scripts/format-geometry-gate.sh \
         testdata/stl/box.stl \
         crates/mmforge-geometry/testdata/assembly.stp \
         crates/mmforge-geometry/testdata/box.igs; do
    if [ ! -f "$WORKDIR/$f" ]; then
        red "FATAL: git archive missing expected file: $f"
        exit 1
    fi
done
green "Git archive complete — $(find "$WORKDIR" -type f | wc -l | tr -d ' ') files extracted."

# Verify NO pre-built shim artifacts exist in the archive.
PREBUILT=(
    "crates/mmforge-geometry/shim/build/libmmforge_occt_shim.a"
    "crates/mmforge-geometry/shim/build/.shim_fingerprint"
    "crates/mmforge-geometry/shim/build/CMakeCache.txt"
)
for artifact in "${PREBUILT[@]}"; do
    if [ -f "$WORKDIR/$artifact" ]; then
        red "FATAL: git archive contains pre-built artifact: $artifact"
        exit 1
    fi
done
green "Confirmed: no pre-built shim artifacts in archive (clean checkout)."

# ── Build OCCT shim from scratch in the archive copy ────────────────────
info "Building OCCT shim from scratch in archive copy …"
export OCCT_INCLUDE_DIR OCCT_LIB_DIR
export CARGO_MANIFEST_DIR="$WORKDIR/crates/mmforge-geometry"

SHIM_PATH=""
if ! SHIM_PATH=$(bash "$WORKDIR/macos/scripts/build-occt-shim.sh"); then
    red "FATAL: OCCT shim build failed in archive copy."
    exit 1
fi
if [ -z "$SHIM_PATH" ] || [ ! -f "$SHIM_PATH" ]; then
    red "FATAL: build-occt-shim.sh returned invalid path: '${SHIM_PATH}'"
    exit 1
fi
export MMFORGE_SHIM_DIR="$(dirname "$SHIM_PATH")"
green "Shim built: ${SHIM_PATH}"

# ── Build CLI with --features occt in the archive copy ──────────────────
info "Building CLI with --features occt …"
cd "$WORKDIR"
cargo build --release -p mmforge-cli --features occt || {
    red "FATAL: cargo build --features occt failed in archive copy."
    exit 1
}
green "CLI built with OCCT support."

# ── Run format-geometry-gate.sh in the archive copy ─────────────────────
info "Running format-geometry-gate.sh …"
GATE_OUTPUT=""
set +e
GATE_OUTPUT=$(bash "$WORKDIR/docs/scripts/format-geometry-gate.sh" 2>&1)
GATE_RC=$?
set -e

echo "$GATE_OUTPUT"

# ── Verify results ──────────────────────────────────────────────────────
if [ "$GATE_RC" -ne 0 ]; then
    red "FAIL: format-geometry-gate.sh exited $GATE_RC (expected 0)"
    exit 1
fi

# STEP must be REAL-GEOMETRY
if echo "$GATE_OUTPUT" | grep "STEP" | grep -q "REAL-GEOMETRY"; then
    green "STEP = REAL-GEOMETRY ✅"
else
    red "FAIL: STEP is NOT REAL-GEOMETRY"
    exit 1
fi

# IGES must be REAL-GEOMETRY
if echo "$GATE_OUTPUT" | grep "IGES" | grep -q "REAL-GEOMETRY"; then
    green "IGES = REAL-GEOMETRY ✅"
else
    red "FAIL: IGES is NOT REAL-GEOMETRY"
    exit 1
fi

# STL must be REAL-GEOMETRY
if echo "$GATE_OUTPUT" | grep "STL" | grep -q "REAL-GEOMETRY"; then
    green "STL = REAL-GEOMETRY ✅"
else
    red "FAIL: STL is NOT REAL-GEOMETRY"
    exit 1
fi

# glTF must be REAL-GEOMETRY
if echo "$GATE_OUTPUT" | grep "glTF" | grep -q "REAL-GEOMETRY"; then
    green "glTF = REAL-GEOMETRY ✅"
else
    red "FAIL: glTF is NOT REAL-GEOMETRY"
    exit 1
fi

# DXF must be 2D-ONLY
if echo "$GATE_OUTPUT" | grep "DXF" | grep -q "2D-ONLY"; then
    green "DXF = 2D-ONLY ✅"
else
    red "FAIL: DXF is NOT 2D-ONLY"
    exit 1
fi

bold "=== Git Archive OCCT Gate: ALL CHECKS PASSED ==="
info "Clean-room git archive → shim build → CLI build → gate:"
info "  STEP = REAL-GEOMETRY, IGES = REAL-GEOMETRY, STL = REAL-GEOMETRY"
info "  glTF = REAL-GEOMETRY, DXF = 2D-ONLY"
exit 0
