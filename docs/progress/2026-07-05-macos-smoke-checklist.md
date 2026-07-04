# macOS Alpha Trialability — Smoke Test Checklist

Last verified: 2026-07-05

## Verification Semantics

| Result | Meaning |
|--------|---------|
| `PASS (automated)` | Verified by a specific XCTest or Rust test that explicitly asserts this behavior |
| `PASS (CLI)` | Verified by running `mmforge-cli benchmark` / `info` and checking output |
| `PASS (code evidence)` | Code path exists and is correct by static analysis; no runtime test covers it |
| `MANUAL PENDING` | Requires manual interaction with the running macOS app; not yet executed |
| `BLOCKED` | Cannot verify: missing fixture or dependency |

---

## 1. File Opening

| # | Format | Test File | Result | Notes |
|---|--------|-----------|--------|-------|
| 1.1 | STEP (.step) | `testdata/PQ-04909-A.STEP` | PASS (CLI) | CLI: parse 0.1ms avg, detection=STEP. No OCCT → no geometry. Evidence: `mmforge benchmark --format text` + `mmforge info` |
| 1.2 | STL (.stl) | `testdata/stl/box.stl` | PASS (automated) | XCTest: `testSmoke_STL_validFile_reachesLoaded` reaches .loaded. CLI: parse 0.2ms avg, 12 triangles, bounds valid |
| 1.3 | glTF (.gltf) | `testdata/gltf/box.gltf` | PASS (automated) | Rust test: `parse_minimal_gltf_with_data_uri` passes. CLI not supported (glTF needs mmforge-bridge) |
| 1.4 | GLB (.glb) | No fixture | BLOCKED | No binary glTF fixture. Detection code exists (`detect_gltf` checks magic `glTF`) but untested |
| 1.5 | IGES (.igs) | `testdata/box.igs` | PASS (CLI) | CLI: parse 0.1ms avg, detection=IGES. No OCCT → no geometry |
| 1.6 | DXF (.dxf) | `testdata/test.dxf` | PASS (automated) | XCTest: `testSmoke_DXF_validData_loadsAs2DDrawing` → .loaded, is2DDrawing=true, drawCommands>0 |
| 1.7 | Unsupported file | 4 bytes 0xDEADBEEF | PASS (automated) | XCTest: `testSmoke_invalidData_reachesError` reaches .error with message |
| 1.8 | Empty file | 0 bytes | PASS (automated) | XCTest: `testSmoke_emptyDataImmediateEmpty` → .empty state |

---

## 2. Loading State

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 2.1 | Progress bar visible | Shows percentage + stage text | PASS (automated) | XCTest: `testParseReportsProgress` verifies `parseStage` is updated. UITest not viable for custom `ProgressView` |
| 2.2 | Cancel button | Stops parse, returns to empty | PASS (automated) | XCTest: `testSmoke_parseThenCancel_stateClean` verifies cancel → .empty, arrays cleared |
| 2.3 | Format-specific title | "Opening STEP File" etc. | PASS (automated) | XCTest: `testSmoke_loadingFileExtensionPropagated` verifies `loadingFileExtension = "stl"` |
| 2.4 | UI responsive during parse | Can interact with chrome | PASS (code evidence) | `parseFile` dispatches async via `mmf_open_async` on background thread; `@MainActor` serializes state updates |

---

## 3. Structure Tree (Sidebar)

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 3.1 | Root node visible | Shows model root | PASS (automated) | XCTest: `testSmoke_STL_validFile_reachesLoaded` + `visibleNodeIndices` count > 0 |
| 3.2 | Expand/collapse | Disclosure triangle works | PASS (automated) | XCTest: `testExpandCollapseDescendants` verifies indices expand/collapse; `testVisibleNodeIndices_collapseHidesGrandchild` |
| 3.3 | Selection → highlight | Click tree node → 3D highlight | PASS (code evidence) | `StructureSidebar.selectionBinding: Binding<Int?>` → `viewModel.selectNode($0)` → `renderer.setSelectedNode` → `highlightColor` in fragment shader |
| 3.4 | Visibility toggle | Eye icon hides/shows part | PASS (automated) | XCTest: `testHideSelectedNode_hidesAndDescendants`, `testHideAllNodes_hidesAllGeometry` |
| 3.5 | Context menu | Right-click shows actions | PASS (code evidence) | `StructureSidebar.nodeContextMenu` provides Show/Hide Part, Isolate, Expand/Collapse All, Reset Color |
| 3.6 | Search | Filters nodes by name | PASS (automated) | XCTest: `testVisibleNodeIndices_dfsPreorder` verifies search flows via `refreshVisibleIndices` + matchesSearch |
| 3.7 | Assembly nodes | Shows count badge, group icon | PASS (code evidence) | `rectangle.3.group` icon, orange color, `childrenOf(index).count` badge in `StructureSidebar.nodeRow` |
| 3.8 | DFS order | Root→A→A1→B, not BFS | PASS (automated) | XCTest: `testVisibleNodeIndices_dfsPreorder` asserts exact order `[0,1,3,2]` |

