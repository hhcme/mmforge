# macOS Alpha Usability Hardening — 2026-07-06

**Date**: 2026-07-06
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — 12 files changed, +774/-61, 155 Swift + 340 Rust tests pass

---

## Summary

This batch performs a macOS Alpha trialability hardening pass over the
current mmforge working tree.  It audits and fixes prior uncommitted
runtime-performance and large-model-usability changes, then implements
per-mesh material color rendering, STEP/IGES OCCT messaging, export
stability, HIG/VoiceOver/shortcut polish, and comprehensive tests.

Two code-review passes corrected: (1) `captureImageAsync` timeout
correctness and thread safety, and (2) `mesh_base_colors` storage format
from flat Vec to HashMap keyed by geometry_id.

---

## 1. Audit & Fix of Prior Uncommitted Changes

### 1.1 `detect_format_name` — VERIFIED

**Files**: `crates/mmforge-bridge/src/lib.rs:178`, `crates/mmforge-bridge/src/job.rs:226-238`

The new `detect_format_name()` correctly calls `dxf_detector::detect_dxf`,
`stl_parser::detect_stl`, `gltf_parser::detect_gltf`, and
`iges_detector::detect_iges` — all four are `pub`.  Detection cascade
matches `parse_with_detection()`.  Format-specific stage text (e.g.
"STL detected — parsing") now appears in the loading UI.

### 1.2 CamHash Quantization — VERIFIED

**File**: `MetalRenderer.swift:228-241`

`CamHash.init` quantizes angular values (~0.5°) and linear (~0.01) before
hashing.  `Equatable` is auto-synthesized on quantized stored properties.
`lastFrustumCamHash` init uses `tx:-1, ty:-1, tz:-1` ensuring first
frame always triggers a frustum scan.

### 1.3 StructureSidebar — REGRESSION FIXED

**File**: `StructureSidebar.swift:150-173`

Restored `List(selection: Binding)` with `Section("Product Structure")`,
replacing the prior `ScrollView + LazyVStack + onTapGesture` which lost
keyboard navigation, type-to-select, and VoiceOver row navigation.
SwiftUI `List` on macOS uses `NSTableView` underneath (cell reuse).
The real performance bottlenecks (O(n) search filter, O(n) subtree walk)
were already fixed by the 200ms debounce and `hasVisibleDescendants`
cache from the prior rounds.

---

## 2. Per-Mesh Material Color Support

### 2.1 Rust — HashMap<geometry_id, [f32;4]>

**File**: `crates/mmforge-bridge/src/lib.rs`

`MmfDocument.mesh_base_colors` is a `HashMap<u32, [f32; 4]>` keyed by
`geometry_id`.  Pre-computed in `build_document()` by resolving
`RenderPacket.instances` (mesh_id → material_id → base_color).

New C ABI:

| Function | Signature |
|----------|-----------|
| `mmf_mesh_base_color(doc, index, out_rgba)` | Looks up mesh at `index`, gets its `geometry_id`, queries HashMap |
| `mmf_chunk_mesh_base_color(doc, chunk, mesh, out_rgba)` | Same via chunk mesh's `geometry_id` |
| `mmf_occt_available()` | Delegates to `mmforge_geometry::is_occt_available()` which checks `cfg!(occt_found)` |

### 2.2 Swift Bridge & DTO

**Files**: `RustBridge/RustBridge.swift:6-24`, `RustBridge/mmforge_bridge.h`

- `RenderPacketDTO.Mesh` carries `materialColor: simd_float4`
- `buildDTO()` reads `mmf_mesh_base_color()` per mesh
- `uploadChunk()` reads `mmf_chunk_mesh_base_color()` per chunk mesh
- Header declares all three new C functions

### 2.3 Metal Rendering

**File**: `Metal/MetalRenderer.swift`

- `GPUMesh` has `materialColor: simd_float4`
- `upload()` accepts `materialColor` (default `[0.7, 0.7, 0.72, 1.0]`)
- `drawPass()` uses `mesh.materialColor` for base color; `nodeColorOverrides` take priority

---

## 3. STEP/IGES OCCT Messaging

### 3.1 Error Enrichment

**File**: `MMForgeDocument.swift:1464`

`DocumentViewModel.enrichErrorMessage(_:fileExtension:)` (nonisolated static) adds:
- STEP/IGES + OCCT error → full build instructions (brew, cmake, cargo --features, Xcode rebuild)
- STEP/IGES + generic error → note about OCCT dependency
- Non-STEP/IGES → passthrough unchanged

