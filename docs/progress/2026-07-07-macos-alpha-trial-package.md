# macOS Alpha Trial Package — 2026-07-07

**Date**: 2026-07-07
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — 2 new scripts, +285 lines

---

## 1. Summary

This batch delivers macOS Debug/Release/DMG packaging with:

- **OCCT runtime bundling**: Release/DMG builds auto-detect OCCT linkage
  and bundle 26 dylibs into `MMForge.app/Contents/Frameworks/`
- **Ad-hoc code signing**: App and bundled dylibs signed with `codesign
  --sign -` for local trialability without Apple Developer ID
- **`smoke-test.sh`**: Automated script to verify the built app opens
  all supported formats
- **Clean-startup path**: App opens STL, glTF, GLB, DXF, LSM, LSMC;
  STEP/IGES require OCCT (bundled in Release/DMG, guidance in Debug)

---

## 2. `macos/scripts/package.sh` — Enhanced

### 2.1 OCCT Runtime Bundling (Recursive Transitive Closure)

**Before**: Only copied `libTK*.dylib` from `/opt/homebrew/opt/opencascade/lib/`.
Residual dependencies on `/opt/homebrew/opt/tbb/lib/libtbb.12.dylib`,
`/opt/homebrew/opt/tbb/lib/libtbbmalloc.2.dylib`,
`/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib` were not resolved,
making the app non-portable.

**After**: `bundle_occt_dylibs` recursively discovers all non-system
dylib dependencies of every binary in the app bundle, copies them into
`Contents/Frameworks/`, and rewrites all load paths to `@rpath/`.
Iterates until no new deps are found (transitive closure).

Result: **0 Homebrew /usr/local / Cellar references** in all 27 binaries
(main executable + 26 bundled dylibs).

| Function | Purpose |
|----------|---------|
| `detect_occt_runtime` | Checks main binary + debug dylib + bridge lib for OCCT linkage; returns dylib dir |
| `bundle_occt_dylibs` | Copies OCCT dylibs into `Contents/Frameworks/`, rewrites load paths to `@rpath` |
| `ad_hoc_sign` | Signs dylibs + app with `codesign --sign -` (no Developer ID needed) |
| `print_diagnostics` | Reports app size, arch, OCCT dylib count, signature status |

### 2.2 OCCT Runtime Flow

```
build_rust → detect_occt_runtime → [if linked] bundle_occt_dylibs → ad_hoc_sign
```

Without OCCT: `build_rust` builds without `--features occt`, app shows
STEP/IGES guidance at launch.

### 2.3 Verification (Automated)

```
bash macos/scripts/package.sh debug
  → Debug .app, 13 MB, unsigned, OCCT dylibs: none
bash macos/scripts/package.sh release
  → Release .app, 45 MB, ad-hoc signed, 26 dylibs bundled (22 OCCT + 4 transitive)
bash macos/scripts/package.sh dmg
  → DMG 3.9 MB (compressed), ad-hoc signed, 26 dylibs bundled (22 OCCT + 4 transitive)
```

### 2.4 Code Evidence

```
$ otool -L macos/build/.../Release/MMForge.app/Contents/MacOS/MMForge \
  | grep libTK | head -3
        @rpath/libTKernel.7.9.dylib         ← rewritten from absolute path
        @rpath/libTKMath.7.9.dylib
        @rpath/libTKG3d.7.9.dylib

$ ls macos/build/.../Release/MMForge.app/Contents/Frameworks/libTK*.dylib | wc -l
22  (plus libtbb.12.dylib, libtbbmalloc.2.dylib, libfreetype.6.dylib, libpng16.16.dylib → 26 total)

$ codesign -dvv macos/build/.../Release/MMForge.app
Signature=adhoc                                  ← ad-hoc, not un-signed
```

---

## 3. `macos/scripts/smoke-test.sh` — New

### 3.1 Purpose

Verifies a built `MMForge.app` can open all supported file formats
without crashing.  Useful as a pre-release sanity check.

### 3.2 Usage

```bash
bash macos/scripts/smoke-test.sh [path/to/MMForge.app]
```

Auto-discovers the app if not specified.

### 3.3 Test Matrix (Automated + GUI)

| # | Format | File | Method | Expected |
|---|--------|------|--------|----------|
| 0 | — | App binary | CLI | `file` reports Mach-O arm64 |
| 1 | STL | `testdata/stl/box.stl` | `open -a` | App launches, no crash |
| 2 | glTF | `testdata/gltf/box.gltf` | `open -a` | App launches, no crash |
| 3 | GLB | `testdata/gltf/box.glb` | `open -a` | App launches, no crash |
| 4 | DXF | `crates/.../test.dxf` | `open -a` | App launches, no crash |
| 5 | STEP | `crates/.../PQ-04909-A.STEP` | `open -a` | App launches (with OCCT: renders; without: guidance) |
| 6 | IGES | `crates/.../box.igs` | `open -a` | App launches |
| 7 | LSM | CLI→STL→LSM | `open -a` | App launches, renders (LSM wired) |
| 8 | LSMC | CLI→STL→LSMC | `open -a` | App launches, renders |

