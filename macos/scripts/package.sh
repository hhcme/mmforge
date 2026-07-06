#!/bin/bash
# package.sh — Build and package MMForge macOS app into a .dmg.
#
# Usage:
#   ./package.sh debug    → Debug build (no code signing), .app symlink
#   ./package.sh release  → Release build, produce unsigned .dmg
#   ./package.sh dmg      → (default) Release build + DMG
#
# Prerequisites:
#   - Xcode 26+ (with macOS 26 SDK)
#   - Rust toolchain (rustup, cargo)
#   - OCCT libraries if building with OCCT (see OCCT SHIM section below)
#
# Output:
#   macos/build/Release/MMForge.app        (standalone .app)
#   macos/build/MMForge-0.1.0-alpha.dmg    (disk image, Release only)

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-dmg}"
APP_NAME="MMForge"
VERSION="0.1.0"
DMG_NAME="${APP_NAME}-${VERSION}-alpha"
IDENTIFIER="com.mmforge.app"
PROJECT="MMForge.xcodeproj"
SCHEME="MMForge"
BUILD_DIR="$(pwd)/build"

# ── Rust Bridge ──────────────────────────────────────────────────────

build_rust() {
    local features=""
    if [ -n "${OCCT_INCLUDE_DIR:-}" ] && [ -n "${OCCT_LIB_DIR:-}" ]; then
        echo "  [rust] Building with OCCT support"
        features="--features occt"
    else
        echo "  [rust] Building without OCCT (STEP/IGES will show guidance)"
    fi

    cargo build --release -p mmforge-bridge ${features}

    local src="$(pwd)/../target/release/libmmforge_bridge.a"
    if [ -f "$src" ]; then
        cp "$src" "$BUILD_DIR/Products/Release/"
        echo "  [rust] → $BUILD_DIR/Products/Release/libmmforge_bridge.a"
    else
        echo "  [rust] ERROR: libmmforge_bridge.a not found at $src"
        exit 1
    fi
}

# ── Build ─────────────────────────────────────────────────────────────

build_app() {
    local config="$1"
    local archive_flag=""
    local code_sign_flag="CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"

    echo "==> Building $APP_NAME ($config) …"

    mkdir -p "$BUILD_DIR/Products/$config"

    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$config" \
        -derivedDataPath "$BUILD_DIR" \
        -destination 'platform=macOS' \
        ${code_sign_flag} \
        build

    local app_path="$BUILD_DIR/Build/Products/$config/$APP_NAME.app"
    if [ ! -d "$app_path" ]; then
        echo "ERROR: Build did not produce $app_path"
        exit 1
    fi

    echo "  [ok] $app_path"
    echo "$app_path"
}

# ── Symlink (Debug only) ──────────────────────────────────────────────

symlink_app() {
    local app_path="$1"
    local link_path="$BUILD_DIR/$APP_NAME.app"
    rm -f "$link_path"
    ln -s "$app_path" "$link_path"
    echo "  [symlink] $link_path → $app_path"
}

# ── DMG ───────────────────────────────────────────────────────────────

create_dmg() {
    local app_path="$1"
    local dmg_path="$BUILD_DIR/${DMG_NAME}.dmg"
    local staging="$BUILD_DIR/dmg_staging"

    echo "==> Creating DMG …"

    rm -rf "$staging" "$dmg_path"
    mkdir -p "$staging"
    cp -R "$app_path" "$staging/"

    # Create a symlink to /Applications for drag-to-install.
    ln -s /Applications "$staging/Applications"

    hdiutil create \
        -volname "$DMG_NAME" \
        -srcfolder "$staging" \
        -ov -format UDZO \
        "$dmg_path"

    rm -rf "$staging"

    echo "  [ok] $dmg_path"
    echo
    echo "  DMG size: $(du -sh "$dmg_path" | cut -f1)"
    echo
    echo "  To install: open $dmg_path"

    echo "$dmg_path"
}

# ── Main ──────────────────────────────────────────────────────────────

echo "MMForge macOS Packaging"
echo "  version : $VERSION"
echo "  config  : $CONFIG"
echo

case "$CONFIG" in
    debug)
        APP_PATH=$(build_app "Debug")
        symlink_app "$APP_PATH"
        echo
        echo "Debug build complete."
        echo "Run: open $APP_PATH"
        ;;
    release)
        build_rust
        APP_PATH=$(build_app "Release")
        echo
        echo "Release build complete."
        echo "App: $APP_PATH"
        echo
        echo "── Signing / Notarization ──"
        echo "This build is UNSIGNED. To sign for distribution:"
        echo "  1. Set DEVELOPMENT_TEAM in the Xcode project"
        echo "  2. Add Hardened Runtime entitlement"
        echo "  3. codesign --deep --force --options runtime --sign \"Developer ID\" \"$APP_PATH\""
        echo "  4. ditto -c -k --keepParent \"$APP_PATH\" MMForge.zip"
        echo "  5. xcrun notarytool submit MMForge.zip --apple-id … --team-id … --wait"
        echo "  6. xcrun stapler staple \"$APP_PATH\""
        echo
        echo "── OCCT Shim ──"
        echo "OCCT support requires a pre-built shim library."
        echo "See: crates/mmforge-geometry/shim/README.md"
        ;;
    dmg)
        build_rust
        APP_PATH=$(build_app "Release")
        create_dmg "$APP_PATH"
        ;;
    *)
        echo "Usage: $0 {debug|release|dmg}"
        echo "  debug    → Debug build + symlink"
        echo "  release  → Release .app (unsigned)"
        echo "  dmg      → Release .app + DMG (unsigned, default)"
        exit 1
        ;;
esac