### 3.2 OCCT Inspector Status

**File**: `InspectorPanel.swift:542`

Inspector "About" section shows "OCCT: Available" (green) or
"OCCT: Not Installed" (secondary) via `mmf_occt_available()`.
Formerly used `cfg!(feature = "occt")` (requested but not proven);
now uses `mmforge_geometry::is_occt_available()` which checks
`cfg!(occt_found)` — set by `build.rs` only when headers, libraries,
and the C ABI shim were actually located and linked.

---

## 4. Export Stability — captureImageAsync

**File**: `Metal/MetalRenderer.swift:945-1010`

**Final implementation**: `withCheckedContinuation` + `NSLock`-protected
single-resume + `DispatchQueue.global().asyncAfter` timeout.

- **GPU path**: `addCompletedHandler` fires → checks `cmdBuf.status` →
  on success builds `NSImage` via `buildImage()` static helper; on
  `.error` returns nil.
- **Timeout path**: `asyncAfter` fires → returns nil immediately.
  Does NOT touch the same `cmdBuf` (GPU may be genuinely stuck).
- **Thread safety**: `NSLock` guards a `resolved` flag inside a
  `finish` closure; both paths call `finish(nil)` or `finish(image)`.
  First-come-first-served; continuation resumed exactly once.

The old synchronous `captureImage()` (pre-existing sync path) is unchanged.

---

## 5. HIG / VoiceOver / Keyboard Shortcuts

| Addition | File | Detail |
|----------|------|--------|
| Render mode menu (Cmd+1..4) | `MMForgeApp.swift` | New `CommandMenu("Render")` with Cmd+1=Solid, 2=Wireframe, 3=Solid+Wire, 4=X-Ray |
| 3D viewport VoiceOver label | `ViewportContainer.swift:220-228` | Dynamic label: "3D model viewport" or "3D viewport — selected: <name>" |
| Removed duplicate `updateNSView` | `ViewportContainer.swift:230` | Was empty stub; now unified into the VoiceOver-aware version |

### Complete Keyboard Shortcut Map

| Key | Action |
|------|--------|
| Cmd+O | Open file |
| Cmd+S | Toggle sidebar |
| Cmd+I | Toggle inspector |
| Cmd+F | Fit to view |
| Cmd+E | Export image |
| Cmd+Shift+E | Export PDF |
| Cmd+K | Toggle clipping |
| Cmd+M | Toggle measurement |
| Cmd+Shift+P | Toggle projection |
| Cmd+Shift+A | Select root |
| Cmd+Shift+H | Show all |
| Cmd+1..4 | Render mode |
| Escape | Cancel parse |
| Arrows | Sidebar navigation |
| Click | Pick node |
| Drag / Alt-Drag / Pinch / Scroll | Orbit / Pan / Zoom |

---

## 6. Rendering Consistency (Code-Review Verified)

The `drawPass` function uses a single code path for all four modes:

| Check | Solid | Wire | Solid+Wire | Transparent |
|-------|-------|------|------------|-------------|
| `mesh.visible` | ✓ | ✓ | ✓ | ✓ |
| `frustumCulledIndices` | ✓ | ✓ | ✓ | ✓ |
| `selectedNodeIndex` highlight | ✓ | ✓ | ✓ (solid pass only) | ✓ |
| `clipPlane` shader discard | ✓ | ✓ | ✓ | ✓ |
| `nodeColorOverrides` | ✓ | ✓ | ✓ | ✓ |
| `mesh.materialColor` | ✓ | ✓ | ✓ | ✓ |
| Back-to-front sort | — | — | — | ✓ |
| Depth bias (wire overlay) | — | — | ✓ (0.001 bias) | — |

- **Multi-mesh nodes**: `setHiddenNodes` iterates ALL `gpuMeshes` matching the node's `nodeIndex`.
- **Hidden/Isolated**: `hiddenNodeIndices` → `setHiddenNodes` → each `GPUMesh.visible` updated.
- **Known limitation**: STEP/IGES B-Rep doesn't carry per-face material colors; only mesh-based formats (glTF) populate `RenderPacket.materials`.

---

## 7. Tests

