#!/bin/bash
# MMForge Release GUI acceptance evidence collector.
#
# This script verifies only what it can observe deterministically:
# process launch, MMForge foreground/window ownership, exact window title,
# window-scoped screenshots, submitted render-mode shortcuts, exported PNG
# existence, and process stability. Viewport content, structure tree contents,
# orbit/pan/zoom, and picking remain manual checks.
set -euo pipefail

if [ "${MMFORGE_ALLOW_INTERACTIVE_GUI:-0}" != "1" ]; then
    cat >&2 <<'EOF'
ERROR: GUI acceptance is an interactive foreground test.

It activates MMForge, sends keyboard shortcuts, drives NSSavePanel, and captures
the MMForge window. Running it will interrupt normal desktop use.

Run it only when the Mac can be dedicated to the acceptance pass:

  MMFORGE_ALLOW_INTERACTIVE_GUI=1 bash scripts/gui-acceptance-test.sh

Silent checks that do not take over the desktop:

  bash macos/scripts/package.sh release
  codesign --verify --deep --strict --verbose=2 macos/build/Build/Products/Release/MMForge.app
  git diff --check
EOF
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${APP:-$ROOT/macos/build/Build/Products/Release/MMForge.app}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/screenshots/2026-07-06}"
EXPORT_DIR="$EVIDENCE_DIR/exports"
RESULT_FILE="$EVIDENCE_DIR/results.txt"
MANIFEST_FILE="$ROOT/docs/progress/2026-07-06-macos-release-gui-acceptance-manifest.txt"

