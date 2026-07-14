#!/bin/bash
# test-xcode-shell-build.sh — Non-GUI regression tests for the Xcode
# Build Rust Bridge shell path (build-occt-shim.sh + validation logic).
#
# Tests:
#   1. build-occt-shim.sh stdout contract — exactly ONE line, archive path only
#   2. build-occt-shim.sh stderr contract — all diagnostics on stderr
#   3. Xcode path validation: missing OCCT → graceful no-OCCT
#   4. Xcode path validation: SHIM_PATH non-empty + exists + parent dir exists
#   5. Xcode path validation: invalid SHIM_PATH detected
#   6. Fingerprint consistency: shell fingerprint matches Rust fingerprint
#
# Usage:
#   bash macos/scripts/test-xcode-shell-build.sh
#
# Exit: 0 = all passed, 1 = at least one failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_SHIM="${SCRIPT_DIR}/build-occt-shim.sh"

PASSED=0
FAILED=0

green()  { printf '\033[32m  PASS\033[0m %s\n' "$*"; }
red()    { printf '\033[31m  FAIL\033[0m %s\n' "$*"; }
header() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ((PASSED++)) || true
        green "$label"
    else
        ((FAILED++)) || true
        red "$label — expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        ((PASSED++)) || true
        green "$label"
    else
        ((FAILED++)) || true
        red "$label — output did not contain '${needle}'"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        ((PASSED++)) || true
        green "$label"
    else
        ((FAILED++)) || true
        red "$label — file not found: ${path}"
    fi
}

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        ((PASSED++)) || true
        green "$label"
    else
        ((FAILED++)) || true
        red "$label — expected exit ${expected}, got ${actual}"
    fi
}

# ──────────────────────────────────────────────────────────────────────
# Test 1: stdout contract — exactly ONE line, archive path only
# ──────────────────────────────────────────────────────────────────────
header "1. stdout contract: exactly ONE archive path"

# Capture stdout and stderr separately.
stdout_file=$(mktemp -t mmforge_test_stdout.XXXXXX)
stderr_file=$(mktemp -t mmforge_test_stderr.XXXXXX)
trap "rm -f $stdout_file $stderr_file" EXIT

set +e
OCCT_INCLUDE_DIR="/opt/homebrew/include/opencascade" \
OCCT_LIB_DIR="/opt/homebrew/lib" \
CARGO_MANIFEST_DIR="${ROOT}/crates/mmforge-geometry" \
bash "$BUILD_SHIM" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

stdout_lines=$(wc -l < "$stdout_file" | tr -d ' ')
assert_eq "1a. stdout is exactly one line" "1" "$stdout_lines"

stdout_content=$(cat "$stdout_file")
assert_contains "1b. stdout contains libmmforge_occt_shim.a" "$stdout_content" "libmmforge_occt_shim.a"

assert_exit "1c. exit code is 0 or 1 or 2" 0 "$rc"

# ──────────────────────────────────────────────────────────────────────
# Test 2: stderr contract — diagnostics on stderr, none on stdout
# ──────────────────────────────────────────────────────────────────────
header "2. stderr contract: diagnostics on stderr only"

# stdout must NOT contain diagnostic phrases.
diagnostic_phrases=("Building" "ERROR" "up to date" "fingerprint" "OCCT not configured")
for phrase in "${diagnostic_phrases[@]}"; do
    if echo "$stdout_content" | grep -qi "$phrase"; then
        ((FAILED++)) || true
        red "2. stdout must NOT contain '${phrase}' — but it does"
    else
        ((PASSED++)) || true
        green "2. stdout clean: no '${phrase}'"
    fi
done

# stderr should be non-empty (at least some diagnostic).
stderr_size=$(wc -c < "$stderr_file" | tr -d ' ')
if [ "$stderr_size" -gt 0 ]; then
    ((PASSED++)) || true
    green "2. stderr is non-empty (diagnostics present)"
else
    ((FAILED++)) || true
    red "2. stderr is empty — diagnostics missing"
fi

# ──────────────────────────────────────────────────────────────────────
# Test 3: Missing OCCT dirs → graceful no-OCCT
# ──────────────────────────────────────────────────────────────────────
header "3. Missing OCCT: graceful no-OCCT path"

set +e
OCCT_INCLUDE_DIR="/nonexistent/occt/include" \
OCCT_LIB_DIR="/nonexistent/occt/lib" \
CARGO_MANIFEST_DIR="${ROOT}/crates/mmforge-geometry" \
bash "$BUILD_SHIM" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

