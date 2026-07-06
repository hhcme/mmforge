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
#   macos/build/Build/Products/Debug/MMForge.app    (Debug .app)
#   macos/build/Build/Products/Release/MMForge.app   (Release .app)
#   macos/build/MMForge-0.1.0-alpha.dmg              (disk image)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$MACOS_DIR/.." && pwd)"

CONFIG="${1:-dmg}"
APP_NAME="MMForge"
VERSION="0.1.0"
DMG_NAME="${APP_NAME}-${VERSION}-alpha"
PROJECT="$MACOS_DIR/MMForge.xcodeproj"
SCHEME="MMForge"
BUILD_DIR="$MACOS_DIR/build"

info()  { echo "$@" >&2; }
err()   { echo "ERROR: $@" >&2; exit 1; }

# ── OCCT runtime detection ────────────────────────────────────────────
# Determine whether the built bridge links against OCCT dylibs.
# Returns the OCCT library directory if found, empty string otherwise.

detect_occt_runtime() {
    local config="${1:-Release}"
    local built_dir="$BUILD_DIR/Build/Products/$config"
    # Check all binaries that might link OCCT: main executable, debug dylib, bridge lib.
    local bins=(
        "$built_dir/$APP_NAME.app/Contents/MacOS/$APP_NAME"
        "$built_dir/$APP_NAME.app/Contents/MacOS/$APP_NAME.debug.dylib"
        "$ROOT/target/release/libmmforge_bridge.a"
    )
    for check_file in "${bins[@]}"; do
        if [ -f "$check_file" ]; then
            local first_lib
            first_lib=$(otool -L "$check_file" 2>/dev/null | grep -o '/.*/libTKernel[^ ]*\.dylib' | head -1)
            if [ -n "$first_lib" ]; then
                dirname "$first_lib"
                return 0
            fi
        fi
    done
    return 1
}

# ── OCCT dylib bundling ───────────────────────────────────────────────
# Copy OCCT dylibs into the app bundle and rewrite load paths to @rpath.
# This makes the app self-contained — it doesn't need OCCT installed.

bundle_occt_dylibs() {
    local app_path="$1"
    local occt_lib_dir="$2"

    local frameworks_dir="$app_path/Contents/Frameworks"
    mkdir -p "$frameworks_dir"

    info "  [occt] Bundling OCCT runtime from $occt_lib_dir"

    # List all OCCT dylibs referenced by the app.
    local dylibs
    dylibs=$(otool -L "$app_path/Contents/MacOS/$APP_NAME" \
                   "$app_path/Contents/MacOS/$APP_NAME.debug.dylib" 2>/dev/null \
        | grep -o '/.*/libTK[^ ]*\.dylib' | sort -u || true)

    if [ -z "$dylibs" ]; then
        info "  [occt] No OCCT dylibs referenced — skipping bundle"
        return 0
    fi

    local count=0
    while IFS= read -r dylib_path; do
        local name
        name=$(basename "$dylib_path")
        local dest="$frameworks_dir/$name"

        if [ ! -f "$dest" ]; then
            cp "$dylib_path" "$dest"
            chmod 644 "$dest"
            info "  [occt]   $name"
            ((count++)) || true
        fi
    done <<< "$dylibs"

    # Rewrite load commands from absolute paths to @rpath-relative.
    info "  [occt] Rewriting load paths to @rpath …"
    local targets
    targets=$(find "$frameworks_dir" -name 'libTK*.dylib' -maxdepth 1)
    for target_bin in "$app_path/Contents/MacOS/$APP_NAME" \
                       "$app_path/Contents/MacOS/$APP_NAME.debug.dylib"; do
        if [ ! -f "$target_bin" ]; then continue; fi
        while IFS= read -r old_path; do
            local libname
            libname=$(basename "$old_path")
            install_name_tool -change "$old_path" "@rpath/$libname" "$target_bin" 2>/dev/null || true
        done <<< "$dylibs"
    done

    # Fix the dylib IDs themselves (so they reference each other with @rpath).
    for dylib_file in $targets; do
        local dylib_name
        dylib_name=$(basename "$dylib_file")
        install_name_tool -id "@rpath/$dylib_name" "$dylib_file" 2>/dev/null || true
        # Rewrite inter-dylib references.
        while IFS= read -r old_path; do
            local ref_name
            ref_name=$(basename "$old_path")
            if [ "$ref_name" != "$dylib_name" ]; then
                install_name_tool -change "$old_path" "@rpath/$ref_name" "$dylib_file" 2>/dev/null || true
            fi
        done <<< "$dylibs"
    done

    info "  [occt] Bundled $count dylibs into Frameworks/"
}

# ── Ad-hoc code signing ───────────────────────────────────────────────
# Apple requires dylibs in app bundles to be signed.  We use ad-hoc
# signing (`-`) when no Developer ID is configured.  This satisfies
# Gatekeeper's "unsigned but notarized" path for local use.

ad_hoc_sign() {
    local app_path="$1"
    if ! command -v codesign &>/dev/null; then return 0; fi
    local identity="${CODE_SIGN_IDENTITY:--}"
    info "  [sign] Ad-hoc signing ($identity) …"
    # Sign dylibs first, then the .app bundle.
    find "$app_path/Contents/Frameworks" -name '*.dylib' -maxdepth 1 2>/dev/null | while IFS= read -r dylib; do
        codesign --force --sign "$identity" --timestamp=none "$dylib" 2>&1 || true
    done
    codesign --force --sign "$identity" --timestamp=none "$app_path" 2>&1 || true
    info "  [sign] done"
}

