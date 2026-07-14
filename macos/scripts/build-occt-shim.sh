#!/bin/bash
# build-occt-shim.sh — Shared OCCT shim build logic
#
# Can be used in two ways:
#   1. source build-occt-shim.sh && ensure_occt_shim   (by package.sh, Xcode)
#   2. bash build-occt-shim.sh                          (direct execution)
#
# Uses content-hash fingerprint (sha256 of all shim sources) — NOT mtime.
#
# Exit codes (when executed directly):
#   0 = shim built successfully or already up to date
#   1 = OCCT not configured (OCCT_INCLUDE_DIR/OCCT_LIB_DIR not set or invalid)
#   2 = shim build failed (cmake configure or build error)
#
# When sourced, ensure_occt_shim returns the same codes via return.
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
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    SHIM_SRC_DIR="$(cd "$SCRIPT_DIR/../../crates/mmforge-geometry/shim" && pwd)"
fi

SHIM_BUILD_DIR="${MMFORGE_SHIM_DIR:-${SHIM_SRC_DIR}/build}"
SHIM_LIB="${SHIM_BUILD_DIR}/libmmforge_occt_shim.a"

# ── Content fingerprint ──────────────────────────────────────────────────
#
# CANONICAL FINGERPRINT SPEC (must match compute_shim_fingerprint in build.rs):
#   SHA256 of the concatenated raw bytes of (in order):
#     1. mmforge_occt_shim.cpp
#     2. mmforge_occt_shim.h
#     3. CMakeLists.txt
#   Produces a 64-char lowercase hex string.
#
# mtime alone is unreliable across git checkout, CI cache, and network
# filesystems.  This content-hash fingerprint is deterministic and
# byte-identical to the Rust build.rs implementation.
compute_fingerprint() {
    cat "${SHIM_SRC_DIR}/mmforge_occt_shim.cpp" \
        "${SHIM_SRC_DIR}/mmforge_occt_shim.h" \
        "${SHIM_SRC_DIR}/CMakeLists.txt" 2>/dev/null \
        | shasum -a 256 | cut -d' ' -f1
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
        echo "build-occt-shim: OCCT dirs not found: INCLUDE=${OCCT_INCLUDE_DIR:-unset}, LIB=${OCCT_LIB_DIR:-unset}" >&2
        return 1
    fi

    # Ensure cmake is available.
    if ! command -v cmake &>/dev/null; then
        echo "build-occt-shim: ERROR — cmake not found in PATH." >&2
        return 2
    fi

    local current_fp
    current_fp=$(compute_fingerprint)
    if [ -z "$current_fp" ]; then
        echo "build-occt-shim: ERROR — could not compute source fingerprint (missing sources?)." >&2
        return 2
    fi

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
    echo "build-occt-shim: Building shim (fingerprint changed or library missing)..." >&2
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

    echo "$current_fp" > "$fp_file"
    echo "build-occt-shim: Successfully built ${SHIM_LIB}" >&2
    echo "${SHIM_LIB}"
    return 0
}

# ── Direct execution ─────────────────────────────────────────────────────
# When run as `bash build-occt-shim.sh`, call ensure_occt_shim and exit
# with its return code.
#
# stdout: exactly ONE line — absolute path to libmmforge_occt_shim.a
# stderr: all diagnostics, progress, errors
# exit:   0=ready, 1=no-OCCT, 2=build-failed
#
# Callers compute MMFORGE_SHIM_DIR from the path themselves, e.g.:
#   SHIM_PATH=$(bash build-occt-shim.sh) && export MMFORGE_SHIM_DIR="$(dirname "$SHIM_PATH")"
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    ensure_occt_shim
    exit $?
fi
