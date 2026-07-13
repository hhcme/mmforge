#!/bin/bash
# build-occt-shim.sh — Shared OCCT shim build logic
#
# Called by package.sh, Xcode Build Rust Bridge, and build.rs (via cargo).
# Uses content-hash fingerprint (sha256 of all shim sources) — NOT mtime.
#
# Exit codes:
#   0 = shim is up to date (or was successfully built)
#   1 = OCCT not configured (OCCT_INCLUDE_DIR/OCCT_LIB_DIR not set)
#   2 = shim build failed
#   3 = shim outdated and build required (caller should rebuild, then re-invoke)
#
# Output (stdout): path to libmmforge_occt_shim.a
# Diagnostics: stderr
#
# Usage:
#   source build-occt-shim.sh
#   ensure_occt_shim  # sets SHIM_LIB, OCCT_INCLUDE_DIR, OCCT_LIB_DIR vars
#   if [ $? -eq 0 ]; then ... fi
#
# Environment:
#   OCCT_INCLUDE_DIR     — required for OCCT build
#   OCCT_LIB_DIR         — required for OCCT build
#   MMFORGE_SHIM_DIR     — optional, override shim build output dir
#   CARGO_MANIFEST_DIR   — set by build.rs; fallback: auto-detect

set -euo pipefail

# ── Locate project root ──────────────────────────────────────────────────
if [ -n "${CARGO_MANIFEST_DIR:-}" ]; then
    SHIM_SRC_DIR="${CARGO_MANIFEST_DIR}/shim"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    ROOT="$(cd "$MACOS_DIR/.." && pwd)"
    SHIM_SRC_DIR="${ROOT}/crates/mmforge-geometry/shim"
fi

SHIM_BUILD_DIR="${MMFORGE_SHIM_DIR:-${SHIM_SRC_DIR}/build}"
SHIM_LIB="${SHIM_BUILD_DIR}/libmmforge_occt_shim.a"

# ── Content fingerprint ──────────────────────────────────────────────────
# Hash all shim source files.  mtime alone is unreliable across git checkout,
# CI cache, and network filesystems.  sha256 of concatenated source content
# gives a deterministic, reproducible fingerprint.
compute_fingerprint() {
    local fp=""
    for f in \
        "${SHIM_SRC_DIR}/mmforge_occt_shim.cpp" \
        "${SHIM_SRC_DIR}/mmforge_occt_shim.h" \
        "${SHIM_SRC_DIR}/CMakeLists.txt"; do
        if [ -f "$f" ]; then
            fp="${fp}$(sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null || echo "0000-${f}")"
        fi
    done
    echo "$fp" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "$fp" | shasum -a 256 | cut -d' ' -f1
}

# ── Main entry point ─────────────────────────────────────────────────────
# Returns: 0=ready, 1=no-OCCT, 2=build-failed
ensure_occt_shim() {
    # Must have OCCT configured.
    if [ -z "${OCCT_INCLUDE_DIR:-}" ] || [ -z "${OCCT_LIB_DIR:-}" ]; then
        echo "build-occt-shim: OCCT not configured (OCCT_INCLUDE_DIR/OCCT_LIB_DIR not set)." >&2
        return 1
    fi
    if [ ! -d "${OCCT_INCLUDE_DIR}" ] || [ ! -d "${OCCT_LIB_DIR}" ]; then
        echo "build-occt-shim: OCCT dirs not found: INCLUDE=${OCCT_INCLUDE_DIR}, LIB=${OCCT_LIB_DIR}" >&2
        return 1
    fi

    # Ensure cmake is available.
    if ! command -v cmake &>/dev/null; then
        echo "build-occt-shim: ERROR — cmake not found in PATH. Install cmake to build the OCCT shim." >&2
        return 2
    fi

    local current_fp
    current_fp=$(compute_fingerprint)

    # Check if shim exists and is current.
    local fp_file="${SHIM_BUILD_DIR}/.shim_fingerprint"
    if [ -f "$SHIM_LIB" ] && [ -f "$fp_file" ]; then
        local stored_fp
        stored_fp=$(cat "$fp_file" 2>/dev/null || echo "")
        if [ "$stored_fp" = "$current_fp" ]; then
            echo "build-occt-shim: shim up to date at ${SHIM_LIB}" >&2
            echo "${SHIM_LIB}"
            return 0
        fi
    fi

    # Build needed.
    echo "build-occt-shim: Building shim (source fingerprint changed or library missing)..." >&2
    mkdir -p "${SHIM_BUILD_DIR}"

    if ! cmake \
        -S "${SHIM_SRC_DIR}" \
        -B "${SHIM_BUILD_DIR}" \
        -DOpenCASCADE_INCLUDE_DIR="${OCCT_INCLUDE_DIR}" \
        -DOpenCASCADE_LIBRARY_DIR="${OCCT_LIB_DIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        >"${SHIM_BUILD_DIR}/.cmake_configure.log" 2>&1; then
        echo "build-occt-shim: ERROR — cmake configure failed. See ${SHIM_BUILD_DIR}/.cmake_configure.log" >&2
        return 2
    fi

    if ! cmake --build "${SHIM_BUILD_DIR}" >"${SHIM_BUILD_DIR}/.cmake_build.log" 2>&1; then
        echo "build-occt-shim: ERROR — cmake build failed. See ${SHIM_BUILD_DIR}/.cmake_build.log" >&2
        return 2
    fi

    if [ ! -f "$SHIM_LIB" ]; then
        echo "build-occt-shim: ERROR — build completed but ${SHIM_LIB} not found." >&2
        return 2
    fi

    # Write fingerprint.
    echo "$current_fp" > "$fp_file"

    echo "build-occt-shim: Successfully built ${SHIM_LIB}" >&2
    echo "${SHIM_LIB}"
    return 0
}
