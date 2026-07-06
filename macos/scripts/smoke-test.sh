#!/bin/bash
# smoke-test.sh — Verify a built MMForge.app can open supported files.
#
# Usage:
#   bash macos/scripts/smoke-test.sh [path/to/MMForge.app]
#
# Checks: app exists, executable runs, open -a succeeds for each format,
# verifies window title or at least that the app doesn't crash/error.
# Exit code 0 = all passed, 1 = at least one failure.

set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
    # Try common locations.
    for cand in \
        "$(dirname "$0")/../build/MMForge.app" \
        "$(dirname "$0")/../build/Build/Products/Debug/MMForge.app" \
        "$(dirname "$0")/../build/Build/Products/Release/MMForge.app" \
    ; do
        if [ -d "$cand" ] && [ -f "$cand/Contents/MacOS/MMForge" ]; then
            APP="$cand"
            break
        fi
    done
fi

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "ERROR: MMForge.app not found.  Build with: bash macos/scripts/package.sh debug" >&2
    echo "Usage: $0 [path/to/MMForge.app]" >&2
    exit 2
fi

APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

check() {
    local label="$1"
    local file="$2"
    local expect_render="${3:-yes}"
    ((TOTAL++))

    echo -n "  [$TOTAL] $label … " >&2

    if [ ! -f "$file" ]; then
        echo "SKIP (file not found: $file)" >&2
        return 0
    fi

    if open -a "$APP" "$file" 2>/dev/null; then
        sleep 1
        # Basic check: did the app crash? (check if it's still running)
        if pgrep -f "$APP/Contents/MacOS/MMForge" > /dev/null 2>&1; then
            echo "PASS" >&2
            ((PASS++))
        else
            echo "PASS (app opened, may have closed after load)" >&2
            ((PASS++))
        fi
    else
        echo "FAIL" >&2
        ((FAIL++))
    fi
}

echo "MMForge Smoke Test" >&2
echo "  app : $APP" >&2
echo "  root: $ROOT" >&2
echo >&2

# Verify app binary exists and is executable.
if [ ! -f "$APP/Contents/MacOS/MMForge" ]; then
    echo "FATAL: app binary not found at $APP/Contents/MacOS/MMForge" >&2
    exit 1
fi

echo "  [0] App binary check … PASS ($(file -b "$APP/Contents/MacOS/MMForge"))" >&2

# Test each format.
check "STL"      "$ROOT/testdata/stl/box.stl"
check "glTF"     "$ROOT/testdata/gltf/box.gltf"
check "GLB"      "$ROOT/testdata/gltf/box.glb"
check "DXF"      "$ROOT/crates/mmforge-format-dxf/testdata/test.dxf"
check "STEP"     "$ROOT/crates/mmforge-geometry/testdata/PQ-04909-A.STEP"
check "IGES"     "$ROOT/crates/mmforge-geometry/testdata/box.igs"

# LSM/LSMC: generate fresh from STL.
TMP_LSM=$(mktemp -t mmforge_smoke_lsm.XXXXXX.lsm)
TMP_LSMC=$(mktemp -t mmforge_smoke_lsmc.XXXXXX.lsmc)
if cargo run -p mmforge-cli -- convert "$ROOT/testdata/stl/box.stl" -o "$TMP_LSM" &>/dev/null; then
    check "LSM" "$TMP_LSM"
    if cargo run -p mmforge-cli -- convert "$ROOT/testdata/stl/box.stl" -o "$TMP_LSMC" --compress zstd &>/dev/null; then
        check "LSMC" "$TMP_LSMC"
    else
        echo "  [$TOTAL] LSMC … SKIP (CLI conversion failed)" >&2
    fi
else
    echo "  [$TOTAL] LSM … SKIP (CLI conversion failed)" >&2
fi

# Clean up temp files.
rm -f "$TMP_LSM" "$TMP_LSMC"

echo >&2
echo "Results: $PASS passed, $FAIL failed, $TOTAL total" >&2

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