| Test | Lang | What |
|------|------|------|
| `is_occt_available_returns_bool` | Rust | `mmforge_geometry::is_occt_available()` returns bool |
| `occt_available_returns_zero_or_one` | Rust | `mmf_occt_available()` returns 0 or 1 |
| `mesh_base_color_returns_valid_rgba_for_valid_mesh` | Rust | Flat mesh base color via C ABI; OOB returns -1 |
| `chunk_mesh_base_color_matches_flat_lookup` | Rust | Full flat↔chunk equivalence: builds streaming chunks, verifies every chunk mesh color equals its flat counterpart by geometry_id |
| `testEnrichErrorMessage_stepWithoutOCCT_getGuidance` | Swift | STEP+OCCT error → "brew install" |
| `testEnrichErrorMessage_igesWithoutOCCT_getGuidance` | Swift | IGES+OCCT error → guidance |
| `testEnrichErrorMessage_stepGenericError_getNote` | Swift | Generic STEP → OCCT note |
| `testEnrichErrorMessage_nonSTEPFormat_passthrough` | Swift | STL error → unchanged |
| `testEnrichErrorMessage_dxfFormat_passthrough` | Swift | DXF error → unchanged |
| `testMeshDTO_materialColorField` | Swift | DTO carries `materialColor` |
| `testRenderMode_allCasesExist` | Swift | RawValues 0-3 exist; 4 is nil |
| `testOcctAvailable_returnsZeroOrOne` | Swift | `mmf_occt_available()` binding |
| `testCaptureImageAsync_guardsEarlyExit` | Swift | headless MTKView → nil (early guard) |

---

## 8. Verification: Automated vs Manual vs Code Review

### 8.1 Automated (Tests Pass)

| Thing Verified | Test |
|---------------|------|
| Hash-based mesh_base_colors is correct | `chunk_mesh_base_color_matches_flat_lookup` (Rust) |
| OCCT availability C ABI + Swift binding | `occt_available_returns_*` + `testOcctAvailable_*` |
| Error message enrichment for 5 cases | 5 × `testEnrichErrorMessage_*` |
| Material color DTO struct | `testMeshDTO_materialColorField` |
| Render mode rawValue enum | `testRenderMode_allCasesExist` |
| captureImageAsync nil on no-drawable | `testCaptureImageAsync_guardsEarlyExit` |
| CString path (no UB) | Implicit — all STL-parsing tests depend on `parse_test_stl_box` |
| Prior tests still pass | 155 Swift + 340 Rust — full regression |

### 8.2 Code Review (Reasoning Verified, Hard to Automate)

| Thing Verified | Reasoning |
|---------------|-----------|
| `captureImageAsync` NSLock prevents data race on `resolved` | Two threads (GPU handler, Dispatch timer) — lock-protected check-and-set |
| `captureImageAsync` timeout does not double-resume | `resolved` flag inside lock; `finish` closure is single-shot |
| `captureImageAsync` timeout does not touch stuck cmdBuf | Timeout path only calls `finish(nil)` — no `waitUntilCompleted` |
| `captureImageAsync` error→nil in both paths | `cmdBuf.status == .error` guard before `buildImage` call |
| HashMap<geometry_id,color> lookup is O(1) and correct for non-contiguous IDs | HashMap keyed by original `RenderMesh.geometry_id`; both flat and chunk paths use same key |
| StructureSidebar `List` is lazy (NSTableView cell reuse) | macOS SwiftUI `List` uses `NSTableView` underneath — verified by Apple documentation |

### 8.3 MiMo Manual GUI Acceptance (Not Automated)

Run these by hand on a macOS host with Metal GPU:

| Check | How | Expected |
|-------|-----|----------|
| Open box.gltf — material colors render | `open -a MMForge box.gltf` | Box faces show their source-file colors, not uniform grey |
| Open box.stl — still works | `open -a MMForge box.stl` | Box shows grey default; orbit/pan/pick work |
| Open test.dxf — 2D drawing | `open -a MMForge test.dxf` | Lines visible; layer panel toggles work |
| Open PQ-04909-A.STEP without OCCT | `open -a MMForge PQ-04909-A.STEP` | Error message with OCCT build guidance |
| Open box.igs without OCCT | `open -a MMForge box.igs` | Error message with format note |
| Export Image (⌘E) — STL/glTF/DXF | Menu → Export → Export Image | Save panel appears; saved PNG contains current viewport |
| Export PDF (⌘⇧E) — STL/DXF | Menu → Export → Export PDF | Save panel appears; saved PDF renderable |
| Render modes (Cmd+1..4) | Cycle through modes on loaded STL/glTF | Each mode visually distinct |
| Sidebar keyboard arrows | Load STL, press ↑↓ in sidebar | Selection moves; inspector updates |
| Inspector "About" OCCT status | Load any file, open Inspector → Settings → About | Shows "OCCT: Not Installed" (no OCCT) or "Available" |
| Clip plane toggle (⌘K) | Load STL, press ⌘K | Clip section visible; distance slider works |
| Measurement (⌘M) | Click two points on STL | Distance label between points |

