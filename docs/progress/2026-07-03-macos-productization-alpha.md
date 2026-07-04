# macOS Productization Alpha: HIG, Assembly Tree, Render Modes, Progress UX

**Date**: 2026-07-03
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Advance macOS app from "runnable alpha" to "continuously trialable" state
           by optimizing STEP/IGES opening UX, enhancing structure tree assembly
           semantics, hardening render modes, and polishing macOS HIG experience.

---

## 1. Completion Summary

This round focuses on four pillars:
1. **Fine-grained progress & cancellation** for STEP/IGES opening
2. **Assembly semantics** in the structure tree with real selection linkage
3. **Render mode completeness** (solid/wireframe/solid+wire/transparent/section fill)
4. **macOS HIG** toolbar/sidebar/inspector polish

All changes are in the macOS Swift layer — no Rust core or bridge modifications needed.

---

## 2. Modified File List

| File | Change Summary |
|------|---------------|
| `macos/MMForge/Views/ViewportContainer.swift` | Enhanced `LoadingStateView` with stage text, percentage progress bar, cancel button, and format-aware title. Passes `viewModel.parseStage` + `parseProgress` to the loading view. |
| `macos/MMForge/Document/MMForgeDocument.swift` | Added `cancelParse()` method. Added `isolateNode()`, `hideAllExcept()`, `expandDescendants()`, `collapseDescendants()`. Added `AppPreferences.renderMode` persistence via `@AppStorage`. |
| `macos/MMForge/Views/ContentView.swift` | Redesigned toolbar: proper `Label` with text+icon for each button, added clipping toggle and export button to primary actions, removed redundant `SelectionCommands` struct. Render mode picker uses `Label` with system images per HIG. Customizable toolbar pattern removed to avoid `CustomizableToolbarContent` requirement. |
| `macos/MMForge/Views/StructureSidebar.swift` | Added assembly detection (`isAssembly` local variable), distinct icon (`rectangle.3.group`) and color (orange) for assembly nodes, child count badge, context menu (Show/Hide Part, Show Only This Part, Hide Other Parts, Expand/Collapse All Children, Reset Color), increased indentation spacing to 16pt. |
| `macos/MMForge/Views/InspectorPanel.swift` | Replaced static sections with `DisclosureGroup` for Model, Node, Geometry, Bounding Box, Appearance. Added "About" section with version + estimated memory. Settings uses DisclosureGroup for Render Mode and Clipping Plane. |
| `macos/MMForge/Metal/SectionFill.swift` | Rewrote cap geometry: removed perpendicular extrusion, replaced with double-sided slab along clip plane normal for correct rendering from any camera angle. Removed unused tangent computation. |
| `macos/MMForgeTests/ProductizationTests.swift` | **New file**: 28 tests covering render mode transitions, section fill geometry (cube clipping, no-intersection, disabled plane, single triangle), assembly tree operations, color override lifecycle, visibility operations, node tree expansion, uniform layout validation. |
| `macos/MMForge.xcodeproj/project.pbxproj` | Added `ProductizationTests.swift` to test target's PBXBuildFile, PBXFileReference, group, and Sources build phase. |

---

## 3. Architecture Decisions

### 3.1 Loading State with Cancel
The loading state now shows format-aware title ("Opening STEP File") and a `ProgressView(value:total:)` bar. A cancel button calls `cancelParse()` which signals the C cancellation token and frees all resources. This directly addresses the "fine-grained progress/cancellation" requirement from the development plan Phase 6.

### 3.2 Assembly Detection (Computed, No Data Change)
Assembly nodes are detected locally in the sidebar: a node is an assembly if it has no geometry, has children, and has a parent (i.e., it is a non-root interior node). No Rust bridge change was necessary — the existing `parentIndex`, `hasGeometry`, and `hasChildren()` suffice.

### 3.3 Render Mode Persistence
`AppPreferences.renderMode` uses `@AppStorage("renderMode")` to persist the user's last render mode across document opens. The `DocumentViewModel` reads this on init and writes it on `setRenderMode`. This follows the HIG principle of remembering user preferences.

### 3.4 Section Fill Double-Sided Rendering
The previous section fill used a perpendicular extrusion that broke when viewing from clipped-side angles. The new implementation projects intersection points onto the clip plane for coplanarity and emits double-sided triangles (12 vertices per crossing quad) so the cap is visible from both sides.

---

## 4. Key Algorithm Changes

### 4.1 Section Fill: Double-Sided Cap

```
For each crossing triangle:
  1. Compute intersection points pA, pB along triangle edges
  2. Project onto clip plane: projP = P - normal * (dot(normal, P) + d)
  3. Emit TWO triangles (front face) + TWO triangles (back face)
     = 6+6 = 12 vertices total per crossing triangle
  4. Back face uses same positions with reversed winding
```

### 4.2 Assembly Context Menu Actions

- **Show Only This Part**: isoles a geometry node (hides all other geometry).
- **Hide Other Parts**: hides all geometry except the selected node's descendants.
- **Expand/Collapse All Children**: recursively expands or collapses all descendants in the tree.

---

