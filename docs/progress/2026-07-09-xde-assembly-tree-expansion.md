# XDE Assembly Tree Recursive Expansion — 2026-07-09

**Date**: 2026-07-09
**Agent**: ZCode (deepseek-v4-pro)
**Status**: VERIFIED WITH REAL OCCT 7.9.3 (Homebrew arm64) — v2 review fixes applied

**Verification levels**:
- ✅ **Real OCCT passed** — C++ shim compiled/linked, 360+ Rust tests pass, CLI produces tree output
- ✅ **IGES bounds parity** — `build_iges_model_from_data` now uses registry post-transform mesh bounds (same as STEP)
- ✅ **git diff --check** — working tree clean (trailing whitespace in assembly.stp fixture fixed)
- ❌ **GUI not verified** — macOS app not launched (foreground GUI excluded per policy)

---

## 1. Summary

This batch replaces the flat `GetFreeShapes()` approach in STEP/IGES parsing
with recursive XDE product-structure traversal. Instead of one synthetic
`"STEP_Assembly"` root → N flat children, the pipeline now:

- Walks the XDE assembly tree via `XCAFDoc_ShapeTool::IsAssembly` / `GetComponents` / `GetReferredShape` / `GetLocation`
- Produces a proper hierarchy: assembly nodes (structural, no geometry) and leaf nodes (solid/part, with geometry + local transform)
- Tessellates each leaf solid independently → per-part mesh in `TessellationRegistry`
- Assigns stable `node_id`/`geometry_id` in tree pre-order
- Passes `local_transform` (4×4 from XDE `TopLoc_Location`) through to `LsmModel::Node`

No changes to renderer (`RenderPacket`), Metal shaders, or Swift UI —
`geomIdToNodeIdx` mapping already supports per-part meshes.

---

## 2. Architecture

### 2.1 Before (flat)
```
STEP_Assembly (geometry: None)
  ├── Widget [Solid]  (GeometryId:0)
  ├── Bolt [Solid]    (GeometryId:1)
  └── Bracket [Solid] (GeometryId:2)
```
All children at same level, `local_transform: IDENTITY`, no product structure.

### 2.2 After (tree)
```
Assembly (geometry: None, bounds: union)
  ├── SubAssembly_A (geometry: None)
  │   ├── Widget [Solid]  (GeometryId:0, transform: T_widget)
  │   └── Bolt [Solid]    (GeometryId:1, transform: T_bolt)
  └── Bracket [Solid]     (GeometryId:2, transform: T_bracket)
```
Real hierarchy with transforms, assembly nodes have no mesh, leaf nodes tessellated individually.

---

## 3. Changes

### 3.1 C++ Shim (`mmforge_occt_shim.h/.cpp`)

| Change | Detail |
|--------|--------|
| ABI version | 3 → 4 |
| `MmfTreeNode` struct | parent_index, name, type, bbox, is_assembly, shape, location[16] |
| `buildAssemblyTree()` | Recursive XDE walk using `IsAssembly`/`GetComponents`/`GetReferredShape`/`GetLocation` |
| `buildNodeRecursive()` | Per-label: extracts name (TDataStd_Name), location (gp_Trsf), bbox (BRepBndLib) |
| Synthetic root | Created for files with multiple free shapes or non-assembly roots; named "Assembly" |
| Assembly bbox | Computed bottom-up as union of children |
| 4 new C ABI functions | `mmforge_shape_tree_node_count`, `mmforge_shape_get_tree_node` (STEP + IGES variants) |
| `ReaderWrapper`/`IgesReaderWrapper` | Added `tree_nodes`, `name_store`, `shape_store` vectors |

### 3.2 Rust FFI (`sys.rs`, `adapter.rs`, `build.rs`)

| File | Change |
|------|--------|
| `sys.rs` | `MmfTreeNode` repr(C) struct, 4 new extern "C" declarations |
| `adapter.rs` | `TreeNode` struct (parent_index, name, shape_type, bounds, is_assembly, transform: Mat4) |
| `adapter.rs` | `enum_tree_nodes()` / `tree_leaf_shape_ptr()` on both adapters — empty fallback when `!occt_found` |
| `adapter.rs` | `as_iges_ptr()` accessor for IGES shape handle construction |
| `build.rs` | 4 new symbols in `REQUIRED_SHIM_SYMBOLS` |
| `adapter.rs` | Link probe test updated with 4 new symbols |

### 3.3 Step/Iges Readers

| File | Change |
|------|--------|
| `step_reader.rs` | `StepData.tree_nodes: Vec<TreeNode>` (`#[cfg(feature = "occt")]`) |
| `iges_reader.rs` | `IgesData.tree_nodes: Vec<TreeNode>` |
| `step_reader.rs` | `occt_read_step_with_tessellation()` — iterates tree, tessellates leaf nodes only |
| `iges_reader.rs` | Same for IGES — tree-based tessellation with `IgesShapeHandle` |

### 3.4 Format Parsers

| File | Change |
|------|--------|
| `mmforge-format-step/src/parser.rs` | Tree-based `LsmModel` building in both `occt_parse_with_progress` and `build_step_model_from_data` |
| `mmforge-format-iges/src/parser.rs` | Same for IGES |
| Both | Flat-shape fallback when tree is empty |
| `parser.rs` (STEP) | E2E test updated: checks leaf count, not "STEP_Assembly" name |

### 3.5 What Does NOT Change

