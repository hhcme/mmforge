#!/bin/bash
# MMForge preflight check — silent, non-GUI verification script.
#
# Runs package/codesign/otool/diff-check validations suitable for CI,
# pre-commit hooks, or deterministic pre-release gate checking.
# Does not launch the app, open windows, or require a display.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULT=0

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
bold()   { printf '\033[1m%s\033[0m\n' "$*" >&2; }

bold "=== MMForge Preflight Check ==="
echo "ROOT: $ROOT"
echo ""

# ---------------------------------------------------------------------------
# 1. Rust static checks
# ---------------------------------------------------------------------------
bold "1. Rust static checks"
echo -n "  cargo fmt --check ... "
if cargo fmt --all --check 2>/dev/null; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

echo -n "  cargo clippy ... "
if cargo clippy --workspace -- -D warnings 2>/dev/null; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 2. Rust tests
# ---------------------------------------------------------------------------
bold "2. Rust tests"
echo -n "  cargo test --workspace ... "
if cargo test --workspace 2>&1 | tail -5; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 3. Swift tests (Xcode, headless)
# ---------------------------------------------------------------------------
bold "3. Swift tests (Xcode headless)"
XCODE_PROJECT="$ROOT/macos/MMForge.xcodeproj"
XCODE_RESULT_BUNDLE="$ROOT/macos/build/PreflightTests.xcresult"
rm -rf "$XCODE_RESULT_BUNDLE" 2>/dev/null || true

echo -n "  xcodebuild test ... "
if xcodebuild test \
    -project "$XCODE_PROJECT" \
    -scheme MMForge \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/macos/build" \
    -resultBundlePath "$XCODE_RESULT_BUNDLE" \
    2>&1 | tail -5; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 4. Package build (Release + DMG)
# ---------------------------------------------------------------------------
bold "4. Package build"
RELEASE_APP="$ROOT/macos/build/Build/Products/Release/MMForge.app"

echo -n "  package.sh release ... "
if bash "$ROOT/macos/scripts/package.sh" release; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

echo -n "  package.sh dmg ... "
if bash "$ROOT/macos/scripts/package.sh" dmg; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 5. Code signature verification
# ---------------------------------------------------------------------------
bold "5. Code signature"

if [ -d "$RELEASE_APP" ]; then
    echo -n "  codesign --verify --deep --strict ... "
    if codesign --verify --deep --strict --verbose=2 "$RELEASE_APP" 2>&1; then
        green "PASS"
    else
        red "FAIL"
        RESULT=1
    fi

    echo -n "  codesign -dvv (status) ... "
    SIG_STATUS=$(codesign -dvv "$RELEASE_APP" 2>&1 || true)
    if echo "$SIG_STATUS" | grep -q "Signature=adhoc"; then
        green "PASS (adhoc)"
    elif echo "$SIG_STATUS" | grep -q "Signature="; then
        green "PASS (signed)"
    else
        red "FAIL (unsigned or unknown)"
        RESULT=1
    fi
else
    red "SKIP — Release .app not found at $RELEASE_APP"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 6. otool -L dependency audit
# ---------------------------------------------------------------------------
bold "6. otool -L dependency audit"