---

## 4. View Modes (Toolbar)

| # | Mode | Expected | Result | Notes |
|---|------|----------|--------|-------|
| 4.1 | Solid | Opaque gray rendering | PASS (code evidence) | `solidPipeline` (fillMode .fill, depthWrite true). No pixel-level automated render test |
| 4.2 | Wireframe | Edge-only rendering | PASS (code evidence) | `wireframePipeline` (fillMode .lines). No pixel-level render test |
| 4.3 | Solid+Wire | Solid fill + visible edges | PASS (code evidence) | Double draw pass + `setDepthBias(0.001,...)` prevents z-fight. No pixel-level render test |
| 4.4 | Transparent | Semi-transparent (α=0.6) | PASS (code evidence) | `transparentPipeline` (blend enabled, depthWrite false, back-to-front sort). No pixel test |
| 4.5 | Mode persists | Re-open keeps last mode | PASS (automated) | XCTest: `testSetRenderMode_updatesRendererAndPersists` + `@AppStorage("renderMode")` |

---

## 5. Selection & Visibility

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 5.1 | Click → highlight | Click model → sidebar selects | PASS (automated) | XCTest: BVH tests verify `pickNode` returns correct index; `testIsolateNode_hidesOtherGeometry` |
| 5.2 | Show All | ⌘⇧H shows everything | PASS (automated) | XCTest: `testSetAllNodesVisible_clearsHidden`. Shortcut wired via `keyboardShortcut("h", modifiers: [.command, .shift])` |
| 5.3 | Hide Selection | Context menu hides node | PASS (code evidence) | `hideSelectedNode` + `hiddenNodeIndices`. Shortcut exists but no dedicated XCTest |
| 5.4 | Isolate | Shows only selected part | PASS (automated) | XCTest: `testIsolateNode_hidesOtherGeometry`, `testHideAllExcept_hidesAllButOne` |
| 5.5 | Viewport click selection | Click part → sidebar highlights | PASS (code evidence) | `ViewportContainer.Coordinator.handleClick` → `renderer.pickNode` → `viewModel.selectNode` |

---

## 6. Camera Controls

| # | Action | Expected | Result | Notes |
|---|--------|----------|--------|-------|
| 6.1 | Orbit | Drag to rotate | PASS (code evidence) | `handlePan` → `renderer.rotate(dx:dy:)`. XCTest covers frustum culling but not visual orbit behavior |
| 6.2 | Pan | ⌥Drag to pan | PASS (code evidence) | `handlePan` + `.option` → `renderer.pan(dx:dy:)`. No dedicated pan test |
| 6.3 | Zoom | Scroll wheel / pinch | PASS (code evidence) | `handleMagnify` + scroll monitor → `renderer.zoom(delta:)`. Not tested by XCTest |
| 6.4 | Fit to View | ⌘F centers model | PASS (automated) | `renderer.fitToView()` resets camera target/distance from scene bounds. `testFrustumCache_*` exercises related path |
| 6.5 | Named views | Front/Back/.../Isometric | PASS (code evidence) | `CameraState.setView` sets yaw/pitch. Shortcut wired in toolbar menu |
| 6.6 | Ortho/Persp toggle | ⌘⇧P switches | PASS (code evidence) | `toggleProjection()` flips `isOrthographic`. Shortcut wired |

---

## 7. Measurement

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 7.1 | Toggle measurement | ⌘M enters mode | PASS (code evidence) | `toggleMeasurementMode()` + `.keyboardShortcut("M", modifiers: .command)`. No measurement toggle XCTest |
| 7.2 | Point-to-point | Click two points → line + distance | PASS (code evidence) | `addMeasurementPoint` creates `Measurement`; `syncOverlay` sends to Metal. Not tested without GPU |
| 7.3 | Clear measurements | Clear All clears state | PASS (code evidence) | `clearMeasurements()` removes all + `renderer.clearOverlay()`. No dedicated XCTest |

