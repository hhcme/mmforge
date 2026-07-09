# macOS Non-Interactive Verification Hardening — 2026-07-08

**Date**: 2026-07-08
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE (v3 — advisory semantics fixed: exit 3, PASS WITH ADVISORY, 18 shell gating tests, non-OCCT ERROR/PLACEHOLDER always fail)

---

## 1. Summary

This batch hardens the non-interactive verification system for macOS
industrial delivery. Key improvements:

- **11 new unit tests** for `Drawing2DView.renderImage` (2D/DXF Export Image rendering pipeline), including pixel-content baseline differential test
- **Preflight check script** `macos/scripts/preflight-check.sh` — 10 silent check categories; geometry exit codes (0=PASS, 1=ERROR, 2=PLACEHOLDER, 3=ADVISORY); advisory→"PASS WITH ADVISORY" not "ALL CHECKS PASSED"
- **18-shell-test geometry gating suite** `macos/scripts/test-preflight-geometry-gating.sh` — covers default-fail, advisory-pass, non-OCCT-ERROR-fail, PLACEHOLDER-fail
- **perf-baseline.sh** exit-code contract: exit 3=ADVISORY only when STEP/IGES are sole errors + advisory mode on; any non-OCCT ERROR or PLACEHOLDER → exit 1/2 unconditionally
- **GUI acceptance isolated** behind `MMFORGE_ALLOW_INTERACTIVE_GUI=1` guard
- **NSBitmapImageRep format bug fixed**: `.alphaNonpremultiplied`→`[]` (default premultiplied) — `kCGImageAlphaLast` unsupported on macOS CGBitmapContext; and `drawCommand` text path: `aciColor` (`CGColor`)→`NSColor(cgColor:)` for `NSAttributedString.Key.foregroundColor`
- **Full non-interactive verification suite re-run**: all Rust/Swift pass; preflight gates correctly on no-OCCT geometry errors

---

## 2. New: `Drawing2DView.renderImage` Tests (11 tests)

**File**: `macos/MMForgeTests/AnnotationTests.swift` (+206 lines)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `testRenderImage_emptyCommands_producesImage` | Empty command list → valid NSImage with correct dimensions |
| 2 | `testRenderImage_withDrawCommands` | Lines + circles produce non-nil image |
| 3 | `testRenderImage_withAnnotations` | Measurement + text annotation overlay on rendered image |
| 4 | `testRenderImage_visibleLayerFiltering` | Layer visibility overrides filter correctly in rendered output |
| 5 | `testRenderImage_largeResolution` | 1920×1080 rendering with polyline works |
| 6 | `testRenderImage_aspectRatioWide` | Non-square world bounds (200×100) produce correct image size |
| 7 | `testRenderImage_invalidDimensions_returnsNil` | pixelWidth=0, pixelHeight=0, and zero-dimension combos all return nil |
| 8 | `testRenderImage_allEntityTypes` | Line, Circle, Arc, Polyline, Text all render without crash |
| 9 | `testRenderImage_dashPatternDoesNotCrash` | Dash pattern `[10,5,2,5]` on lines does not crash |
| 10 | `testRenderImage_pixelContentNonTrivial` | Pixel diff against empty-command baseline + ACI color-index detection proves entity rendered |
| 11 | `testRenderImage_closedPolyline_rendersWithoutCrash` | Closed polyline renders safely |

All 11 tests use the **headless** `Drawing2DView.renderImage` static method — no
NSView hierarchy, no window, no display required. The rendering uses
`NSBitmapImageRep` + `NSGraphicsContext` so it works silently in CI.

---

## 3. New: `macos/scripts/preflight-check.sh`

A single-script entrypoint for all non-interactive delivery checks.
Suitable for CI, pre-commit hooks, and deterministic pre-release gates.

### 3.1 Check Categories (10 categories, 0 GUI)

| # | Category | Purpose |
|---|----------|---------|
| 1 | `cargo fmt --check` | Rust formatting |
| 2 | `cargo clippy -- -D warnings` | Rust static analysis |
| 3 | `cargo test --workspace` | Rust unit + integration tests |
| 4 | `xcodebuild test` | Swift tests (headless) |
| 5 | `package.sh release` + `package.sh dmg` | Release .app + DMG build |
| 6 | `codesign --verify --deep --strict` | Code signature validation |
| 7 | `otool -L` audit | 0 Homebrew refs, all @rpath deps satisfied |
| 8 | `file` arch check | Binary arch matches host arch (arm64) |
| 9 | `hdiutil verify` DMG integrity | DMG file integrity |
| 10 | `git diff --check` | Whitespace violations |