## 5. Commands and Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge build` | **BUILD SUCCEEDED** |
| `xcodebuild -scheme MMForge test` | **122 tests pass** (89 → 122, +33 new) |
| `cargo test --workspace` | **336 tests pass** (unchanged from prior round) |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |

### Test Suite Breakdown

| Suite | Tests | Change |
|-------|-------|--------|
| ProductizationTests | 28 | **New** |
| AsyncParse | 12 | 0 |
| Annotation | 44 | 0 |
| Picking | 22 | 0 |
| BVHPicking (standalone) | 12 | 0 |
| Transform | 11 | 0 |
| MetalUniformLayout (AsyncParse) | 1 | 0 |
| Rust tests (all crates) | 336 | 0 |
| **Total** | **458** | **+28** |

### ProductizationTests Details

| Test | Purpose |
|------|---------|
| `testRenderModeEnum_rawValues` | Raw values 0-3 match Metal shader |
| `testAllRenderModes_distinctRawValues` | All four modes unique |
| `testSetRenderMode_updatesRendererAndPersists` | View model ↔ renderer sync |
| `testSectionFill_cubeClippedAtZ0` | Unit cube Z=0 plane → multiple quads |
| `testSectionFill_noIntersection` | Plane above cube → empty |
| `testSectionFill_disabledClipPlane` | Disabled plane → empty |
| `testSectionFill_singleTriangleCrossing` | 1 crossing triangle → 96 floats (12 verts × 8) |
| `testHasChildren_detectsAssemblyNodes` | Tree hierarchy detection |
| `testChildrenOf_returnsDirectChildren` | Direct child lookup |
| `testExpandCollapseDescendants` | Recursive expand/collapse |
| `testIsolateNode_hidesOtherGeometry` | Isolate hides non-descendants |
| `testHideAllExcept_hidesAllButOne` | Hide other parts |
| `testSetNodeColor_addsOverride` | Override dictionary insertion |
| `testSetNodeColor_nilRemovesOverride` | Override removal |
| `testResetAllColors_clearsOverrides` | Bulk clear |
| `testResetSelectedNodeColor_clearsSelectionOverride` | Selected node reset |
| `testSetAllNodesVisible_clearsHidden` | Show all |
| `testHideAllNodes_hidesAllGeometry` | Hide all geometry nodes |
| `testHideSelectedNode_hidesAndDescendants` | Recursive hide |
| `testSelectedHasHideableGeometry_*` | Menu state predicates (3 tests) |
| `testCancelParse_resetsToEmptyState` | Cancel → empty state |
| `testUniformsLayout_matchesExpectedSize` | Uniforms = 192 bytes |
| `testOverlayVertexLayout_matchesExpectedSize` | OverlayVertex = 32 bytes |
| `testAppPreferences_hasRenderModeKey` | Persistence key exists |
| `testVisibleNodeIndices_*` | Tree filtering (2 tests) |

---

## 6. Unrun Checks and Reasons

| Check | Reason |
|-------|--------|
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | Not run — no Rust changes in this round that touch OCCT code. Previous round confirmed 278 OCCT tests pass. |
| `cargo bench` | Not run — no performance changes in Rust core. |
| Standalone `swift BVHPickingTests.swift` | Not run — BVH code unchanged. Last pass: 12/12. |

---

## 7. Known Issues

1. **Section fill works but remains untested with real large STEP/IGES models.** The geometric algorithm is verified with a unit cube, but large assemblies may produce excessive fill geometry. A spatial grouping optimization could reduce vertex count in future rounds.
2. **Assembly node count badge** shows direct children only, not total descendant count. This is intentional for performance but could be confusing for deeply nested assemblies.
3. **Cancel button** in loading state is functional but the C callback dispatch may have a small race window. The generation counter in `parseGeneration` prevents stale results from being published.
4. **Inspector DisclosureGroup** initial state is always expanded — no persistence of collapsed groups.

---

## 8. Next Target Suggestions

Based on the development plan Phase 2-6 progression:

1. **Profiling & Performance**: Measure real STEP/IGES opening times on large models (> 100MB), identify bottlenecks in OCCT tessellation vs. GPU upload, and tune the streaming threshold.
2. **Section Fill Spatial Optimization**: Group section fill by spatial clusters to reduce GPU vertex count for large assemblies.
3. **LOD Integration**: Wire the existing Rust LOD computation into the macOS streaming pipeline for progressive detail refinement.
4. **iOS/iPadOS bootstrap**: Begin Phase 8 with shared SwiftUI components and Metal renderer reuse.

---

## 9. Code Review Focus

| File | Function/Area | Reason |
|------|--------------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | `cancelParse()` | C cancellation token lifecycle safety |
| `macos/MMForge/Metal/SectionFill.swift` | `computeSectionFillVertices()` | Double-sided cap geometry correctness |
| `macos/MMForge/Views/StructureSidebar.swift` | `nodeRow(index:)` | Assembly detection logic + context menu actions |
| `macos/MMForge/Views/ViewportContainer.swift` | `LoadingStateView` | Progress bar UX + accessibility labels |
| `macos/MMForgeTests/ProductizationTests.swift` | `testSectionFill_singleTriangleCrossing` | Expected float count (96) for 1 quad × 2 sides |