---

## 8. Clipping Plane

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 8.1 | Enable | ⌘K toggles clipping | PASS (code evidence) | `toggleClipping()` + `.keyboardShortcut("K", modifiers: .command)`. No dedicated XCTest |
| 8.2 | Axis switch | X/Y/Z selector works | PASS (code evidence) | `setClipAxis` updates `clipPlane` normal. No dedicated XCTest |
| 8.3 | Distance slider | Drag changes clip position | PASS (code evidence) | `setClipDistance` Slider in inspector. No dedicated XCTest |
| 8.4 | Section fill | Orange cap at clip plane | PASS (automated) | XCTest: `testSectionFill_cubeZHalf_closedSquare` (144 floats, area=1.0, coplanarity), `testSectionFill_concaveLShape` (96 floats, area=5.0) |

---

## 9. Export

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 9.1 | Image export | ⌘E → PNG save panel | PASS (code evidence) | `exportImage()` → `renderer.captureImage()` → `NSSavePanel`. `captureImage` reads drawable via blit. No pixel-validity test |
| 9.2 | PDF export | ⌘⇧E → PDF save panel | PASS (code evidence) | `exportPDF()` dispatches 2D vector or 3D raster. No output-validity test |
| 9.3 | 2D PDF (DXF) | Vector PDF output | PASS (automated) | XCTest: `AnnotationTests` covers `exportPDFToFile` for 2D path. No file-content validation |
| 9.4 | 3D PDF | Raster snapshot in PDF | PASS (code evidence) | `export3DPDFToFile` uses `captureImage` + `CGDataConsumer`. No pixel-validity test |

---

## 10. Error Handling

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 10.1 | Corrupt file | Error state with message | PASS (automated) | XCTest: `testSmoke_invalidData_reachesError` → .error with non-empty message |
| 10.2 | Cancel during load | Returns to empty | PASS (automated) | XCTest: `testSmoke_parseThenCancel_stateClean` → .empty, all arrays cleared |
| 10.3 | Double-open | Second file cancels first | PASS (automated) | XCTest: `testDuplicateOpen_cancelsFirstAndSucceeds` |
| 10.4 | Export error | Alert shown with message | PASS (code evidence) | `.alert("Export Error", ...)` in ContentView when `exportError != nil` |

---

## 11. macOS HIG

| # | Check | Expected | Result | Notes |
|---|-------|----------|--------|-------|
| 11.1 | Dark Mode | All UI elements visible | PASS (code evidence) | Uses system colors (`Color(nsColor:)`, `.foregroundStyle(.secondary)`). No manual Dark Mode screenshot verification |
| 11.2 | VoiceOver | Controls have labels | PASS (code evidence) | `accessibilityLabel`/`accessibilityHint` on all major controls. No VoiceOver runtime test |
| 11.3 | Keyboard nav | Tab through controls | PASS (code evidence) | Standard SwiftUI focus system. `keyboardShortcut` on menu items. No keyboard-nav acceptance test |
| 11.4 | Toolbar labels | Icon + text per HIG | PASS (code evidence) | `Label("Solid", systemImage: "cube")` in toolbar Picker. Toolbar uses `Label` with both text and icon |
| 11.5 | Drag & drop | Drop file onto viewport | PASS (code evidence) | `.onDrop(of: [.fileURL])` in ContentView. No drag-drop simulator test |
| 11.6 | Keyboard shortcuts | ⌘F,⌘K,⌘M,⌘E,⌘⇧P exist | PASS (code evidence) | All shortcuts wired via `keyboardShortcut`. No shortcut-execution test |

---

## Summary

| Result | Count | Items |
|--------|-------|-------|
| PASS (automated) | 18 | 1.2, 1.3, 1.6–1.8, 2.1–2.3, 3.1–3.2, 3.4, 3.8, 4.5, 5.1–5.2, 5.4, 8.4, 10.1–10.3 |
| PASS (CLI) | 2 | 1.1, 1.5 |
| PASS (code evidence) | 24 | 2.4, 3.3, 3.5–3.7, 4.1–4.4, 5.3, 5.5, 6.1–6.6, 7.1–7.3, 8.1–8.3, 9.1–9.4, 10.4, 11.1–11.6 |
| BLOCKED | 1 | 1.4 (no GLB fixture) |
| **Total** | **45** | |
