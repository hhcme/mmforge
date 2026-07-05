# macOS GUI Manual Acceptance — 2026-07-05

**Date**: 2026-07-05
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — all 5 formats open via `open -a`, plain `.json` rejected

---

## 1. Root Cause & Fix

### Problem

`open -a MMForge.app file.stl` launched the app but `NSDocumentController` rejected
the file: _"MMForge cannot open files in the '3D Model File' format."_

### Root Cause

macOS resolves `.stl` → `public.standard-tesselated-geometry-format` (system UTI).
SwiftUI DocumentGroup checks `FileDocument.readableContentTypes` against the
file's system UTI.  The `readableContentTypes` only listed custom UTIs
(`com.mmforge.stl`); the system UTI does not conform to the custom UTI, so
the match failed.

### Fix — `MMForgeDocument.swift`

```swift
static var readableContentTypes: [UTType] {
    let custom: [UTType] = [.step, .stl, .gltf, .glb, .iges, .dxf]
    let sys: [UTType] = ["step","stp","stl","STL","gltf","glb","igs","iges","dxf"]
        .compactMap { UTType(filenameExtension: $0) }
    return custom + sys
}
```

`UTType(filenameExtension:)` resolves to the system UTI (e.g.
`public.standard-tesselated-geometry-format` for `.stl`).  Adding these
alongside custom UTIs ensures NSDocumentController can match files.

### Supporting Changes

| File | Change | Why |
|------|--------|-----|
| `Info.plist` | Added `public.standard-tesselated-geometry-format` to `LSItemContentTypes`; STL custom UTI conforms to it | Launch Services UTI matching |
| `Info.plist` | Removed `public.json` from `LSItemContentTypes` | MMForge must NOT claim to handle generic JSON |
| `AppDelegate.swift` | `applicationShouldOpenUntitledFile → false` | DocumentGroup handles untitled docs |
| `AppDelegate.swift` | `applicationShouldHandleReopen` → creates new doc on Dock click | Standard macOS behavior |
| `AppDelegate.swift` | Removed dead `application(_:openFiles:)` fallback; removed commented-out diagnostic block | SwiftUI's internal handler processes odoc events before AppDelegate |

### Why the AppDelegate open-files Fallback Is Dead Code

SwiftUI DocumentGroup registers an internal `NSApplicationDelegate` that intercepts
the "odoc" Apple Event before `@NSApplicationDelegateAdaptor`'s delegate.
With `readableContentTypes` fixed, SwiftUI's handler succeeds and creates a
document window; the user's delegate method is never called.  The method was
only reached when `NSDocumentController` rejected the file (before the fix).

---

## 2. File-Open Test Results (Code Evidence)

All tests executed via `open -a MMForge.app <file>`, window names verified via
`osascript -e 'tell app "System Events" to tell process "MMForge" to return name of every window'`.

### 2.1 CAD/Model Formats — OPENED

| Format | Fixture | Window Title | Result |
|--------|---------|-------------|--------|
| STL    | `testdata/stl/box.stl` | `box.stl` | **OPENED** |
| DXF    | `crates/mmforge-format-dxf/testdata/test.dxf` | `test.dxf` | **OPENED** |
| STEP   | `crates/mmforge-geometry/testdata/PQ-04909-A.STEP` | `PQ-04909-A.STEP` | **OPENED** |
| glTF   | `testdata/gltf/box.gltf` | `box.gltf` | **OPENED** |
| IGES   | `crates/mmforge-geometry/testdata/box.igs` | `box.igs` | **OPENED** |

### 2.2 Non-CAD Format — REJECTED

| Format | Fixture | Result |
|--------|---------|--------|
| JSON   | `/tmp/test_plain.json` (`{"test":true}`) | **REJECTED** — no document window created, no error dialog |

This proves MMForge does NOT claim to open generic `.json` files.  The glTF
custom UTI (`com.mmforge.gltf`) with `.gltf` extension mapping is sufficient.

---

## 3. Manual Interactive Evidence

The app was launched and files opened.  Screenshots captured to
`~/Desktop/mmforge-screenshots/`.

| File | Size | Content |
|------|------|---------|
| `01_stl_loaded.png` | 722K | STL file opened, 3D Metal viewport, structure sidebar |
| `02_dxf_loaded.png` | 787K | DXF file opened, 2D Core Graphics canvas, layers sidebar |
| `03_step_loaded.png` | 731K | STEP file opened, 3D viewport, structure tree |
| `04_gltf_loaded.png` | 729K | glTF file opened, 3D viewport |
| `05_iges_loaded.png` | 728K | IGES file opened, 3D viewport |
| `STL_01_solid.png` | 729K | STL in solid render mode |
| `DXF_01_2d_view.png` | 798K | DXF 2D drawing with entities visible |
| `REOPEN_after_dxf.png` | 800K | DXF opened while STL was loaded |