# ── Diagnostics ───────────────────────────────────────────────────────

print_diagnostics() {
    local app_path="$1"
    info
    info "── App Diagnostics ──"
    info "  path       : $app_path"
    info "  size       : $(du -sh "$app_path" 2>/dev/null | cut -f1)"
    info "  arch       : $(file "$app_path/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/.*: //')"

    if [ -d "$app_path/Contents/Frameworks" ] && ls "$app_path/Contents/Frameworks"/libTK*.dylib &>/dev/null; then
        local dylib_count
        dylib_count=$(ls "$app_path/Contents/Frameworks"/libTK*.dylib 2>/dev/null | wc -l | tr -d ' ')
        info "  OCCT dylibs: $dylib_count bundled in Frameworks/"
    else
        info "  OCCT dylibs: none (OCCT not linked or not bundled)"
    fi

    local sign_info
    sign_info=$(codesign -dvv "$app_path" 2>&1 || true)
    if echo "$sign_info" | grep -q 'Signature=ad-hoc'; then
        info "  Signature  : ad-hoc"
    elif echo "$sign_info" | grep -q 'Authority='; then
        info "  Signature  : $(echo "$sign_info" | grep '^Authority=' | head -1 | sed 's/.*=//')"
    else
        info "  Signature  : unsigned"
    fi
    info
}

# ── Rust Bridge ──────────────────────────────────────────────────────

build_rust() {
    local features=""
    local occt_incl="${OCCT_INCLUDE_DIR:-/opt/homebrew/include/opencascade}"
    local occt_lib="${OCCT_LIB_DIR:-/opt/homebrew/lib}"
    local shim_a="${MMFORGE_SHIM_DIR:-${ROOT}/crates/mmforge-geometry/shim/build}/libmmforge_occt_shim.a"

    if [ -d "$occt_incl" ] && [ -d "$occt_lib" ] && [ -f "$shim_a" ]; then
        info "  [rust] Building with OCCT support"
        features="--features occt"
    else
        info "  [rust] Building without OCCT (STEP/IGES will show guidance)"
    fi

    cd "$ROOT"
    cargo build --release -p mmforge-bridge ${features} 2>&1 \
        | while IFS= read -r line; do info "  [rust] $line"; done

    local src="${ROOT}/target/release/libmmforge_bridge.a"
    if [ ! -f "$src" ]; then
        err "libmmforge_bridge.a not found at $src"
    fi
    mkdir -p "$BUILD_DIR/Products/Release"
    cp "$src" "$BUILD_DIR/Products/Release/"
    info "  [rust] → $BUILD_DIR/Products/Release/libmmforge_bridge.a"
}

# ── Build ─────────────────────────────────────────────────────────────

build_app() {
    local config="$1"
    local cs="CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"

    info "==> Building $APP_NAME ($config) …"
    mkdir -p "$BUILD_DIR/Products/$config"

    cd "$MACOS_DIR"
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
info "  root    : $ROOT"
info "  macos   : $MACOS_DIR"
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
        print_diagnostics "$APP_PATH"
        ;;
    release)
        build_rust
        APP_PATH=$(build_app "Release")
        # Bundle OCCT if linked, then sign.
        occt_dir=""
        if occt_dir=$(detect_occt_runtime "Release"); then
            bundle_occt_dylibs "$APP_PATH" "$occt_dir"
        fi
        ad_hoc_sign "$APP_PATH"
        info
        info "Release build complete."
        info "App: $APP_PATH"
        print_diagnostics "$APP_PATH"
        info
        info "── Signing / Notarization ──"
        info "This build is ad-hoc signed.  For distribution:"
        info "  1. Set DEVELOPMENT_TEAM in the Xcode project"
        info "  2. Add Hardened Runtime entitlement"
        info "  3. codesign --deep --force --options runtime --sign \"Developer ID\" \"$APP_PATH\""
        info "  4. ditto -c -k --keepParent \"$APP_PATH\" MMForge.zip"
        info "  5. xcrun notarytool submit MMForge.zip --apple-id … --team-id … --wait"
        info "  6. xcrun stapler staple \"$APP_PATH\""
        info
        if [ -z "$occt_dir" ]; then
            info "── OCCT Shim ──"
            info "OCCT is NOT linked.  STEP/IGES will show build guidance."
            info "To enable: install OCCT + build shim, then rebuild."
            info "See: crates/mmforge-geometry/shim/README.md"
        fi
        ;;
    dmg)
        build_rust
        APP_PATH=$(build_app "Release")
        occt_dir=""
        if occt_dir=$(detect_occt_runtime "Release"); then
            bundle_occt_dylibs "$APP_PATH" "$occt_dir"
        fi
        ad_hoc_sign "$APP_PATH"
        create_dmg "$APP_PATH"
        ;;
    *)
        info "Usage: $0 {debug|release|dmg}"
        info "  debug    → Debug build + symlink"
        info "  release  → Release .app (ad-hoc signed, OCCT bundled if linked)"
        info "  dmg      → Release .app + DMG (ad-hoc signed, OCCT bundled if linked)"
        exit 1
        ;;
esac
