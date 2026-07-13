# macOS Real-Fixture Bridge Acceptance — 2026-07-09 (revised 2026-07-13)

**Date**: 2026-07-09 (revised 2026-07-13)
**Agent**: ZCode (deepseek-v4-pro)
**Status**: NON-GUI VERIFIED — 362+ Rust / 192 Swift (26 acceptance + 166 existing) / headless MetalRenderer all pass

---

## 1. Summary

26 `BridgeAcceptanceTests` load real on-disk fixture files through sync/async
Rust bridge paths, covering: DTO structure with concrete numeric assertions,
tree hierarchy, mesh-node mapping, bounds (exact epsilon), headless
MetalRenderer acceptance (geometryId→nodeIndex→GPUMesh mapping, selectNode,
toggleNodeVisibility, hideSelectedNode, isolateSelectedNode, setAllNodesVisible,
camera init), expand/collapse/search tree operations — all using real
assembly.stp DTO nodes (no mock data). All 192 Swift tests pass.

---

## 2. Test Inventory (26 tests)

### 2.1 Real-Fixture DTO Structure

| # | Test | Fixture | Key Assertions |
|---|------|---------|----------------|
| 1–3 | STEP assembly (3 tests) | `assembly.stp` | nodes=3, meshes=2, mesh→node mapping, bounds valid |
| 4–5 | IGES (2 tests) | `box.igs`, `translated_box.igs` | meshes=1; translated: exact epsilon bounds |
| 6 | STL | `box.stl` | triangles=12, meshes=1, nodes≥2 |
| 7 | glTF | `box.gltf` | triangles=1, meshes=1 |
| 8 | DXF | `test.dxf` | `mmf_is_2d_drawing != 0` |

### 2.2 translated_box.igs — exact epsilon bounds

```
sceneBoundsMin.x == 20.0 ± 1.0, max.x == 30.0 ± 1.0
sceneBoundsMin.y ==  0.0 ± 1.0, max.y == 10.0 ± 1.0
sceneBoundsMin.z ==  5.0 ± 1.0, max.z == 15.0 ± 1.0
```

All 6 bounds asserted with `XCTAssertEqual(_, accuracy: 1.0)`.

### 2.3 Tree Consistency

| # | Test | Assertions |
|---|------|------------|
| 9 | `test_parent_index_consistency` | parentIndex < child index, in-bounds |
| 10 | `test_mesh_indices_are_sequential` | node.meshIndex → valid geometryId |

### 2.4 Real assembly.stp DTO Visibility (no renderer)

| # | Test | Assertions |
|---|------|------------|
| 11 | selection | select/deselect leaf, verify hasGeometry |
| 12 | visibleNodeIndices | both leaves visible with root expanded |
| 13 | isolate | isolateNode(1) → 2 hidden, 1 visible, selectedIndex=1 |
| 14 | hide-all/show-all | hideAllNodes → 2 hidden, setAllNodesVisible → 0 hidden |

### 2.5 Headless MetalRenderer Acceptance (real DTO → GPU meshes)

Shared `MTKView`/`MetalRenderer` created once (avoids GPU resource conflicts).
Each test calls `makeAssemblyWithHeadlessRenderer()` which: clears meshes,
parses assembly.stp, builds DTO, `vm.setRenderer()` → `vm.uploadToRenderer()`.

| # | Test | VM State | GPU State (via `getGPUMeshes()`) |
|---|------|----------|----------------------------------|
| 15 | geometryId→nodeIndex→GPUMesh | — | 2 meshes, nodeIndex maps to correct DTO node |
| 16 | selectNode | `selectedIndex == 1` | `renderer.selectedNodeIndex == 1` |
| 17 | toggleNodeVisibility | node 1 in hiddenNodeIndices | mesh for nodeIndex=1 `.visible == false`; toggle back restores |
| 18 | hideSelectedNode | node 1 hidden | mesh invisible |
| 19 | isolateSelectedNode | node 2 hidden, 1 not | mesh for 1 visible, mesh for 2 invisible |
| 20 | setAllNodesVisible | hiddenNodeIndices empty | all meshes `.visible == true` |
| 21 | camera init | — | camera.distance > 0, target finite |

### 2.6 Real-DTO Tree Operations (no renderer)

| # | Test | Assertions |
|---|------|------------|
| 22 | expand/collapse | collapseAll → leaves hidden; expandAll → leaves visible |
| 23 | search | "Base" filters visible nodes; clearing restores all |
| 24 | child count | root has 2 children; leaves have 0 |

### 2.7 Async + Error

| # | Test | Assertions |
|---|------|------------|
| 25 | async parse progress | STL → `.loaded(tri=12, mesh=1, node≥2)` |
| 26 | nonexistent file error | nil doc, non-empty error message |

---

## 3. Coverage Matrix

| Fixture | Format | Tests |
|---------|--------|:-----:|
| `assembly.stp` | STEP | 15 (3 DTO + 5 VM visibility + 7 headless renderer) |
| `box.igs` | IGES | 1 |
| `translated_box.igs` | IGES | 1 |
| `box.stl` | STL | 1 |
| `box.gltf` | glTF | 1 |
| `test.dxf` | DXF | 1 |
| Nonexistent | Error | 1 |

**LSM**: fixture present in `testdata/lsm/` but not covered — blocked by binary
format requiring specific parser setup.

---

## 4. Verification Pipeline

| Check | Result |
|-------|--------|
| cmake shim build | ✅ |
| `cargo check --workspace --features occt` | ✅ Clean |
| `cargo test --workspace --features occt` | ✅ **362+** / 0 fail |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ Clean |
| `xcodebuild test` | ✅ **192** / 0 fail (26 acceptance + 166 existing) |
| CLI `info assembly.stp` | ✅ nodes=3, geoms=2 |
| CLI `info translated_box.igs` | ✅ bounds=[20,0,5]–[30,10,15] |
| `git diff --check` (working + range) | ✅ Clean |

---

## 5. GUI Items Pending Manual Verification

| # | Item | Dependency |
|---|------|-----------|
| G1 | Structure sidebar renders assembly tree | Visible GUI |
| G2 | Viewport picking visual feedback | GUI + Metal drawable |
| G3 | Camera orbit/pan/zoom gestures | GUI |
| G4 | 3D Export PNG (`captureImageAsync`) | GUI + Metal drawable |
| G5 | Inspector shows per-part bounds | GUI |
| G6 | Color/material per component | GUI |
| G7 | Window-scoped GUI acceptance (8 formats) | Dedicated foreground session |
| G8 | LSM fixture bridge acceptance | Parser format support |

---

## 6. Files Changed

| File | Δ | Change |
|------|---|--------|
| `macos/MMForgeTests/BridgeAcceptanceTests.swift` | ~580 (new) | 26 real-fixture bridge + headless MetalRenderer acceptance tests |
| `macos/MMForge.xcodeproj/project.pbxproj` | +4 | Add BridgeAcceptanceTests.swift to MMForgeTests target |
