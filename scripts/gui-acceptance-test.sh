#!/bin/bash
# MMForge Release GUI Acceptance Test — 2026-07-06
# Automated screenshot + interaction test for all 8 formats.
set -euo pipefail

ROOT="/Volumes/hhcStorage/hhc_project/mmforge"
APP="${ROOT}/macos/build/Build/Products/Release/MMForge.app"
SCREENSHOTS="${ROOT}/docs/screenshots/2026-07-06"
mkdir -p "${SCREENSHOTS}"

RESULT_FILE="${ROOT}/docs/screenshots/2026-07-06/results.txt"
echo "# MMForge Release GUI Acceptance — $(date)" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Generate LSM/LSMC test files from STL box
STL_FILE="${ROOT}/testdata/stl/box.stl"
LSM_FILE="/tmp/test_box.lsm"
LSMC_FILE="/tmp/test_box.lsmc"

echo "=== Generating LSM/LSMC test files ==="
cargo run --release -p mmforge-cli -- convert "$STL_FILE" -o "$LSM_FILE" 2>/dev/null
cargo run --release -p mmforge-cli -- convert "$STL_FILE" -o "$LSMC_FILE" --compress zstd 2>/dev/null
echo "LSM: $(wc -c < $LSM_FILE) bytes, LSMC: $(wc -c < $LSMC_FILE) bytes"

record_result() {
    local fmt="$1" check="$2" status="$3" detail="${4:-}"
    printf "%-6s %-22s %-8s %s\n" "$fmt" "$check" "$status" "$detail" >> "$RESULT_FILE"
}

test_format() {
    local FORMAT="$1" FILE="$2" PREFIX="$3" IS_2D="$4"

    echo ""
    echo "========================================"
    echo "  Testing: $FORMAT — $FILE"
    echo "========================================"

    killall MMForge 2>/dev/null || true
    sleep 1

    # Launch
    open -a "$APP" "$FILE"
    sleep 5

    # Check process alive
    if pgrep -q MMForge; then
        record_result "$FORMAT" "launch" "PASS"
    else
        record_result "$FORMAT" "launch" "FAIL" "app not running after 5s"
        return
    fi

    # Window title should be the filename
    local EXPECTED_FILE
    EXPECTED_FILE=$(basename "$FILE")
    TITLE=$(osascript -e 'tell application "System Events" to get name of window 1 of process "MMForge"' 2>/dev/null || echo "NONE")
    if [ "$TITLE" = "$EXPECTED_FILE" ]; then
        record_result "$FORMAT" "window_title" "PASS" "$TITLE"
    else
        record_result "$FORMAT" "window_title" "FAIL" "got='$TITLE' expected='$EXPECTED_FILE'"
    fi

    # Screenshot: default render mode (solid)
    screencapture -T 2 "${SCREENSHOTS}/${PREFIX}-1-solid.png" 2>/dev/null
    record_result "$FORMAT" "screenshot_solid" "CAPTURED"

    # Cmd+2 wireframe
    osascript -e 'tell application "System Events" to keystroke "2" using command down' 2>/dev/null
    sleep 1
    screencapture -T 2 "${SCREENSHOTS}/${PREFIX}-2-wireframe.png" 2>/dev/null
    record_result "$FORMAT" "screenshot_wire" "CAPTURED"

    # Cmd+3 solid+wire
    osascript -e 'tell application "System Events" to keystroke "3" using command down' 2>/dev/null
    sleep 1
    screencapture -T 2 "${SCREENSHOTS}/${PREFIX}-3-solidwire.png" 2>/dev/null
    record_result "$FORMAT" "screenshot_solidwire" "CAPTURED"

    # Cmd+4 x-ray
    osascript -e 'tell application "System Events" to keystroke "4" using command down' 2>/dev/null
    sleep 1
    screencapture -T 2 "${SCREENSHOTS}/${PREFIX}-4-xray.png" 2>/dev/null
    record_result "$FORMAT" "screenshot_xray" "CAPTURED"

    # Back to solid (Cmd+1)
    osascript -e 'tell application "System Events" to keystroke "1" using command down' 2>/dev/null
    sleep 1

    # Export Image test (Cmd+E)
    osascript -e 'tell application "System Events" to keystroke "e" using command down' 2>/dev/null
    sleep 2
    # Press Enter to accept default save location, or Escape to cancel
    osascript -e 'tell application "System Events" to keystroke return' 2>/dev/null
    sleep 2
    record_result "$FORMAT" "export_image" "SUBMITTED" "Cmd+E → Return"

    # Screenshot after export dialog
    screencapture -T 2 "${SCREENSHOTS}/${PREFIX}-5-export.png" 2>/dev/null

    # Final app state
    if pgrep -q MMForge; then
        record_result "$FORMAT" "final_state" "RUNNING" "app still running after tests"
    else
        record_result "$FORMAT" "final_state" "EXITED"
    fi

    echo "Done testing: $FORMAT"
}

# ─── Test all 8 formats ───
test_format "STL"   "${ROOT}/testdata/stl/box.stl"                         "stl"   0
test_format "glTF"  "${ROOT}/testdata/gltf/box.gltf"                       "gltf"  0
test_format "GLB"   "${ROOT}/testdata/gltf/box.glb"                        "glb"   0
test_format "DXF"   "${ROOT}/crates/mmforge-format-dxf/testdata/test.dxf"  "dxf"   1
test_format "STEP"  "${ROOT}/crates/mmforge-geometry/testdata/PQ-04909-A.STEP" "step" 0
test_format "IGES"  "${ROOT}/crates/mmforge-geometry/testdata/box.igs"     "iges"  0
test_format "LSM"   "$LSM_FILE"                                            "lsm"   0
test_format "LSMC"  "$LSMC_FILE"                                           "lsmc"  0

# ─── Summary ───
echo "" >> "$RESULT_FILE"
echo "---" >> "$RESULT_FILE"

# Count passes/fails/captures
PASSES=$(grep -c "PASS\|CAPTURED\|SUBMITTED\|RUNNING" "$RESULT_FILE" 2>/dev/null || echo 0)
FAILS=$(grep -c "FAIL" "$RESULT_FILE" 2>/dev/null || echo 0)

echo "Total lines with PASS/CAPTURED/SUBMITTED/RUNNING: $PASSES" >> "$RESULT_FILE"
echo "Total FAIL lines: $FAILS" >> "$RESULT_FILE"

echo ""
echo "========================================"
echo "GUI Acceptance complete."
echo "Results: ${ROOT}/docs/screenshots/2026-07-06/results.txt"
cat "$RESULT_FILE"