- **RenderPacket / RenderMesh**: per-mesh instances already supported
- **Swift `DocumentViewModel.uploadToRenderer()`**: `geomIdToNodeIdx` mapping unchanged
- **MetalRenderer / Shaders.metal**: no changes
- **StructureSidebar / Picking / Hide-Isolate**: all use `nodeIndex` (stable)

---

## 4. Verification Status

### 4.1 Real OCCT 7.9.3 (Homebrew arm64)

| Check | Result |
|-------|--------|
| `cmake .. && make` (shim rebuild) | **Compiled + linked** |
| `nm libmmforge_occt_shim.a` (symbol check) | **All 37 symbols present** |
| `cargo check --workspace --features occt` | **Clean** (0 errors) |
| `cargo test --workspace --features occt` | **360+ passed, 0 failed** |
| `cargo clippy --workspace --features occt -- -D warnings` | **Clean** (0 warnings) |
| CLI `info PQ-04909-A.STEP` | **node_count=2, geoms=1, tri=4554** |
| CLI `info assembly.stp` | **node_count=3, geoms=2, tri=244** |
| CLI `info box.igs` | **node_count=2, geoms=1, tri=12** |
| `git diff --check` (working tree) | **Clean** |

### 4.2 Assembly Fixture Evidence

```
$ mmforge info crates/mmforge-geometry/testdata/assembly.stp
file    : assembly.stp
format  : STEP
nodes   : 3        ← root assembly + 2 leaf components (>2 ✓)
geoms   : 2        ← per-part mesh (>1 ✓)
triangles: 244      ← real tessellated geometry
bounds  : [-3,-3,0] – [10,10,15]
```

```
$ mmforge info crates/mmforge-geometry/testdata/box.igs
file    : box.igs
format  : IGES
nodes   : 2        ← root assembly + 1 leaf component
geoms   : 1
triangles: 12
bounds  : [0,0,0] – [1,1,1]
```

The 494-entity AP214 STEP assembly contains:
- Root `ASSEMBLY` (Compound, no mesh, no geometry)
- `Base_Box` — 10×10×10 box solid (12 triangles)
- `Pillar_Cylinder` — radius 3, height 15 cylinder (232 triangles)

### 4.3 Per-Part Transform Baking

XDE component location transforms are pre-baked into tessellated mesh vertices:
- Positions transformed by full `Mat4` (translation + rotation)
- Normals transformed by `Mat3` (rotation only)
- Bounds recomputed from transformed positions
- Node bounds use registry mesh bounds (post-transform) for AABB consistency

This ensures picking, hide/isolate, and viewport rendering are all consistent
without requiring `RenderPacket` or Metal renderer changes.

### 4.4 Stub Path (feature=occt, no OCCT libs)

| Check | Result |
|-------|--------|
| `cargo check --features occt` (no env vars) | **Clean** — empty tree fallback |
| Tree → empty vec → flat model fallback | **Working** |

### 4.5 GUI Items Not Yet Manually Verified

All of the following require a foreground macOS GUI session (`MMFORGE_ALLOW_INTERACTIVE_GUI=1`)
and have NOT been verified:

| # | Item | Reason |
|---|------|--------|
| G1 | macOS app launch + Metal rendering | Requires interactive GUI session |
| G2 | Structure sidebar showing assembly hierarchy | Requires GUI |
| G3 | Viewport picking on individual components | Requires GUI |
| G4 | Hide/isolate per component | Requires GUI |
| G5 | Per-part bounds in inspector | Requires GUI |
| G6 | Component transform correctness in viewport | Requires GUI |
| G7 | Export PNG / DMG acceptance tests | Requires GUI |
| G8 | Color/material per component | Requires GUI |

These are implementation-complete on the Rust/Swift side (tree structure,
node_id/geometry_id stability, mesh → node mapping unchanged) but need a
dedicated foreground GUI session for end-to-end visual confirmation.

---

## 5. Files Changed

| File | Δ | Change |
|------|---|--------|
| `crates/mmforge-geometry/shim/mmforge_occt_shim.h` | +38 | MmfTreeNode, tree enum functions, ABI v4 |
| `crates/mmforge-geometry/shim/mmforge_occt_shim.cpp` | +257/−2 | buildAssemblyTree, tree getters, transfer_roots update |
| `crates/mmforge-geometry/src/occt/sys.rs` | +35 | MmfTreeNode repr(C), 4 new extern "C" |
| `crates/mmforge-geometry/src/occt/adapter.rs` | +201/−47 | TreeNode, enum_tree_nodes, cfg restructure |
| `crates/mmforge-geometry/build.rs` | +4 | New symbols in REQUIRED_SHIM_SYMBOLS |
| `crates/mmforge-geometry/src/occt/step_reader.rs` | +69/−13 | tree_nodes field, tree-based tessellate |
| `crates/mmforge-geometry/src/occt/iges_reader.rs` | +73/−18 | Same for IGES |
| `crates/mmforge-format-step/src/parser.rs` | +155/−119 | Tree-based model building + flat fallback |
| `crates/mmforge-format-iges/src/parser.rs` | +131/−129 | Same for IGES |

---

## 6. Remaining Gaps

| # | Gap | Status |
|---|-----|--------|
| G1 | macOS GUI rendering verification | ❌ Requires foreground session |
| G2 | Viewport picking with per-part transforms | ❌ Requires GUI session |
| G3 | Structure sidebar displaying assembly hierarchy | ❌ Requires GUI session |
| G4 | IGES assembly fixture | ⚠️ IGES parser supports tree but no multi-part IGES fixture |
| G5 | Non-rigid transforms (scale/shear) | ⚠️ XDE locations are typically rigid; tested with translation only |
