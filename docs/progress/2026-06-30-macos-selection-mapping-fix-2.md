# Selection Mapping Fix — Authoritative geometry_id in RenderMesh

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix mesh↔node mapping to use authoritative `geometry_id`
        stored in `RenderMesh`, not array position heuristics

---

## Problem

`mmf_node_mesh_index` returned the geometry's position in
`model.geometries`, but `build_render_packet` sorts by `GeometryId`.
If `model.geometries` order doesn't match the sorted order, the
mapping breaks.  The previous approach relied on both orders being
identical — a fragile assumption.

---

## Solution

### 1. `geometry_id` stored in `RenderMesh`

Added `geometry_id: u32` field to `RenderMesh`.  Populated from the
`GeometryId` in `build_render_packet` after sorting.  This makes the
mapping explicit and verifiable at every layer.

### 2. `mmf_mesh_geometry_id(doc, mesh_index)` C ABI function

New function returns the `GeometryId` for a mesh at the given index.
Swift uses this to build `geometryId → nodeIndex` mapping.

### 3. Swift DTO includes `geometryId` per mesh

`RenderPacketDTO.Mesh` now has `geometryId: Int`.  `uploadToRenderer`
builds `geomIdToNodeIdx[meshIdx] = nodeIdx` using the authoritative
`meshIndex` from `NodeInfo` (which is the sorted rank).

### 4. Regression test: non-sequential IDs

`geometry_id_preserved_through_sort` test:
- Inserts geometries with IDs [7, 2, 99, 1]
- Verifies meshes are sorted [1, 2, 7, 99]
- Verifies each mesh's `geometry_id` matches the original ID

---

## Data Flow

```
model.geometries[i].id() = GeometryId
  ↓
TessellationRegistry { GeometryId → TessellatedMeshData }
  ↓
build_render_packet: sort by GeometryId → mesh[i].geometry_id = geom_id.get()
  ↓
C ABI: mmf_mesh_geometry_id(doc, i) → geometry_id
  ↓
Swift: Mesh.geometryId → geomIdToNodeIdx mapping
  ↓
MetalRenderer: mesh.nodeIndex = geomIdToNodeIdx[meshIdx]
```

The mapping is authoritative at every layer — no heuristics.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-render/src/packet.rs` | `geometry_id: u32` in `RenderMesh` |
| `crates/mmforge-render/src/builder.rs` | Populate `geometry_id`; regression test |
| `crates/mmforge-bridge/src/lib.rs` | `mmf_mesh_geometry_id` function |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | `mmf_mesh_geometry_id` declaration |
| `macos/MMForge/RustBridge/RustBridge.swift` | `geometryId` in `Mesh` DTO |
| `macos/MMForge/Document/MMForgeDocument.swift` | `uploadToRenderer` uses `geometryId` mapping |
