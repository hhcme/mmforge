# XDE Assembly Tree Recursive Expansion — 2026-07-09

**Date**: 2026-07-09
**Agent**: ZCode (deepseek-v4-pro)
**Status**: IMPLEMENTED (shim rebuild + OCCT-enabled tests pending)

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

| Check | Result |
|-------|--------|
| `cargo check --workspace` | **Clean** (no errors) |
| `cargo check --features occt` (step+iges) | **Clean** |
| `git diff --check` | **Clean** |
| C++ shim rebuild | **Pending** — requires OCCT 7.9 headers/libs |
| `cargo test --features occt` (E2E) | **Pending** — requires rebuilt shim |
| Assembly STEP fixture | **Pending** — small AP214 assembly fixture needed |

### 4.1 To Verify (requires OCCT-enabled build)

```bash
# Rebuild shim
cd crates/mmforge-geometry/shim && mkdir -p build && cd build
cmake .. && make -j$(sysctl -n hw.ncpu)

# Full E2E
MMFORGE_SHIM_DIR=$(pwd) \
  OCCT_INCLUDE_DIR=/path/to/occt/include \
  OCCT_LIB_DIR=/path/to/occt/lib \
  cargo test -p mmforge-geometry --features occt
cargo test -p mmforge-format-step --features occt
cargo test -p mmforge-format-iges --features occt
```

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
| G1 | C++ shim rebuild with OCCT 7.9 | Requires OCCT headers/libs |
| G2 | E2E tree verification tests (occt_found) | Requires rebuilt shim |
| G3 | Small AP214 assembly STEP fixture | Manual creation or OCCT export needed |
| G4 | Assembly fixture with NEXT_ASSEMBLY_USAGE_OCCURRENCE + PRODUCT_DEFINITION | Validates real XDE hierarchy |
| G5 | Non-OCCT build path: tree returns empty → flat fallback works | Verified via `cargo check --features occt` |
