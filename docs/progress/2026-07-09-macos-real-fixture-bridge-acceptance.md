# macOS Real-Fixture Bridge Acceptance — 2026-07-09

**Date**: 2026-07-09
**Agent**: ZCode (deepseek-v4-pro)
**Status**: NON-GUI VERIFIED — 362+ Rust / 182 Swift (16 new acceptance) / C++ shim all pass

---

## 1. Summary

Added 16 new `BridgeAcceptanceTests` that load real on-disk fixture files
through the synchronous and async Rust bridge, verifying DTO structure,
tree hierarchy, mesh-node mapping, bounds consistency, visibility lifecycle,
selection, 2D detection, error paths, and parse progress.  All pass
alongside the existing 166 Swift tests (182 total).

---

## 2. New Tests — `BridgeAcceptanceTests.swift` (16 tests)

### 2.1 Real-Fixture DTO Structure (sync `mmf_parse_file`)

| # | Test | Fixture | Assertions |
|---|------|---------|------------|
| 1 | `test_step_assembly_fixture_node_count_and_hierarchy` | `assembly.stp` (494-entity AP214) | nodes=3, root parentIndex=-1, 2 leaves with geometry, valid scene bounds |
| 2 | `test_step_assembly_mesh_node_mapping` | `assembly.stp` | meshes=2, geomToNodeIdx map built, every mesh maps to a node |
| 3 | `test_step_assembly_node_bounds` | `assembly.stp` | leaf bounds finite, min ≤ max per axis |
| 4 | `test_iges_box_dto_structure` | `box.igs` | nodes≥2, meshes=1, triangles>0 |
| 5 | `test_iges_translated_box_bounds` | `translated_box.igs` | scene bounds have non-trivial extent |
| 6 | `test_stl_fixture_dto_structure` | `box.stl` | nodes≥2, meshes=1, triangles=12 |
| 7 | `test_gltf_fixture_dto_structure` | `box.gltf` | nodes≥1, meshes=1, triangles=1 |
| 8 | `test_dxf_fixture_is_2d_drawing` | `test.dxf` | `mmf_is_2d_drawing == true` |

### 2.2 Tree Consistency

| # | Test | Assertions |
|---|------|------------|
| 9 | `test_parent_index_consistency` | parentIndex < child index (pre-order guarantee), in-bounds |
| 10 | `test_mesh_indices_are_sequential` | every node with meshIndex references a valid geometryId |

### 2.3 Visibility Lifecycle (model layer, no renderer)

| # | Test | Assertions |
|---|------|------------|
| 11 | `test_selection_updates_selected_index` | selectedIndex set/clear |
| 12 | `test_hide_isolate_direct_hidden_indices` | hiddenNodeIndices directly set and read |
| 13 | `test_isolate_node_hides_others` | isolateNode(1) hides other geometry |
| 14 | `test_hide_all_then_show_all_direct` | hideAllNodes → 2 hidden, setAllNodesVisible → 0 hidden |

### 2.4 Async Parse Path

| # | Test | Assertions |
|---|------|------------|
| 15 | `test_async_parse_reports_progress` | STL async parse → parseStage non-empty, state=.loaded with triangle/mesh/node counts |
| 16 | `test_nonexistent_file_returns_error` | mmf_parse_file → nil, mmf_last_error → non-empty message |

---

## 3. Coverage Matrix

| Fixture | Format | Tests | Sync | Async | 2D |
|---------|--------|:-----:|:----:|:-----:|:--:|
| `assembly.stp` | STEP | 3 | ✅ | — | — |
| `box.igs` | IGES | 1 | ✅ | — | — |
| `translated_box.igs` | IGES | 1 | ✅ | — | — |
| `box.stl` | STL | 1 | ✅ | ✅ | — |
| `box.gltf` | glTF | 1 | ✅ | — | — |
| `test.dxf` | DXF | 1 | ✅ | — | ✅ |
| Nonexistent | Error path | 1 | ✅ | — | — |

---

## 4. 3D Export PNG / Snapshot

| Capability | Status |
|-----------|--------|
| 2D `Drawing2DView.renderImage` (headless) | ✅ Automated — 11 AnnotationTests |
| 3D `MetalRenderer.captureImageAsync` | ❌ Manual GUI pending — requires `MTKView.currentDrawable` |
| 3D `exportImage()` via `DocumentViewModel` | ❌ Manual GUI pending — wraps `captureImageAsync` |

The 3D export path requires a valid Metal drawable which only exists after
a frame is rendered to screen.  No headless path available on macOS without
an on-screen `MTKView`.

---

## 5. Verification Pipeline

| Check | Result |
|-------|--------|
| cmake shim build | ✅ |
| `cargo check --workspace --features occt` | ✅ Clean |
| `cargo test --workspace --features occt` | ✅ **362+** / 0 fail |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ Clean |
| `xcodebuild test` | ✅ **182** / 0 fail (166 existing + 16 new) |
| CLI `info assembly.stp` | ✅ nodes=3, geoms=2 |
| `git diff --check` + `37b7a43..HEAD` | ✅ Clean |

---

## 6. GUI Items Pending Manual Verification

| # | Item | Dependency |
|---|------|-----------|
| G1 | Structure sidebar renders assembly tree | Visible GUI |
| G2 | Viewport picking on components | GUI + Metal |
| G3 | Hide/isolate visual feedback | GUI |
| G4 | Camera fit/orbit/pan/zoom with assembly | GUI |
| G5 | 3D Export PNG | GUI + Metal drawable |
| G6 | Inspector shows per-part bounds | GUI |
| G7 | Color/material per component | GUI |
| G8 | Window-scoped GUI acceptance (all 8 formats) | Dedicated foreground session |

---

## 7. Files Changed

| File | Δ | Change |
|------|---|--------|
| `macos/MMForgeTests/BridgeAcceptanceTests.swift` | +340 (new) | 16 real-fixture bridge acceptance tests |
| `macos/MMForge.xcodeproj/project.pbxproj` | +4 | Add BridgeAcceptanceTests.swift to MMForgeTests target |

---

## 8. Commit Range

`37b7a43..HEAD` — 7 commits, all git diff --check clean.