---

## 9. Verification Suite (Final)

| Command | Result |
|---------|--------|
| `xcodebuild test -project MMForge.xcodeproj -scheme MMForge -derivedDataPath build` | **155/155 pass** |
| `cargo test --workspace` | **340 pass** (53 bridge, 8 CLI, 30 integration, 97 core, 39 DXF, 6 IGES, 12 STEP, 6 geometry, 89 render) |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `bash docs/scripts/perf-baseline.sh` | STEP/IGES/STL/DXF pass; glTF CLI NOT SUPPORTED (known) |
| `git diff --check` | **clean** |

---

## 10. Performance Comparison

| Metric | Before This Batch | After |
|--------|------------------|-------|
| Frustum re-scan trigger | Every pixel | ~0.5° / 0.01 quantized |
| Sidebar rendering | LazyVStack (no keyboard) | List(selection:) with arrow-key nav |
| Search filter | Per-keystroke O(n) | 200ms debounced |
| Loading stage text | Generic "detecting" | Format-specific |
| Inspector descendant check | O(subtree) per tick | O(1) generation-guarded cache |
| GPU mesh base color | Hardcoded grey | HashMap<geometry_id, color> from source |
| Export image | Sync GPU stall | NSLock-raced async, 5s timeout → nil |
| STEP/IGES errors | Raw "OCCT not enabled" | Enriched with build guidance |
| OCCT status in UI | None | Inspector "About" section |
| Render mode shortcuts | None | Cmd+1..4 menu + toolbar |
| VoiceOver: 3D viewport | No label | Dynamic label with selection context |
| Chunk streaming color | Default grey | Per-chunk-mesh HashMap lookup |

---

## 11. Files Changed

| File | ΔLines | Change |
|------|--------|--------|
| `crates/mmforge-bridge/src/lib.rs` | +128 | `mesh_base_colors` HashMap, `mmf_mesh_base_color`, `mmf_chunk_mesh_base_color`, `mmf_occt_available` |
| `crates/mmforge-bridge/src/job.rs` | +102 | Format-specific stages, UB fix (CString), +3 tests |
| `crates/mmforge-geometry/src/lib.rs` | +25 | `is_occt_available()` delegating to `cfg!(occt_found)` |
| `macos/MMForge/Metal/MetalRenderer.swift` | +118 | `GPUMesh.materialColor`, `drawPass` uses it; `captureImageAsync` NSLock+timeout; `buildImage` helper |
| `macos/MMForge/Document/MMForgeDocument.swift` | +121 | `enrichErrorMessage` (nonisolated), async export plumbing |
| `macos/MMForgeTests/ProductizationTests.swift` | +199 | +9 tests |
| `macos/MMForge/Views/StructureSidebar.swift` | +34 | Restored `List(selection:)`, kept debounce |
| `macos/MMForge/App/MMForgeApp.swift` | +32 | `RenderCommandsView` Cmd+1..4 |
| `macos/MMForge/Views/InspectorPanel.swift` | -24/+2 | Cached `hasVisibleDescendants`; OCCT status |
| `macos/MMForge/Views/ViewportContainer.swift` | +19 | VoiceOver label; removed duplicate stub |
| `macos/MMForge/RustBridge/RustBridge.swift` | +12 | `materialColor` DTO field; `mmf_chunk_mesh_base_color` |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | +22 | 3 new C function declarations |

---

## 12. Known Remaining Issues

| Sev | Issue |
|-----|-------|
| Med | glTF CLI unsupported (macOS bridge supports it) |
| Med | O(n) CPU frustum culling — GPU-side spatial structure needed |
| Med | STEP/IGES empty without OCCT — needs pre-built shim and CI |
| Med | STEP/IGES B-Rep doesn't propagate per-face material colors |
| Low | No file association Info.plist registration |
| Low | Section fill generates many triangles on large clipped models |

---

## 13. Next Targets

1. macOS Alpha trial package: OCCT shim CI, DMG, code signing
2. glTF CLI support via bridge crate
3. GPU-space frustum culling + BVH ray picking
4. macOS file associations + Quick Look preview
5. OCCT pre-built shim CI workflow
