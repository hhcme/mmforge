#!/bin/bash
# fresh-debug-build.sh — Non-GUI fresh Debug build + manifest for acceptance.
#
# Builds macos/build/Build/Products/Debug/MMForge.app from clean state,
# records commit SHA, executable hash, and artifact paths into a manifest.
# Does NOT launch the app or require a display.
#
# Usage:
#   bash macos/scripts/fresh-debug-build.sh
#
# Output:
#   macos/build/Build/Products/Debug/MMForge.app
#   macos/build/.build-manifest.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT/macos/build"
MANIFEST="$BUILD_DIR/.build-manifest.json"

echo "=== Fresh Debug Build ==="
echo "ROOT: $ROOT"

# ── Gather metadata ───────────────────────────────────────────────────
COMMIT_SHA=$(git -C "$ROOT" rev-parse HEAD)
COMMIT_SHORT=$(git -C "$ROOT" rev-parse --short HEAD)
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOST=$(hostname)
XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1 || echo "unknown")

echo "  commit: $COMMIT_SHORT"
echo "  date:   $BUILD_DATE"
echo "  xcode:  $XCODE_VER"

# ── Clean build artifacts ─────────────────────────────────────────────
echo "  cleaning macos/build/ ..."
rm -rf "$BUILD_DIR/Build" "$BUILD_DIR/Logs" "$BUILD_DIR/ModuleCache.noindex" \
       "$BUILD_DIR/Index.noindex" "$BUILD_DIR/SDKStatCaches.noindex" \
       "$BUILD_DIR/*.xcresult" 2>/dev/null || true

# ── Build Rust bridge ──────────────────────────────────────────────────
echo "=== Building Rust bridge (release) ==="
OCCT_INCL="${OCCT_INCLUDE_DIR:-/opt/homebrew/include/opencascade}"
OCCT_LIB="${OCCT_LIB_DIR:-/opt/homebrew/lib}"

cd "$ROOT"
if [ -d "$OCCT_INCL" ] && [ -d "$OCCT_LIB" ]; then
    echo "  OCCT configured — building shim + bridge with OCCT"
    export OCCT_INCLUDE_DIR="$OCCT_INCL" OCCT_LIB_DIR="$OCCT_LIB"
    export CARGO_MANIFEST_DIR="$ROOT/crates/mmforge-geometry"
    SHIM_PATH=$(bash "$ROOT/macos/scripts/build-occt-shim.sh")
    export MMFORGE_SHIM_DIR="$(dirname "$SHIM_PATH")"
    cargo build --release -p mmforge-bridge --features occt
else
    cargo build --release -p mmforge-bridge
fi
echo "  Rust bridge built."

# ── Build Xcode Debug .app ─────────────────────────────────────────────
echo "=== Building Xcode Debug .app ==="
cd "$ROOT/macos"
xcodebuild \
    -project MMForge.xcodeproj \
    -scheme MMForge \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | grep -E "BUILD|error:|warning:" | tail -5

APP_PATH="$BUILD_DIR/Build/Products/Debug/MMForge.app"
if [ ! -d "$APP_PATH" ]; then
    echo "FATAL: Build did not produce $APP_PATH" >&2
    exit 1
fi

APP_BIN="$APP_PATH/Contents/MacOS/MMForge"
APP_HASH=$(shasum -a 256 "$APP_BIN" 2>/dev/null | cut -d' ' -f1)
APP_SIZE=$(du -sh "$APP_PATH" 2>/dev/null | cut -f1)

echo "  App:  $APP_PATH"
echo "  Size: $APP_SIZE"
echo "  Hash: $APP_HASH"

# ── Write manifest ─────────────────────────────────────────────────────
mkdir -p "$BUILD_DIR"
cat > "$MANIFEST" <<EOF
{
  "commit_sha": "$COMMIT_SHA",
  "commit_short": "$COMMIT_SHORT",
  "build_date_utc": "$BUILD_DATE",
  "host": "$HOST",
  "xcode": "$XCODE_VER",
  "app_path": "$APP_PATH",
  "app_size": "$APP_SIZE",
  "app_binary_sha256": "$APP_HASH",
  "build_type": "Debug",
  "occt_configured": $([ -d "$OCCT_INCL" ] && [ -d "$OCCT_LIB" ] && echo "true" || echo "false")
}
EOF

echo "=== Build Complete ==="
echo "Manifest: $MANIFEST"
echo "App:      $APP_PATH"