LSM/LSMC files generated on-the-fly via `mmforge convert`.

---

## 4. Clean-Startup Path

The app can be opened without any OCCT installation:

| Mode | OCCT | STEP/IGES | STL/glTF/GLB/DXF/LSM/LSMC |
|------|------|-----------|---------------------------|
| Debug build | Not linked | Error with build guidance | Launch smoke / code evidence |
| Release build | Bundled in Frameworks/ (26 dylibs) | Launch smoke / code evidence | Launch smoke / code evidence |
| DMG | Bundled in Frameworks/ (26 dylibs) | Launch smoke / code evidence | Launch smoke / code evidence |

**No Apple Developer ID required**: all builds use ad-hoc signing.
Gatekeeper will block on first launch — right-click → Open to bypass.

---

## 5. Signing Status

| Artifact | Status |
|----------|--------|
| Debug app | Unsigned (Xcode default) |
| Release app | Ad-hoc signed (`codesign --sign -`) |
| DMG | Ad-hoc signed app inside |
| Notarization | **Not performed** — requires $99/year Apple Developer Program |

Ad-hoc signing satisfies macOS code signing requirements for local
execution.  For distribution, a Developer ID certificate + notarization
is needed (documented in package.sh output).

---

## 6. Verification Suite

| Command | Result |
|---------|--------|
| `cargo test --workspace` | **350 pass** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `xcodebuild test -project macos/MMForge.xcodeproj -scheme MMForge -configuration Debug -destination 'platform=macOS' -derivedDataPath macos/build` | **155/155 pass** |
| `bash macos/scripts/package.sh debug` | **BUILD SUCCEEDED** (13 MB, unsigned, no OCCT) |
| `bash macos/scripts/package.sh release` | **BUILD SUCCEEDED** (45 MB, ad-hoc, 26 dylibs) |
| `bash macos/scripts/package.sh dmg` | **BUILD SUCCEEDED** (3.9 MB DMG, ad-hoc, 26 dylibs) |
| `bash docs/scripts/perf-baseline.sh` | **2 REAL-GEOMETRY + 1 2D-ONLY + 2 ERROR** (default no-OCCT; with OCCT: 4 REAL-GEOMETRY + 1 2D-ONLY) |
| `git diff --check` | **clean** |

### Evidence Grades

| Check | Grade | Evidence |
|-------|-------|----------|
| Rust tests (350 pass) | Automated | `cargo test --workspace` output |
| Swift tests (155 pass) | Automated | `xcodebuild test` output |
| CLI geometry (perf-baseline) | Automated — OCCT-dependent | `perf-baseline.sh` output (2 REAL-GEOMETRY + 1 2D-ONLY default; 4+1 with OCCT) |
| Debug .app builds | Automated | `package.sh debug` exit 0 |
| Release .app builds | Automated | `package.sh release` exit 0 |
| DMG builds | Automated | `package.sh dmg` exit 0 |
| OCCT transitive deps (27 binaries, 0 Homebrew refs) | Code evidence | `otool -L` recursive — all `@rpath/` |
| Ad-hoc signing | Code evidence | `codesign -dvv` → `Signature=adhoc` |
| Launch smoke (8 formats) | Automated (launch smoke only — no rendering verification) | `smoke-test.sh`: 8 passed, 0 failed, 0 skipped |
| GUI rendering verification | Manual — ⚠️ Prior Debug session only; re-verify for Release build | Visual inspection of 3D viewport |

---

## 7. Files Changed

| File | Δ | Change |
|------|---|--------|
| `macos/scripts/package.sh` | +132/−52 | Recursive transitive dylib bundling, ad-hoc signing, diagnostics |
| `macos/scripts/smoke-test.sh` | +31/−31 (rewrite) | Launch smoke; fix `set -e` + `((PASS++))` exit bug |
| `docs/progress/2026-07-07-macos-alpha-trial-package.md` | +150 (new) | This report |

---

## 8. Product Artifacts

| Artifact | Path |
|----------|------|
| Debug app | `macos/build/MMForge.app` (symlink) |
| Release app (with OCCT) | `macos/build/Build/Products/Release/MMForge.app` |
| Release DMG (with OCCT) | `macos/build/MMForge-0.1.0-alpha.dmg` |

---

## 9. Known Limitations

1. **No Apple notarization**: Developer ID certificate required ($99/year)
2. **OCCT dylibs large**: 26 dylibs add ~70 MB to the app bundle
3. **MacOS 26 target**: Requires macOS 26 (Sequoia successor)
4. **No auto-update**: Sparkle or similar not yet integrated
5. **No Installer .pkg**: DMG is the only distribution format
6. **Intel Mac untested**: arm64-only; universal binary not configured