mkdir -p "$EVIDENCE_DIR" "$EXPORT_DIR" "$(dirname "$MANIFEST_FILE")"
rm -f "$EVIDENCE_DIR"/*.png "$EXPORT_DIR"/*.png

{
    echo "# MMForge Release GUI Acceptance Evidence"
    echo "# Date: $(date)"
    echo "# App: $APP"
    echo "# Evidence: $EVIDENCE_DIR"
    echo ""
} > "$RESULT_FILE"

{
    echo "# MMForge Release GUI Acceptance Manifest"
    echo "# Date: $(date)"
    echo "# Screenshots are local/regeneratable and ignored by git."
    echo "# Columns: kind format path bytes width height sha256"
} > "$MANIFEST_FILE"

if [ ! -d "$APP" ]; then
    echo "ERROR: app not found: $APP" >&2
    exit 1
fi

STL_FILE="$ROOT/testdata/stl/box.stl"
LSM_FILE="/tmp/mmforge_gui_acceptance_box.lsm"
LSMC_FILE="/tmp/mmforge_gui_acceptance_box.lsmc"

echo "=== Generating LSM/LSMC test files ==="
rm -f "$LSM_FILE" "$LSMC_FILE"
cargo run --release -p mmforge-cli -- convert "$STL_FILE" -o "$LSM_FILE" >/dev/null
cargo run --release -p mmforge-cli -- convert "$STL_FILE" -o "$LSMC_FILE" --compress zstd >/dev/null
echo "LSM: $(wc -c < "$LSM_FILE") bytes, LSMC: $(wc -c < "$LSMC_FILE") bytes"

record_result() {
    local fmt="$1" check="$2" status="$3" detail="${4:-}"
    printf "%-6s %-28s %-12s %s\n" "$fmt" "$check" "$status" "$detail" >> "$RESULT_FILE"
}

png_width() {
    sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}'
}

png_height() {
    sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}'
}

file_bytes() {
    wc -c < "$1" | tr -d ' '
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

append_manifest() {
    local kind="$1" fmt="$2" path="$3"
    local bytes width height sha
    bytes="$(file_bytes "$path")"
    width="$(png_width "$path")"
    height="$(png_height "$path")"
    sha="$(sha256_file "$path")"
    printf "%-10s %-6s %-72s %10s %6s %6s %s\n" \
        "$kind" "$fmt" "${path#$ROOT/}" "$bytes" "$width" "$height" "$sha" >> "$MANIFEST_FILE"
}

validate_png() {
    local fmt="$1" check="$2" path="$3" min_bytes="${4:-50000}" kind="${5:-screenshot}"
    if [ ! -s "$path" ]; then
        record_result "$fmt" "$check" "FAIL" "missing or empty: ${path#$ROOT/}"
        return 1
    fi

    local bytes width height
    bytes="$(file_bytes "$path")"
    width="$(png_width "$path")"
    height="$(png_height "$path")"

    if [ -z "$width" ] || [ -z "$height" ] || [ "$width" -lt 400 ] || [ "$height" -lt 300 ]; then
        record_result "$fmt" "$check" "FAIL" "invalid dimensions ${width:-?}x${height:-?}"
        return 1
    fi
    if [ "$bytes" -lt "$min_bytes" ]; then
        record_result "$fmt" "$check" "FAIL" "too small: ${bytes} bytes"
        return 1
    fi

    append_manifest "$kind" "$fmt" "$path"
    record_result "$fmt" "$check" "PASS" "${path#$ROOT/} ${width}x${height} ${bytes} bytes"
    return 0
}

get_window_info() {
    local expected="$1"
    osascript - "$expected" <<'APPLESCRIPT'
on run argv
    set expectedTitle to item 1 of argv
    tell application "MMForge" to activate
    delay 0.8
    tell application "System Events"
        if not (exists process "MMForge") then error "MMForge process missing"
        set frontProc to name of first application process whose frontmost is true
        if frontProc is not "MMForge" then error "frontmost process is " & frontProc
        tell process "MMForge"
            if not (exists window expectedTitle) then error "MMForge has no window named " & expectedTitle
            perform action "AXRaise" of window expectedTitle
            set actualTitle to name of window expectedTitle
            if actualTitle is not expectedTitle then error "window title is " & actualTitle & ", expected " & expectedTitle
            set windowPosition to position of window expectedTitle
            set windowSize to size of window expectedTitle
            set x to item 1 of windowPosition
            set y to item 2 of windowPosition
            set w to item 1 of windowSize
            set h to item 2 of windowSize
        end tell
    end tell
    return actualTitle & "|" & x & "|" & y & "|" & w & "|" & h
end run
APPLESCRIPT
}

wait_for_window() {
    local expected="$1"
    local info=""
    local attempts=24
    local i
    for ((i = 1; i <= attempts; i++)); do
        if info="$(get_window_info "$expected" 2>/dev/null)"; then
            echo "$info"
            return 0
        fi
        sleep 0.5
    done
    get_window_info "$expected"
}

capture_window() {
    local fmt="$1" expected="$2" mode="$3" path="$4"
    local info title x y w h
    if ! info="$(wait_for_window "$expected")"; then
        record_result "$fmt" "window_${mode}" "FAIL" "cannot activate/find MMForge window"
        return 1
    fi
    IFS='|' read -r title x y w h <<< "$info"
    if [ "$w" -lt 400 ] || [ "$h" -lt 300 ]; then
        record_result "$fmt" "window_${mode}" "FAIL" "window too small: ${w}x${h}"
        return 1
    fi
    screencapture -x -R"${x},${y},${w},${h}" "$path"
    validate_png "$fmt" "window_${mode}" "$path"
}

record_mode_visual_delta() {
    local fmt="$1" prefix="$2"
    local paths=(
        "$EVIDENCE_DIR/${prefix}-1-solid.png"
        "$EVIDENCE_DIR/${prefix}-2-wireframe.png"
        "$EVIDENCE_DIR/${prefix}-3-solidwire.png"
        "$EVIDENCE_DIR/${prefix}-4-xray.png"
    )
    local path
    for path in "${paths[@]}"; do
        if [ ! -s "$path" ]; then
            record_result "$fmt" "render_mode_visual_delta" "UNVERIFIED" "missing mode screenshot: ${path#$ROOT/}"
            return 0
        fi
    done

    local unique_hashes
    unique_hashes="$(for path in "${paths[@]}"; do sha256_file "$path"; done | sort -u | wc -l | tr -d ' ')"
    if [ "$unique_hashes" -gt 1 ]; then
        record_result "$fmt" "render_mode_visual_delta" "PASS" "unique screenshot hashes: $unique_hashes"
    else
        record_result "$fmt" "render_mode_visual_delta" "UNVERIFIED" "mode screenshot hashes identical; manual visual check required"
    fi
}

send_mmforge_shortcut() {
    local key="$1"
    osascript - "$key" <<'APPLESCRIPT'
on run argv
    set shortcutKey to item 1 of argv
    tell application "System Events"
        repeat with i from 1 to 10
            tell application "MMForge" to activate
            delay 0.3
            set frontProc to name of first application process whose frontmost is true
            if frontProc is "MMForge" then exit repeat
        end repeat
        set frontProc to name of first application process whose frontmost is true
        if frontProc is not "MMForge" then error "frontmost process is " & frontProc
        keystroke shortcutKey using command down
    end tell
end run
APPLESCRIPT
}

export_image() {
    local fmt="$1" expected="$2" prefix="$3"
    local export_path="$EXPORT_DIR/${prefix}-export.png"
    rm -f "$export_path"

    if ! osascript - "$EXPORT_DIR" "$(basename "$export_path")" <<'APPLESCRIPT'
on run argv
    set exportDir to item 1 of argv
    set exportName to item 2 of argv
    tell application "System Events"
        repeat 10 times
            key code 53
            delay 0.1
        end repeat
        repeat with i from 1 to 10
            tell application "MMForge" to activate
            delay 0.3
            set frontProc to name of first application process whose frontmost is true
            if frontProc is "MMForge" then exit repeat
        end repeat
        set frontProc to name of first application process whose frontmost is true
        if frontProc is not "MMForge" then error "frontmost process is " & frontProc
        keystroke "e" using command down
        repeat with i from 1 to 30
            delay 0.3
            tell process "MMForge"
                if exists window "Export Image" then exit repeat
            end tell
        end repeat
        tell process "MMForge"
            if not (exists window "Export Image") then error "Export Image panel did not appear"
        end tell
        keystroke "g" using {command down, shift down}
        delay 0.4
        set the clipboard to exportDir
        keystroke "v" using command down
        keystroke return
        delay 0.8
        set the clipboard to exportName
        keystroke "a" using command down
        keystroke "v" using command down
        delay 0.2
        keystroke return
        delay 1.5
        -- If a replace confirmation appears, accept it.
        try
            keystroke return
            delay 0.5
        end try
    end tell
end run
APPLESCRIPT
    then
        record_result "$fmt" "export_png" "FAIL" "automation failed"
        return 1
    fi

    validate_png "$fmt" "export_png" "$export_path" 1000 "export"
}

open_document() {
    local file="$1"
    local attempt
    for ((attempt = 1; attempt <= 3; attempt++)); do
        if open -a "$APP" "$file" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    open -n -a "$APP" "$file" >/dev/null 2>&1
}

test_format() {
    local fmt="$1" file="$2" prefix="$3"
    local expected
    expected="$(basename "$file")"

    echo ""
    echo "========================================"
    echo "  Testing: $fmt - $file"
    echo "========================================"

    if ! open_document "$file"; then
        record_result "$fmt" "open_document" "FAIL" "LaunchServices could not open $file"
        return 1
    fi

    if pgrep -x MMForge >/dev/null 2>&1; then
        record_result "$fmt" "launch_process" "PASS" "process exists"
    else
        record_result "$fmt" "launch_process" "FAIL" "app not running"
        return 1
    fi

    local info title x y w h
    if info="$(wait_for_window "$expected")"; then
        IFS='|' read -r title x y w h <<< "$info"
        record_result "$fmt" "frontmost_window_title" "PASS" "$title ${w}x${h}"
    else
        record_result "$fmt" "frontmost_window_title" "FAIL" "expected $expected"
        return 1
    fi

    capture_window "$fmt" "$expected" "solid" "$EVIDENCE_DIR/${prefix}-1-solid.png" || true

    if send_mmforge_shortcut "2"; then
        sleep 0.8
        record_result "$fmt" "shortcut_cmd_2" "PASS" "sent to MMForge"
    else
        record_result "$fmt" "shortcut_cmd_2" "FAIL" "MMForge was not frontmost"
    fi
    capture_window "$fmt" "$expected" "wireframe" "$EVIDENCE_DIR/${prefix}-2-wireframe.png" || true

    if send_mmforge_shortcut "3"; then
        sleep 0.8
        record_result "$fmt" "shortcut_cmd_3" "PASS" "sent to MMForge"
    else
        record_result "$fmt" "shortcut_cmd_3" "FAIL" "MMForge was not frontmost"
    fi
    capture_window "$fmt" "$expected" "solidwire" "$EVIDENCE_DIR/${prefix}-3-solidwire.png" || true

    if send_mmforge_shortcut "4"; then
        sleep 0.8
        record_result "$fmt" "shortcut_cmd_4" "PASS" "sent to MMForge"
    else
        record_result "$fmt" "shortcut_cmd_4" "FAIL" "MMForge was not frontmost"
    fi
    capture_window "$fmt" "$expected" "xray" "$EVIDENCE_DIR/${prefix}-4-xray.png" || true
    record_mode_visual_delta "$fmt" "$prefix"

    if send_mmforge_shortcut "1"; then
        sleep 0.5
        record_result "$fmt" "shortcut_cmd_1" "PASS" "sent to MMForge"
    else
        record_result "$fmt" "shortcut_cmd_1" "FAIL" "MMForge was not frontmost"
    fi

    export_image "$fmt" "$expected" "$prefix" || true

    if pgrep -x MMForge >/dev/null 2>&1; then
        record_result "$fmt" "final_process" "PASS" "app still running"
    else
        record_result "$fmt" "final_process" "FAIL" "app exited"
    fi

    echo "Done testing: $fmt"
}

killall MMForge 2>/dev/null || true
for ((startup_wait = 1; startup_wait <= 20; startup_wait++)); do
    if ! pgrep -x MMForge >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

test_format "STL"  "$ROOT/testdata/stl/box.stl" "stl"
test_format "glTF" "$ROOT/testdata/gltf/box.gltf" "gltf"
test_format "GLB"  "$ROOT/testdata/gltf/box.glb" "glb"
test_format "DXF"  "$ROOT/crates/mmforge-format-dxf/testdata/test.dxf" "dxf"
test_format "STEP" "$ROOT/crates/mmforge-geometry/testdata/PQ-04909-A.STEP" "step"
test_format "IGES" "$ROOT/crates/mmforge-geometry/testdata/box.igs" "iges"
test_format "LSM"  "$LSM_FILE" "lsm"
test_format "LSMC" "$LSMC_FILE" "lsmc"

echo "" >> "$RESULT_FILE"
echo "---" >> "$RESULT_FILE"

PASS_COUNT=$(awk '$3 == "PASS" {count++} END {print count+0}' "$RESULT_FILE")
FAIL_COUNT=$(awk '$3 == "FAIL" {count++} END {print count+0}' "$RESULT_FILE")
UNVERIFIED_COUNT=$(awk '$3 == "UNVERIFIED" {count++} END {print count+0}' "$RESULT_FILE")
PNG_COUNT=$(find "$EVIDENCE_DIR" -type f -name '*.png' | wc -l | tr -d ' ')

{
    echo "Automated PASS lines: $PASS_COUNT"
    echo "Automated FAIL lines: $FAIL_COUNT"
    echo "Automated UNVERIFIED lines: $UNVERIFIED_COUNT"
    echo "PNG evidence files: $PNG_COUNT"
    echo "Manifest: $MANIFEST_FILE"
    echo ""
    echo "Manual still required: viewport content, structure tree, orbit/pan/zoom, picking, exported image semantic correctness."
} >> "$RESULT_FILE"

echo ""
echo "========================================"
echo "GUI evidence collection complete."
echo "Results : $RESULT_FILE"
echo "Manifest: $MANIFEST_FILE"
cat "$RESULT_FILE"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