### 3.2 Usage

```bash
# Run full preflight (no GUI, no desktop interaction)
bash macos/scripts/preflight-check.sh
# Exit code 0 = all pass (or no-OCCT advisory)
# Exit code 1 = fatal failure

# Accept STEP/IGES no-OCCT as advisory (exit 0, but notes the gap)
MMFORGE_ALLOW_NO_OCCT=1 bash macos/scripts/preflight-check.sh
```

### 3.3 Geometry Gate (Section 10 — perf-baseline)

`preflight-check.sh` section 10 calls `docs/scripts/perf-baseline.sh` and
interprets its exit code:

| perf-baseline exit | Meaning | Preflight result | Summary message |
|:--:|---------|-------------------|-----------|
| 0 | All REAL-GEOMETRY or 2D-ONLY (OCCT present) | green PASS | `ALL CHECKS PASSED` |
| 1 | Hard ERROR (any format, incl. non-OCCT) | **FAIL (exit 1)** | `CHECKS FAILED` |
| 2 | PLACEHOLDER (empty model) | **FAIL (exit 1)** | `CHECKS FAILED` |
| 3 | ADVISORY: STEP/IGES no-OCCT only | yellow ADVISORY (exit 0) | `PASS WITH ADVISORY` |

The **exit 3 path** is the critical distinction:
- It only triggers when `MMFORGE_ALLOW_NO_OCCT=1` AND all errors are STEP/IGES
- The preflight summary prints "PASS WITH ADVISORY" (yellow), NOT "ALL CHECKS PASSED"
- The advisory message explicitly states: "STEP/IGES geometry NOT verified (requires OpenCASCADE)"
- STL, glTF, DXF ERROR or any PLACEHOLDER → always exit 1/2, advisory flag ignored

---

## 4. Documentation Overclaim Corrections

### 4.1 Files Fixed

| File | Claims Corrected |
|------|-----------------|
| `docs/progress/2026-07-07-macos-format-gui-acceptance.md` | 6 fixes — status→PARTIAL; 8/8 ✅→⚠️; Export/Interaction ✅→⚠️; Window/Structure ✅→⚠️; perf-baseline "5/5"→"4 REAL-GEOMETRY + 1 2D-ONLY" |
| `docs/progress/2026-07-07-macos-alpha-trial-package.md` | 4 fixes — perf-baseline "5/5"→"4+1"; smoke-test qualifier; GUI check marked ⚠️ Prior Debug |
| `docs/progress/2026-07-07-macos-runtime-usability-performance.md` | 4 fixes — perf-baseline "5/5"→"4+1"; smoke qualifier; 5 GUI checks ✅→⚠️; progress bar description corrected |
| `docs/progress/2026-07-07-macos-format-closure-review.md` | 2 fixes — perf-baseline "5/5"→"4+1"; GUI section marked ⚠️ Prior Debug |
| `docs/progress/2026-07-06-macos-industrial-delivery-hardening.md` | 1 fix — smoke-test "8/8"→"(launch smoke only — no rendering verification)" |

### 4.2 Correction Patterns

| Pattern | Before | After |
|---------|--------|-------|
| perf-baseline binary count | "5/5 pass" / "ALL 5 FORMATS PASS" | "2 REAL-GEOMETRY + 1 2D-ONLY + 2 ERROR" (default no-OCCT) |
| perf-baseline with OCCT | (not distinguished) | With OCCT: "4 REAL-GEOMETRY + 1 2D-ONLY" |
| GUI claims from prior Debug session | ✅ Renders / ✅ NSSavePanel | ⚠️ Prior Debug — not re-verified for Release |
| Export/interaction claims | ✅ PNG saved / ✅ All 4 distinct | ⚠️ Prior Debug session |
| smoke-test language | "8 passed" (alongside correctness tests) | "(launch smoke only — no rendering verification)" |
| Progress bar "no flash" | "Progress bar — no flash \| Code review ✅" | "meshCount label corrected; flash was from prior code version already removed" |
| preflight perf-baseline exit | Always PASS (ignored ERROR) | Fails on ERROR unless MMFORGE_ALLOW_NO_OCCT=1 (advisory) |
| pixelContentNonTrivial | Count non-white pixels (weak) | Pixel diff vs empty-command baseline + ACI color detection |

---

## 5. GUI Acceptance Isolation

### 5.1 MMFORGE_ALLOW_INTERACTIVE_GUI Guard

`scripts/gui-acceptance-test.sh` now refuses to run unless explicitly opted in:

```bash
$ bash scripts/gui-acceptance-test.sh
ERROR: GUI acceptance is an interactive foreground test.
...
  MMFORGE_ALLOW_INTERACTIVE_GUI=1 bash scripts/gui-acceptance-test.sh
EXIT: 2
```

The error message also lists silent checks that can be run without the guard.

### 5.2 Evidence Policy

- **Screen capture**: window-scoped only (not full-screen), validated by dimensions and SHA-256 manifest
- **Export verification**: checks exported PNG file exists, is non-empty, and has valid dimensions
- **Render-mode delta**: script detects screenshot hash changes but does not assert semantic mode correctness (manual review needed)
- **No automated viewport/content assertions**: orbit/pan/zoom, structure tree, picking remain manual

### 5.3 When to Run

Only on a dedicated machine where desktop takeover is acceptable. The script activates MMForge via AppleScript, sends keyboard shortcuts (Cmd+1..4, Cmd+E), drives NSSavePanel, and captures the MMForge window.

---

## 6. Verification Suite (Re-run 2026-07-08 10:22 CST, v2 review fixes applied)

### 6.1 Automated (No GUI)

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | **clean** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo test --workspace` | **354 pass** (63 bridge, 12 CLI binary, 30 CLI integration, 97 core, 39 DXF, 6 IGES, 12 STEP, 6 geometry, 89 render) |
| `xcodebuild test` (Debug, macOS arm64) | **166/166 pass** (55 Annotation + 26 AsyncParse + 22 Picking + 52 Productization + 11 Transform) |
| `bash macos/scripts/package.sh release` | **BUILD SUCCEEDED** (51 MB, ad-hoc signed, 30 OCCT dylibs) |
| `bash macos/scripts/package.sh dmg` | **BUILD SUCCEEDED** (20 MB DMG) |
| `codesign --verify --deep --strict` | **OK** (all 30 dylibs validated, app valid on disk) |
| `otool -L` (main binary + 30 dylibs) | **0 Homebrew refs** (+ 34 unique @rpath deps, 0 missing) |
| `bash docs/scripts/perf-baseline.sh` | **exit 1: 2 REAL-GEOMETRY + 1 2D-ONLY + 2 ERROR (no OCCT)** |
| `MMFORGE_NO_OCCT_ADVISORY=1 bash docs/scripts/perf-baseline.sh` | **exit 3: ADVISORY — GEOMETRY_VERDICT=ADVISORY** |
| `bash macos/scripts/preflight-check.sh` (default) | **FAIL (exit 1)** — geometry ERROR on STEP/IGES |
| `MMFORGE_ALLOW_NO_OCCT=1 bash macos/scripts/preflight-check.sh` | **exit 0: "PASS WITH ADVISORY"** (not "ALL CHECKS PASSED") |
| `bash macos/scripts/test-preflight-geometry-gating.sh` | **ALL TESTS PASSED (18/18)** |
| `git diff --check` | **clean** |
| `bash -n macos/scripts/preflight-check.sh` | **syntax OK** |
| `bash -n docs/scripts/perf-baseline.sh` | **syntax OK** |
| `bash -n scripts/gui-acceptance-test.sh` | **syntax OK** |
| `MMFORGE_ALLOW_INTERACTIVE_GUI` guard test | **PASS** — exits with message at default |

### 6.2 Geometry Evidence (perf-baseline, default no-OCCT)

| Format | Status | Nodes | Geoms | Triangles |
|--------|--------|-------|-------|-----------|
| STL | REAL-GEOMETRY | 2 | 1 | 12 |
| glTF | REAL-GEOMETRY | 1 | 1 | 1 |
| DXF | 2D-ONLY | 5 | 1 | 0 |
| STEP | ERROR (no OCCT) | — | — | — |
| IGES | ERROR (no OCCT) | — | — | — |

> With OCCT enabled (`--features mmforge-bridge/occt`, Release build): 4 REAL-GEOMETRY + 1 2D-ONLY (STEP geoms=1, tri=4554; IGES geoms=1, tri=12).

### 6.3 Preflight Exit Code Paths Verified

| Scenario | Command | Exit | Section 10 Result | Summary Message |
|----------|---------|:----:|-------------------|-----------------|
| Default (no OCCT) | `bash macos/scripts/preflight-check.sh` | 1 | FAIL (geometry ERROR STEP IGES) | CHECKS FAILED |
| Advisory no-OCCT | `MMFORGE_ALLOW_NO_OCCT=1 bash macos/scripts/preflight-check.sh` | 0 | ADVISORY (STEP/IGES no-OCCT) | PASS WITH ADVISORY |
| With OCCT | (requires OCCT build) | 0 | PASS (4 REAL-GEOMETRY + 1 2D-ONLY) | ALL CHECKS PASSED |
| Advisory + non-OCCT ERROR | (test-only, see gating suite) | 1 | FAIL | CHECKS FAILED |
| Advisory + PLACEHOLDER | (test-only) | 1 | FAIL | CHECKS FAILED |

### 6.3 Test Count Changes

| Suite | Before | After | Delta |
|-------|--------|-------|-------|
| Rust tests | 354 | 354 | — |
| Swift tests | 155 | **166** | +11 (renderImage) |
| AnnotationTests | 44 | **55** | +11 |
| Total | 509 | 520 | +11 |

---

## 7. Product Artifacts

| Artifact | Path | Size | OCCT | Signed |
|----------|------|------|------|:------:|
| Debug .app | `macos/build/MMForge.app` (symlink) | 13 MB | None | No |
| Release .app | `macos/build/Build/Products/Release/MMForge.app` | 51 MB | 30 dylibs | Ad-hoc |
| DMG | `macos/build/MMForge-0.1.0-alpha.dmg` | 20 MB | 30 dylibs inside | Ad-hoc |

---

## 8. Files Changed

| File | Δ | Change |
|------|---|--------|
| `macos/MMForgeTests/AnnotationTests.swift` | +224 | 11 new `renderImage` unit tests; `pixelContentNonTrivial` rewritten with baseline-diff + ACI color detection |
| `macos/scripts/preflight-check.sh` | +300 (new) | 10-category silent verification; Section 10 exit-code gating with `MMFORGE_ALLOW_NO_OCCT` advisory |
| `docs/scripts/perf-baseline.sh` | +34/−0 | Exit codes (0/1/2/3); `MMFORGE_NO_OCCT_ADVISORY=1` downgrade for known OCCT-dependent formats |
| `docs/progress/2026-07-08-macos-noninteractive-verification-hardening.md` | +260 (new) | This report |
| `docs/progress/2026-07-07-macos-format-gui-acceptance.md` | +14/−13 | perf-baseline OCCT/no-OCCT split: "4+1"→"2+1+2 ERROR (default); with OCCT: 4+1" |
| `docs/progress/2026-07-07-macos-alpha-trial-package.md` | +4/−4 | perf-baseline OCCT/no-OCCT split |
| `docs/progress/2026-07-07-macos-runtime-usability-performance.md` | +10/−9 | perf-baseline OCCT/no-OCCT split |
| `docs/progress/2026-07-07-macos-format-closure-review.md` | +4/−3 | perf-baseline OCCT/no-OCCT split |
| `docs/progress/2026-07-06-macos-industrial-delivery-hardening.md` | +1/−1 | smoke-test "(launch smoke only)" qualifier |

**Working tree carries forward** (preserved from prior session):
- `macos/MMForge/Document/MMForgeDocument.swift` (+53): 2D image export path
- `macos/MMForge/Views/DrawingView.swift` (+44): `renderImage` static method
- `scripts/gui-acceptance-test.sh` (+488): stricter evidence, `MMFORGE_ALLOW_INTERACTIVE_GUI` guard
- `docs/progress/2026-07-06-macos-release-gui-acceptance.md` (+352): BLOCKED WITH CORRECTIONS status

---

## 9. Remaining Gaps

| # | Gap | Status |
|---|-----|--------|
| G1 | Window-scoped GUI acceptance (all 8 formats) | Blocked — requires `MMFORGE_ALLOW_INTERACTIVE_GUI=1` dedicated foreground session |
| G2 | Export PNG verification (GUI) | Blocked — same as G1 |
| G3 | Viewport semantics (structure tree, orbit/pan/zoom, picking) | Manual pending — no automated assertion exists |
| G4 | Apple Developer ID / notarization | Requires $99/year Apple Developer Program |
| G5 | Intel Mac (x86_64) untested | arm64 only |
| G6 | OCCT-enabled CLI benchmarks (STEP/IGES) | Debug build lacks OCCT; release binary path needs `--features occt` |

---

## 10. Next Priorities

1. Run `MMFORGE_ALLOW_INTERACTIVE_GUI=1 bash scripts/gui-acceptance-test.sh` on dedicated Mac for window-scoped GUI evidence
2. OCCT-enabled CI pipeline for STEP/IGES parity
3. Draw-call batching in Metal renderer (C1 from prior report)
4. `@Published` → `@Observable` migration for SwiftUI performance
5. Apple notarization + Hardened Runtime for distribution