assert_exit "3a. exit code 1 (no OCCT configured)" 1 "$rc"

stderr_content=$(cat "$stderr_file")
assert_contains "3b. stderr mentions OCCT dirs not found" "$stderr_content" "OCCT dirs not found"

# ──────────────────────────────────────────────────────────────────────
# Test 4: Xcode path validation — SHIM_PATH non-empty + exists + dir
# ──────────────────────────────────────────────────────────────────────
header "4. Xcode path validation logic"

# Simulate the Xcode shell script's validation logic.
test_xcode_validation() {
    local shim_path="$1"
    local expect_pass="$2"  # "pass" or "fail"
    local label="$3"

    local valid=true
    if [ -z "$shim_path" ] || [ ! -f "$shim_path" ]; then
        valid=false
    else
        local shim_dir
        shim_dir="$(dirname "$shim_path")"
        if [ ! -d "$shim_dir" ]; then
            valid=false
        fi
    fi

    if [ "$expect_pass" = "pass" ] && [ "$valid" = "true" ]; then
        ((PASSED++)) || true
        green "4. ${label}"
    elif [ "$expect_pass" = "fail" ] && [ "$valid" = "false" ]; then
        ((PASSED++)) || true
        green "4. ${label}"
    else
        ((FAILED++)) || true
        red "4. ${label} — expected ${expect_pass}, valid=${valid}"
    fi
}

# Valid: the actual shim library.
SHIM_LIB="${ROOT}/crates/mmforge-geometry/shim/build/libmmforge_occt_shim.a"
test_xcode_validation "$SHIM_LIB" "pass" "valid shim path accepted"

# Invalid: empty path.
test_xcode_validation "" "fail" "empty path rejected"

# Invalid: nonexistent file.
test_xcode_validation "/nonexistent/libmmforge_occt_shim.a" "fail" "nonexistent file rejected"

# Invalid: dir instead of file.
test_xcode_validation "${ROOT}/crates/mmforge-geometry/shim/build" "fail" "directory path rejected"

# ──────────────────────────────────────────────────────────────────────
# Test 5: Fingerprint consistency — shell vs Rust
# ──────────────────────────────────────────────────────────────────────
header "5. Fingerprint consistency: shell == Rust"

SHIM_SRC="${ROOT}/crates/mmforge-geometry/shim"
SHIM_BUILD="${SHIM_SRC}/build"

# Compute shell fingerprint (canonical: sha256 of cat files).
shell_fp=$(cat "${SHIM_SRC}/mmforge_occt_shim.cpp" \
               "${SHIM_SRC}/mmforge_occt_shim.h" \
               "${SHIM_SRC}/CMakeLists.txt" 2>/dev/null \
           | shasum -a 256 | cut -d' ' -f1)

# Read stored fingerprint (written by build.rs or shell script).
if [ -f "${SHIM_BUILD}/.shim_fingerprint" ]; then
    stored_fp=$(cat "${SHIM_BUILD}/.shim_fingerprint")
    assert_eq "5a. shell fingerprint matches stored fingerprint" "$shell_fp" "$stored_fp"
else
    ((FAILED++)) || true
    red "5a. no stored fingerprint at ${SHIM_BUILD}/.shim_fingerprint"
fi

# Verify fingerprint is 64-char hex.
assert_eq "5b. fingerprint is 64-char hex" "64" "${#shell_fp}"

# ──────────────────────────────────────────────────────────────────────
# Test 6: build-occt-shim.sh can be sourced
# ──────────────────────────────────────────────────────────────────────
header "6. Sourced mode: ensure_occt_shim function available"

# Source the script and verify the function is defined.
# shellcheck disable=SC1090
if source "$BUILD_SHIM" 2>/dev/null && declare -f ensure_occt_shim >/dev/null 2>&1; then
    ((PASSED++)) || true
    green "6. ensure_occt_shim function defined after sourcing"
else
    ((FAILED++)) || true
    red "6. sourcing build-occt-shim.sh failed or function not found"
fi

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
printf "Results: \033[32m%d passed\033[0m, " "$PASSED"
if [ "$FAILED" -gt 0 ]; then
    printf "\033[31m%d failed\033[0m\n" "$FAILED"
    echo "Some tests FAILED."
    exit 1
else
    printf "\033[32m0 failed\033[0m\n"
    echo "All tests PASSED."
    exit 0
fi
