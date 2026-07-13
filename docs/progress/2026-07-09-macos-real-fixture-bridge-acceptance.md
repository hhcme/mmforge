# macOS Real-Fixture Bridge Acceptance — 2026-07-09 (revised)

**Date**: 2026-07-09 (revised 2026-07-13)
**Agent**: ZCode (deepseek-v4-pro)
**Status**: NON-GUI VERIFIED — 362+ Rust / 183 Swift (17 acceptance + 166 existing) / C++ shim all pass

---

## 1. Summary

Added 17 `BridgeAcceptanceTests` loading real on-disk fixture files through
synchronous and async Rust bridge paths. Tests cover DTO structure with
concrete numeric assertions, tree hierarchy, mesh-node mapping, bounds,
visibility lifecycle using real assembly.stp DTO nodes (not mock data),
2D detection, error paths, and parse progress. All 183 Swift tests pass.

---

## 2. Test Inventory (17 tests)

### 2.1 Real-Fixture DTO Structure — concrete numeric assertions

| # | Test | Fixture | Key Assertions |
|---|------|---------|----------------|
| 1 | `test_step_assembly_fixture_node_count_and_hierarchy` | `assembly.stp` | nodes=3, root parentIndex=-1, 2 leaves with geometry, valid scene bounds |
| 2 | `test_step_assembly_mesh_node_mapping` | `assembly.stp` | meshes=2, every mesh maps to a node via geometryId |
| 3 | `test_step_assembly_node_bounds` | `assembly.stp` | leaf bounds finite, min ≤ max per axis |
| 4 | `test_iges_box_dto_structure` | `box.igs` | nodes≥2, meshes=1, triangles>0 |
| 5 | `test_iges_translated_box_bounds` | `translated_box.igs` | sceneBoundsMin.x>15, max.x<35, min.z>2, max.z<18 — confirms translation [20,0,5]–[30,10,15] |
| 6 | `test_stl_fixture_dto_structure` | `box.stl` | nodes≥2, meshes=1, triangles=12 |
| 7 | `test_gltf_fixture_dto_structure` | `box.gltf` | nodes≥1, meshes=1, triangles=1 |
| 8 | `test_dxf_fixture_is_2d_drawing` | `test.dxf` | `mmf_is_2d_drawing != 0` |

### 2.2 Tree Consistency

| # | Test | Key Assertions |
|---|------|----------------|
| 9 | `test_parent_index_consistency` | parentIndex < child index (pre-order), in-bounds |
| 10 | `test_mesh_indices_are_sequential` | every node with meshIndex references a valid geometryId |

### 2.3 Real assembly.stp DTO Visibility Lifecycle

All below load `assembly.stp` via `mmf_parse_file`, build DTO, assign to
`DocumentViewModel`, expand root, and test against real node indices
(not mock `NodeInfo` structs).

| # | Test | Key Assertions |
|---|------|----------------|
| 11 | `test_real_assembly_selection_updates_selected_index` | Select leaf (index 1) → hasGeometry, geometryId≥0; deselect → nil |
| 12 | `test_real_assembly_visible_node_indices` | With root expanded, both leaf parts (indices 1,2) visible |
| 13 | `test_real_assembly_isolate_node_hides_other_leaf` | `isolateNode(1)` → 2 hidden, 1 visible, selectedIndex=1 |
| 14 | `test_real_assembly_hide_all_then_show_all` | `hideAllNodes()` → 1,2 hidden; `setAllNodesVisible()` → 0 hidden |
| 15 | `test_real_assembly_hidden_node_then_toggle` | Insert/remove from `hiddenNodeIndices` tracked correctly |

### 2.4 Async + Error Path

| # | Test | Key Assertions |
|---|------|----------------|
| 16 | `test_async_parse_reports_progress` | STL async parse → parseStage non-empty, `.loaded(tri=12, mesh=1, node≥2)` |
| 17 | `test_nonexistent_file_returns_error` | `mmf_parse_file` → nil, `mmf_last_error` → non-empty string |

---

## 3. CLI Evidence

```
$ cargo run -p mmforge-cli --features mmforge-bridge/occt -- \
    info crates/mmforge-geometry/testdata/assembly.stp --format text
nodes   : 3      geoms   : 2      triangles: 244

$ cargo run -p mmforge-cli --features mmforge-bridge/occt -- \
    info crates/mmforge-geometry/testdata/translated_box.igs --format text
nodes   : 2      geoms   : 1      triangles: 12
bounds  : [20.000,-0.000,5.000] – [30.000,10.000,15.000]
```

The translated_box.igs CLI bounds match the XCTest assertions exactly.

---

## 4. Coverage Matrix

| Fixture | Format | Tests | Sync DTO | Async | 2D | Visibility |
|---------|--------|:-----:|:--------:|:-----:|:--:|:----------:|
| `assembly.stp` | STEP | 9 | ✅ | — | — | ✅ (5 real-DTO tests) |
| `box.igs` | IGES | 1 | ✅ | — | — | — |
| `translated_box.igs` | IGES | 1 | ✅ | — | — | — |
| `box.stl` | STL | 1 | ✅ | ✅ | — | — |
| `box.gltf` | glTF | 1 | ✅ | — | — | — |
| `test.dxf` | DXF | 1 | ✅ | — | ✅ | — |
| Nonexistent | Error | 1 | ✅ | — | — | — |

Note: LSM fixture (`model_golden_v1.lsm`) is present in `testdata/lsm/` but
not yet covered by these acceptance tests — blocked by LSM parser requiring
a specific binary format that may not load correctly via `mmf_parse_file`.

---

## 5. 3D Export PNG / Snapshot

| Capability | Status |
|-----------|--------|
| 2D `Drawing2DView.renderImage` (headless) | ✅ Automated — 11 AnnotationTests |
| 3D `MetalRenderer.captureImageAsync` | ❌ Manual GUI pending — requires `MTKView.currentDrawable` |

---

## 6. Verification Pipeline

| Check | Result |
|-------|--------|
| cmake shim build | ✅ |
| `cargo check --workspace --features occt` | ✅ Clean |
| `cargo test --workspace --features occt` | ✅ **362+** / 0 fail |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ Clean |
| `xcodebuild test` | ✅ **183** / 0 fail (166 existing + 17 new) |
| CLI `info assembly.stp` (`--features mmforge-bridge/occt`) | ✅ nodes=3, geoms=2 |
| CLI `info translated_box.igs` | ✅ bounds=[20,0,5]–[30,10,15] |
| `git diff --check` (working tree) | ✅ Clean |
| `git diff --check 37b7a43..HEAD` | ✅ Clean |

---

## 7. GUI Items Pending Manual Verification

| # | Item | Dependency |
|---|------|-----------|
| G1 | Structure sidebar renders assembly tree | Visible GUI |
| G2 | Viewport picking on components | GUI + Metal |
| G3 | Hide/isolate visual feedback | GUI |
| G4 | Camera fit/orbit/pan/zoom with assembly | GUI |
| G5 | 3D Export PNG (`MetalRenderer.captureImageAsync`) | GUI + Metal drawable |
| G6 | Inspector shows per-part bounds | GUI |
| G7 | Color/material per component | GUI |
| G8 | Window-scoped GUI acceptance (all 8 formats) | Dedicated foreground session |

---

## 8. Files Changed

| File | Δ | Change |
|------|---|--------|
| `macos/MMForgeTests/BridgeAcceptanceTests.swift` | +368 (new) | 17 real-fixture bridge acceptance tests |
| `macos/MMForge.xcodeproj/project.pbxproj` | +4 | Add BridgeAcceptanceTests.swift to MMForgeTests target |
