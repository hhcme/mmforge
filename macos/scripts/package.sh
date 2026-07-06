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

# ── Recursive dylib bundling ──────────────────────────────────────────
# Collect ALL non-system dylibs needed by every binary in the app bundle
# (main executable + existing dylibs in Frameworks/), copy them into
# Frameworks/, and rewrite load paths to @rpath so the app is fully
# self-contained (no /opt/homebrew, /usr/local, or Cellar paths).

# Returns 0 if the path looks like a system library (should NOT be bundled).
is_system_lib() {
    local lib="$1"
    case "$lib" in
        /usr/lib/*|/System/Library/*) return 0 ;;
        *) return 1 ;;
    esac
}

bundle_occt_dylibs() {
    local app_path="$1"
    local frameworks_dir="$app_path/Contents/Frameworks"
    mkdir -p "$frameworks_dir"

    info "  [occt] Bundling dylibs (recursive transitive closure) …"

    # Collect all binaries to scan: main executable + debug dylib + any .dylib in Frameworks/.
    local scan_list
    scan_list=$(find "$frameworks_dir" -name '*.dylib' -maxdepth 1 2>/dev/null || true)
    if [ -f "$app_path/Contents/MacOS/$APP_NAME" ]; then
        scan_list="$scan_list"$'\n'"$app_path/Contents/MacOS/$APP_NAME"
    fi
    if [ -f "$app_path/Contents/MacOS/$APP_NAME.debug.dylib" ]; then
        scan_list="$scan_list"$'\n'"$app_path/Contents/MacOS/$APP_NAME.debug.dylib"
    fi

    local total_copied=0
    local changed=1

    # Iterate until no new dylibs are discovered.
    while [ "$changed" -eq 1 ]; do
        changed=0

        # Discover all non-system, non-@rpath deps from all scanned binaries.
        local new_deps=""
        while IFS= read -r bin; do
            [ -z "$bin" ] && continue
            [ -f "$bin" ] || continue
            local deps
            deps=$(otool -L "$bin" 2>/dev/null \
                | grep -oE '/[^ ]+\.dylib' \
                | grep -v '@rpath\|@loader_path\|@executable_path\|^/lib/\|^/usr/\|^/System/' \
                || true)
            while IFS= read -r dep; do
                [ -z "$dep" ] && continue
                if is_system_lib "$dep"; then continue; fi
                local name
                name=$(basename "$dep")
                local dest="$frameworks_dir/$name"
                if [ ! -f "$dest" ]; then
                    new_deps="$new_deps"$'\n'"$dep"
                fi
            done <<< "$deps"
        done <<< "$scan_list"

        new_deps=$(echo "$new_deps" | sort -u | sed '/^$/d')

        # Copy new deps.
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            if [ ! -f "$dep" ]; then
                info "  [occt]   WARNING: not found: $dep"
                continue
            fi
            local name
            name=$(basename "$dep")
            local dest="$frameworks_dir/$name"
            cp "$dep" "$dest"
            chmod 644 "$dest"
            info "  [occt]   $name"
            ((total_copied++)) || true
            changed=1
        done <<< "$new_deps"

        # Update scan list to include newly copied dylibs.
        scan_list=$(find "$frameworks_dir" -name '*.dylib' -maxdepth 1 2>/dev/null || true)
    done

    if [ "$total_copied" -eq 0 ]; then
        info "  [occt] No new dylibs to copy"
    else
        info "  [occt] Copied $total_copied new dylibs"
    fi

    # Always rewrite load paths — even when no new dylibs were copied,
    # previously-bundled dylibs may still need rewriting (e.g. main
    # executable references them with absolute paths from the linker).

    if ! ls "$frameworks_dir"/*.dylib &>/dev/null; then
        info "  [occt] No dylibs in Frameworks/ — nothing to rewrite"
        return 0
    fi

    info "  [occt] Rewriting load paths to @rpath …"

    local all_dylibs
    all_dylibs=$(find "$frameworks_dir" -name '*.dylib' -maxdepth 1 2>/dev/null || true)

    # Build a lookup: basename → absolute path for each bundled dylib.
    while IFS= read -r dylib_file; do
        [ -z "$dylib_file" ] && continue
        local dylib_name
        dylib_name=$(basename "$dylib_file")
        # Fix the dylib's own install name.
        install_name_tool -id "@rpath/$dylib_name" "$dylib_file" 2>/dev/null || true
    done <<< "$all_dylibs"

    # For every binary (app + debug dylib + all bundled dylibs), rewrite
    # each absolute homebrew/Cellar path to @rpath/libname.
    local all_bins="$all_dylibs"$'\n'"$app_path/Contents/MacOS/$APP_NAME"
    if [ -f "$app_path/Contents/MacOS/$APP_NAME.debug.dylib" ]; then
        all_bins="$all_bins"$'\n'"$app_path/Contents/MacOS/$APP_NAME.debug.dylib"
    fi

    while IFS= read -r bin; do
        [ -z "$bin" ] && continue
        [ -f "$bin" ] || continue
        local abs_deps
        abs_deps=$(otool -L "$bin" 2>/dev/null \
            | grep -oE '/[^ ]+\.dylib' \
            | grep -v '@rpath\|@loader_path\|@executable_path\|^/usr/lib\|^/System\|^/lib/' \
            || true)
        while IFS= read -r old_path; do
            [ -z "$old_path" ] && continue
            local libname
            libname=$(basename "$old_path")
            install_name_tool -change "$old_path" "@rpath/$libname" "$bin" 2>/dev/null || true
        done <<< "$abs_deps"
    done <<< "$all_bins"

    local final_count
    final_count=$(ls "$frameworks_dir"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
    info "  [occt] Bundled $total_copied new + rewriting load paths; Frameworks/ now has $final_count dylibs"
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
            bundle_occt_dylibs "$APP_PATH"
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
        info "── OCCT Shim ──"
        info "OCCT support requires a pre-built shim library."
        info "See: crates/mmforge-geometry/shim/README.md"
        ;;
    dmg)
        build_rust
        APP_PATH=$(build_app "Release")
        occt_dir=""
        if occt_dir=$(detect_occt_runtime "Release"); then
            bundle_occt_dylibs "$APP_PATH"
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