---

## 4. Feature Verification (Code Evidence)

| Feature | Code Evidence |
|---------|--------------|
| 3D viewport | `testMetalUpload_interleavedVertexLayout`, `testFrustumCache_invalidatedOnClear` |
| 2D drawing | `testSmoke_DXF_validData_loadsAs2DDrawing` |
| Structure tree | `testHasChildren_detectsAssemblyNodes`, `testChildrenOf_returnsDirectChildren`, `testExpandCollapseDescendants`, `testIsolateNode_hidesOtherGeometry`, `testHideAllExcept_hidesAllButOne`, `testVisibleNodeIndices_*` (7 tests) |
| Render modes | `testRenderModeEnum_rawValues`, `testSetRenderMode_updatesRendererAndPersists` |
| Camera transform | `TransformTests` (11 tests: world↔screen, round-trip, pan, zoom, Y-flip) |
| Selection + visibility | `testHideSelectedNode_hidesAndDescendants`, `testSetAllNodesVisible_clearsHidden`, `testHideAllNodes_hidesAllGeometry` |
| Color override | `testSetNodeColor_addsOverride`, `testSetNodeColor_nilRemovesOverride`, `testResetAllColors_clearsOverrides`, `testResetSelectedNodeColor_clearsSelectionOverride` |
| 2D Geometry / measurement | `AnnotationTests` (closest point, distance, area, centroid, angle, snap) |
| Layer visibility (DXF) | `testVisibleCommands_filtersHiddenLayers`, `testVisibleCommands_defaultVisible`, `testVisibleCommands_overrideShow` |
| PDF export | `testPDFExport_doesNotCrash`, `testPDFExport_withDrawCommands`, `testPDFRender_worldTopAboveWorldBottom` |
| Clip plane + section fill | `testSectionFill_cubeZHalf_closedSquare`, `testSectionFill_concaveLShape`, `testSectionFill_openPolyline_skipped`, `testSectionFill_noIntersection`, `testSectionFill_bowtie_earClipsAsSimplePolygon`, `testSectionFill_hopelesslyDegenerate_skipped` |
| Reopen (load new while open) | `testDXF_reopen_invalidatesOldLease`, `testDuplicateOpen_cancelsFirstAndSucceeds`, `testReopenDuringStreaming_newFileLoads` |
| Cancel parse | `testParseCancel_releasesResources`, `testCancelParse_resetsToEmptyState`, `testSmoke_parseThenCancel_stateClean` |
| Gen-guarded spatial query (UAF-safe) | `testDXF_spatialQueryReturnsNilAfterCancel`, `testDXF_reopen_invalidatesOldLease`, `testDXF_closeThenSpawnView_noCrash` |

---

## 5. Verification Suite

| Command | Result |
|---------|--------|
| `xcodebuild test -derivedDataPath macos/build` | **142/142 pass** |
| `cargo test --workspace` | **all pass (336)** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `bash docs/scripts/perf-baseline.sh` | STEP/IGES/STL/DXF pass; glTF CLI fails |
| `git diff --check` | **clean** |

### Perf Baseline

| Format | Status | Detail |
|--------|--------|--------|
| STEP (36K) | PASS | 0.2ms |
| IGES (16K) | PASS | 0.2ms |
| STL (4.0K) | PASS | 0.3ms, 12 triangles |
| glTF (4.0K) | FAILED | CLI returns `error: not a valid STL file` (unsupported path; bridge tests cover) |
| DXF (4.0K) | PASS | 0.1ms |

---

## 6. Key Design Decisions

1. **No `public.json` in `LSItemContentTypes`** — glTF uses custom UTI
   `com.mmforge.gltf` with `.gltf` extension only.  Plain `.json` is rejected.
2. **No AppDelegate `application(_:openFiles:)`** — SwiftUI's internal handler
   processes odoc events first.  Adding a user-side handler would suppress
   SwiftUI's handler (per Apple docs), breaking the fixed flow.
3. **`applicationShouldOpenUntitledFile → false`** — DocumentGroup creates
   untitled documents via its own lifecycle; returning `true` creates a
   conflicting window.
4. **`applicationShouldHandleReopen`** — standard macOS behavior: clicking the
   Dock icon with no open windows creates a new document.

---

## 7. Remaining Issues

| Severity | Issue |
|----------|-------|
| Medium | `captureImage` blocks main thread (B8) |
| Medium | O(n) frustum culling per frame (B9) |
| Medium | glTF CLI unsupported; macOS bridge tests cover |
| Low | Inspector `nodeHasVisibleDescendants` tree walk per render (B16) |
| Low | STEP/IGES produce empty geometry without OCCT (format detection only) |
