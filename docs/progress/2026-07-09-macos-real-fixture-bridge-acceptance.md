# macOS Real-Fixture Bridge Acceptance — 2026-07-09 (revised 2026-07-13)

**Date**: 2026-07-09 (revised 2026-07-13)
**Agent**: ZCode (deepseek-v4-pro)
**Status**: NON-GUI VERIFIED — 362+ Rust / 199 Swift (33 acceptance + 166 existing) / headless MetalRenderer all pass

---

## 1. Summary

33 `BridgeAcceptanceTests` load real on-disk fixtures through sync/async Rust
bridge paths, covering: DTO structure (concrete numeric + exact-epsilon bounds),
tree hierarchy, mesh-node mapping, headless MetalRenderer acceptance
(geometryId→nodeIndex→GPUMesh, selectNode, toggleNodeVisibility,
hideSelectedNode, isolateSelectedNode, setAllNodesVisible — ALL through formal
VM API), pendingDTO deferred upload, async parse with bound renderer, camera
math (fit/reset/orbit/zoom/named-views), picking, expand/collapse/search tree
operations. All 199 Swift tests pass.

---

## 2. Test Inventory (33 tests)

### 2.1 Real-Fixture DTO (8 tests)
| Fixture | Assertions |
|---------|------------|
| `assembly.stp` (3) | nodes=3, meshes=2, mesh→node, bounds valid |
| `box.igs` (1) | meshes=1, triangles>0 |
| `translated_box.igs` (1) | **6 exact-epsilon bounds**: x∈[19,21]/[29,31], y∈[-1,1]/[9,11], z∈[4,6]/[14,16] |
| `box.stl` (1) | triangles=12, meshes=1, nodes≥2 |
| `box.gltf` (1) | triangles=1, meshes=1 |
| `test.dxf` (1) | `mmf_is_2d_drawing != 0` |

### 2.2 Tree Consistency (2)
- parentIndex < child (pre-order), in-bounds
- meshIndex → valid geometryId

### 2.3 Real-DTO VM Visibility (4 — formal API)
| Test | API Used |
|------|----------|
| selection | `vm.selectNode(1)` / `vm.selectNode(nil)` |
| visibleNodeIndices | root expanded → leaves visible |
| isolate | `vm.isolateNode(1)` → other hidden |
| hide-all/show-all | `vm.hideAllNodes()` / `vm.setAllNodesVisible()` |

### 2.4 Headless MetalRenderer (15 — all formal VM API)
| # | Test | Key Assertion |
|---|------|---------------|
| | geometryId→nodeIndex mapping | 2 meshes, nodeIndex = correct DTO node |
| | **selectNode sync** | `vm.selectNode(1)` → `vm.selectedIndex==1` AND `renderer.selectedNodeIndex==1`; `selectNode(nil)` clears both |
| | toggle visibility | `vm.toggleNodeVisibility(1)` → `hiddenNodeIndices` contains 1 AND GPU mesh `.visible==false`; toggle back restores |
| | hide selected | `vm.hideSelectedNode()` → VM hidden + GPU invisible |
| | isolate selected | `vm.isolateSelectedNode()` → other hidden + GPU invisible, target visible |
| | set-all-visible | `vm.setAllNodesVisible()` → 0 hidden + all GPU meshes `.visible==true` |
| | **pendingDTO** | parse without renderer → setRenderer later → GPU meshes uploaded |
| | **async+bound renderer** | async STL parse with bound renderer → 12 triangles on GPU |
| | camera init | distance>0, target finite |
| | camera fit/reset | fitToView/resetCamera → distance>0, finite yaw/pitch |
| | camera orbit | rotate(dx,dy) → yaw/pitch change |
| | camera zoom | zoom(delta) → distance changes |
| | named views | 7 views all non-crashing; isometric has non-zero yaw/pitch |
| | picking | pickNode returns optional nodeIndex within bounds |

### 2.5 Real-DTO Tree (3)
| Test | Assertion |
|------|-----------|
| expand/collapse | collapseAll → leaves hidden; expandAll → leaves visible |
| search | "Base" filters; clear restores all |
| child count | root has 2, leaves have 0 |

### 2.6 Error + Async (2)
| Test | Assertion |
|------|-----------|
| async parse progress | `.loaded(tri=12, mesh=1, node≥2)` |
| nonexistent file | nil doc, non-empty error |

---

## 3. Coverage Matrix

| Fixture | Format | Tests |
|---------|--------|:-----:|
| `assembly.stp` | STEP | 20 (3 DTO + 4 VM vis + 10 headless renderer + 3 tree) |
| `box.igs` | IGES | 1 |
| `translated_box.igs` | IGES | 1 |
| `box.stl` | STL | 1 (+ async parse uses STL) |
| `box.gltf` | glTF | 1 |
| `test.dxf` | DXF | 1 |
| Nonexistent | Error | 1 |

**LSM**: fixture present in `testdata/lsm/` but not covered — binary format requires specific parser setup.

---

## 4. Verification Pipeline

| Check | Result |
|-------|--------|
| `cargo test --workspace --features occt` | ✅ **362+** / 0 fail |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ Clean |
| `xcodebuild test` | ✅ **199** / 0 fail (33 acc + 166 existing) |
| `git diff --check` (both) | ✅ Clean |

---

## 5. GUI Items Pending Manual Verification

| # | Item | Dependency |
|---|------|-----------|
| G1 | Structure sidebar visual rendering | GUI |
| G2 | Viewport picking visual feedback | GUI + Metal drawable |
| G3 | Camera orbit/pan/zoom gestures | GUI |
| G4 | 3D Export PNG | GUI + Metal drawable |
| G5 | Inspector per-part bounds | GUI |
| G6 | Color/material per component | GUI |
| G7 | Window-scoped GUI acceptance (8 formats) | Foreground session |
| G8 | LSM fixture bridge acceptance | Parser support |