if [ -d "$RELEASE_APP" ]; then
    APP_BIN="$RELEASE_APP/Contents/MacOS/MMForge"
    FRAMEWORKS_DIR="$RELEASE_APP/Contents/Frameworks"

    if [ -f "$APP_BIN" ]; then
        echo -n "  Homebrew refs in main binary ... "
        HB_REFS=$(otool -L "$APP_BIN" 2>/dev/null | grep -cE '/opt/homebrew|/usr/local/Cellar' || true)
        if [ "$HB_REFS" -eq 0 ]; then
            green "PASS (0 Homebrew refs)"
        else
            red "FAIL ($HB_REFS Homebrew refs found)"
            RESULT=1
        fi
    fi

    if [ -d "$FRAMEWORKS_DIR" ]; then
        echo -n "  Bundled dylib count ... "
        DYLIB_COUNT=$(ls "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
        echo "$DYLIB_COUNT dylibs"

        echo -n "  Homebrew refs in bundled dylibs ... "
        HB_DYLIB_REFS=$(otool -L "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | grep -cE '/opt/homebrew|/usr/local/Cellar' || true)
        if [ "$HB_DYLIB_REFS" -eq 0 ]; then
            green "PASS (0 Homebrew refs)"
        else
            red "FAIL ($HB_DYLIB_REFS Homebrew refs found in dylibs)"
            RESULT=1
        fi

        echo -n "  Missing @rpath deps (fatal) ... "
        MISSING=0
        for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
            for dep in $(otool -L "$dylib" 2>/dev/null | awk '/@rpath\// {print $1}'); do
                dep_name="${dep#@rpath/}"
                if [ ! -f "$FRAMEWORKS_DIR/$dep_name" ] && [ ! -f "$FRAMEWORKS_DIR/$(basename "$dep_name")" ]; then
                    echo "  MISSING: $dep (from $dylib)"
                    MISSING=$((MISSING + 1))
                fi
            done
        done
        if [ "$MISSING" -eq 0 ]; then
            green "PASS (all @rpath deps satisfied)"
        else
            red "FAIL ($MISSING missing @rpath dependencies)"
            RESULT=1
        fi
    else
        echo "  SKIP — Frameworks directory not found (no OCCT bundled)"
    fi
else
    red "SKIP — Release .app not found"
fi

# ---------------------------------------------------------------------------
# 7. Native arch check
# ---------------------------------------------------------------------------
bold "7. Architecture verification"

if [ -f "$APP_BIN" ]; then
    echo -n "  Host arch ... "
    HOST_ARCH=$(uname -m)
    echo "$HOST_ARCH"

    echo -n "  Binary arch ... "
    BIN_ARCH=$(file "$APP_BIN" 2>/dev/null | grep -o 'arm64\|x86_64')
    if [ "$BIN_ARCH" = "$HOST_ARCH" ]; then
        green "PASS ($BIN_ARCH matches host)"
    else
        echo "Binary: $BIN_ARCH, Host: $HOST_ARCH"
        red "FAIL (arch mismatch)"
        RESULT=1
    fi
fi

# ---------------------------------------------------------------------------
# 8. DMG integrity check
# ---------------------------------------------------------------------------
bold "8. DMG integrity"
DMG_PATH="$ROOT/macos/build/MMForge-0.1.0-alpha.dmg"

if [ -f "$DMG_PATH" ]; then
    echo -n "  DMG exists: $DMG_PATH ... "
    DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
    echo "$DMG_SIZE"

    echo -n "  hdiutil verify ... "
    if hdiutil verify "$DMG_PATH" >/dev/null 2>&1; then
        green "PASS"
    else
        red "FAIL"
        RESULT=1
    fi
else
    echo "  SKIP — DMG not found"
fi

# ---------------------------------------------------------------------------
# 9. git diff whitespace check
# ---------------------------------------------------------------------------
bold "9. git diff whitespace check"
echo -n "  git diff --check ... "
if git -C "$ROOT" diff --check; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

echo -n "  git diff --check --staged ... "
if git -C "$ROOT" diff --check --staged; then
    green "PASS"
else
    red "FAIL"
    RESULT=1
fi

# ---------------------------------------------------------------------------
# 10. perf-baseline (CLI geometry evidence, no GUI)
#
# Exit codes from perf-baseline.sh:
#   0 = PASS — all formats REAL-GEOMETRY or 2D-ONLY
#   1 = FAIL — hard ERROR (any format)
#   2 = FAIL — PLACEHOLDER (empty model)
#   3 = ADVISORY — STEP/IGES no-OCCT downgraded (MMFORGE_NO_OCCT_ADVISORY=1);
#       no non-OCCT ERROR, no PLACEHOLDER
#
# MMFORGE_ALLOW_NO_OCCT=1 enables advisory downgrade for STEP/IGES only.
# STL/glTF/DXF ERROR or any PLACEHOLDER always hard-fails (exit 1/2).
# ---------------------------------------------------------------------------
bold "10. CLI format geometry baseline"

ADVISORY_NO_OCCT="${MMFORGE_ALLOW_NO_OCCT:-0}"
PERF_OUTPUT="$ROOT/macos/build/.preflight-perf-baseline.log"
mkdir -p "$(dirname "$PERF_OUTPUT")"
GEOMETRY_ADVISORY=0

echo -n "  perf-baseline.sh ... "
set +e
MMFORGE_NO_OCCT_ADVISORY="$ADVISORY_NO_OCCT" \
  bash "$ROOT/docs/scripts/perf-baseline.sh" >"$PERF_OUTPUT" 2>&1
PERF_RC=$?
set -e

# Parse summary table to extract problematic format names
PERF_ERROR_FORMATS=$(awk -F'|' '/^[|] (STEP|IGES|STL|glTF|DXF)/ && /ERROR/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); printf " %s", $2}' "$PERF_OUTPUT" 2>/dev/null || true)
PERF_PLACEHOLDER_FORMATS=$(awk -F'|' '/^[|] (STEP|IGES|STL|glTF|DXF)/ && /PLACEHOLDER/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); printf " %s", $2}' "$PERF_OUTPUT" 2>/dev/null || true)

case "$PERF_RC" in
  0)
    green "PASS (all formats REAL-GEOMETRY or 2D-ONLY)"
    ;;
  1)
    red "FAIL — geometry ERROR:${PERF_ERROR_FORMATS}"
    echo "    (Set MMFORGE_ALLOW_NO_OCCT=1 to accept STEP/IGES no-OCCT as advisory)"
    RESULT=1
    ;;
  2)
    red "FAIL — geometry PLACEHOLDER:${PERF_PLACEHOLDER_FORMATS}"
    echo "    (Parser returned empty model — format not wired or feature missing)"
    RESULT=1
    ;;
  3)
    yellow "ADVISORY — STEP/IGES geometry NOT verified (no OpenCASCADE)"
    echo "    Only STL, glTF, and DXF geometry is fully verified."
    echo "    STEP and IGES require OpenCASCADE for complete geometry verification."
    GEOMETRY_ADVISORY=1
    ;;
  *)
    red "FAIL — perf-baseline exited $PERF_RC"
    RESULT=1
    ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
bold "=== Summary ==="
if [ "$RESULT" -eq 0 ] && [ "$GEOMETRY_ADVISORY" -eq 0 ]; then
    green "Preflight: ALL CHECKS PASSED"
elif [ "$RESULT" -eq 0 ] && [ "$GEOMETRY_ADVISORY" -eq 1 ]; then
    yellow "Preflight: PASS WITH ADVISORY"
    yellow "  STEP/IGES geometry NOT verified (requires OpenCASCADE)."
    yellow "  STL, glTF, DXF geometry fully verified."
else
    red "Preflight: SOME CHECKS FAILED (exit code $RESULT)"
fi

exit $RESULT
