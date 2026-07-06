#!/bin/bash
# package.sh — Build and package MMForge macOS app.
#
# Usage:
#   ./package.sh debug    → Debug build (no code signing), .app symlink
#   ./package.sh release  → Release build, produce unsigned .app
#   ./package.sh dmg      → (default) Release build + DMG
#
# Prerequisites:
#   - Xcode 26+ (with macOS 26 SDK)
#   - Rust stable toolchain in ~/.cargo/bin
#   - OCCT (optional): if OCCT_INCLUDE_DIR/OCCT_LIB_DIR/shim exist,
#     builds with OCCT; otherwise builds without it (STEP/IGES show guidance)
#
# Output:
#   macos/build/Products/Debug/MMForge.app    (Debug .app)
#   macos/build/Products/Release/MMForge.app   (Release .app)
#   macos/build/MMForge-0.1.0-alpha.dmg        (disk image)

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-dmg}"
APP_NAME="MMForge"
VERSION="0.1.0"
DMG_NAME="${APP_NAME}-${VERSION}-alpha"
PROJECT="MMForge.xcodeproj"
SCHEME="MMForge"
BUILD_DIR="$(pwd)/build"

# ── Logging helpers ───────────────────────────────────────────────────
# All log/info messages go to stderr so that $(build_app …) captures
# only the app path on stdout.

info()  { echo "$@" >&2; }
err()   { echo "ERROR: $@" >&2; exit 1; }

# ── Rust Bridge ──────────────────────────────────────────────────────
# Xcode's own build phase also runs this logic (conditional OCCT).
# We duplicate it here so package.sh can pre-build the bridge for
# release/dmg without a second xcodebuild pass.  Debug mode lets
# xcodebuild's build phase handle it.

build_rust() {
    local features=""
    local occt_incl="${OCCT_INCLUDE_DIR:-/opt/homebrew/include/opencascade}"
    local occt_lib="${OCCT_LIB_DIR:-/opt/homebrew/lib}"
    local shim_a="${MMFORGE_SHIM_DIR:-$(pwd)/../crates/mmforge-geometry/shim/build}/libmmforge_occt_shim.a"

    if [ -d "$occt_incl" ] && [ -d "$occt_lib" ] && [ -f "$shim_a" ]; then
        info "  [rust] Building with OCCT support"
        features="--features occt"
    else
        info "  [rust] Building without OCCT (STEP/IGES will show guidance)"
    fi

    cargo build --release -p mmforge-bridge ${features} 2>&1 | while IFS= read -r line; do info "  [rust] $line"; done

    local src="../../target/release/libmmforge_bridge.a"
    if [ ! -f "$src" ]; then
        err "libmmforge_bridge.a not found at $src"
    fi
    mkdir -p "$BUILD_DIR/Products/Release"
    cp "$src" "$BUILD_DIR/Products/Release/"
    info "  [rust] → $BUILD_DIR/Products/Release/libmmforge_bridge.a"
}

# ── Build ─────────────────────────────────────────────────────────────
# All logging goes to stderr.  Only the resulting .app path is printed
# to stdout (for $() capture by the caller).

build_app() {
    local config="$1"
    local cs="CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"

    info "==> Building $APP_NAME ($config) …"

    mkdir -p "$BUILD_DIR/Products/$config"

    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$config" \
        -derivedDataPath "$BUILD_DIR" \
        -destination 'platform=macOS' \
        ${cs} \
        build >&2

    local app_path="$BUILD_DIR/Build/Products/$config/$APP_NAME.app"
    if [ ! -d "$app_path" ]; then
        err "Build did not produce $app_path"
    fi

    info "  [ok] $app_path"
    echo "$app_path"
}

# ── Symlink (Debug) ───────────────────────────────────────────────────

symlink_app() {
    local app_path="$1"
    local link_path="$BUILD_DIR/$APP_NAME.app"
    rm -f "$link_path"
    ln -sf "$app_path" "$link_path"
    info "  [symlink] $link_path → $app_path"
}

# ── DMG ───────────────────────────────────────────────────────────────

create_dmg() {
    local app_path="$1"
    local dmg_path="$BUILD_DIR/${DMG_NAME}.dmg"
    local staging="$BUILD_DIR/dmg_staging"

    info "==> Creating DMG …"

    rm -rf "$staging" "$dmg_path"
    mkdir -p "$staging"
    cp -R "$app_path" "$staging/"

    ln -s /Applications "$staging/Applications"

    hdiutil create \
        -volname "$DMG_NAME" \
        -srcfolder "$staging" \
        -ov -format UDZO \
        "$dmg_path" >&2

    rm -rf "$staging"

    info "  [ok] $dmg_path"
    info "  DMG size: $(du -sh "$dmg_path" | cut -f1)"
    info
    info "  To install: open $dmg_path"

    echo "$dmg_path"
}

# ── Main ──────────────────────────────────────────────────────────────

info "MMForge macOS Packaging"
info "  version : $VERSION"
info "  config  : $CONFIG"
info

case "$CONFIG" in
    debug)
        APP_PATH=$(build_app "Debug")
        symlink_app "$APP_PATH"
        info
        info "Debug build complete."
        info "Run: open $APP_PATH"
        ;;
    release)
        build_rust
        APP_PATH=$(build_app "Release")
        info
        info "Release build complete."
        info "App: $APP_PATH"
        info
        info "── Signing / Notarization ──"
        info "This build is UNSIGNED. To sign for distribution:"
        info "  1. Set DEVELOPMENT_TEAM in the Xcode project"
        info "  2. Add Hardened Runtime entitlement"
        info "  3. codesign --deep --force --options runtime --sign \"Developer ID\" \"$APP_PATH\""
        info "  4. ditto -c -k --keepParent \"$APP_PATH\" MMForge.zip"
        info "  5. xcrun notarytool submit MMForge.zip --apple-id … --team-id … --wait"
        info "  6. xcrun stapler staple \"$APP_PATH\""
        info
        info "── OCCT Shim ──"
        info "OCCT support requires a pre-built shim library."
        info "See: crates/mmforge-geometry/shim/README.md"
        ;;
    dmg)
        build_rust
        APP_PATH=$(build_app "Release")
        create_dmg "$APP_PATH"
        ;;
    *)
        info "Usage: $0 {debug|release|dmg}"
        info "  debug    → Debug build + symlink"
        info "  release  → Release .app (unsigned)"
        info "  dmg      → Release .app + DMG (unsigned, default)"
        exit 1
        ;;
esac
