# Selection Mapping Fix — Authoritative geometryId in NodeInfo

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix Swift-side mesh→node mapping to use `mesh.geometryId`
        as authoritative key, not array index heuristics

---

## Problem

The previous `uploadToRenderer` built the mapping from `meshIdx` to
`nodeIdx` using `node.meshIndex` (which equals the sorted rank).
When iterating meshes, it looked up `geomIdToNodeIdx[meshIdx]` —
using the array index as a proxy for geometryId.  This broke when
`model.geometries` order didn't match the sorted mesh order.

---

## Solution

### 1. `mmf_node_geometry_id` C ABI function

New function returns the `GeometryId` for a node (the authoritative
key for node↔mesh mapping).  Returns -1 if no geometry.

### 2. `NodeInfo.geometryId` field

`RenderPacketDTO.NodeInfo` now includes `geometryId: Int` from
`mmf_node_geometry_id`.  This is the same value as
`Mesh.geometryId` for the corresponding mesh.

### 3. `uploadToRenderer` uses `mesh.geometryId`

```swift
var geomIdToNodeIdx = [Int: Int]()
for (nodeIdx, node) in dto.nodes.enumerated() {
    if node.geometryId >= 0 {
        geomIdToNodeIdx[node.geometryId] = nodeIdx
    }
}
for mesh in dto.meshes {
    let nodeIdx = geomIdToNodeIdx[mesh.geometryId] ?? -1
    // ...
}
```

The mapping key is `mesh.geometryId` (from RenderMesh) matched
against `node.geometryId` (from NodeInfo).  Both come from the same
Rust `GeometryId` — no array index heuristics.

### 4. Regression tests (existing)

- `multi_geometry_deterministic_order`: IDs [3,1,0,2] → sorted [0,1,2,3]
- `geometry_id_preserved_through_sort`: IDs [7,2,99,1] → sorted [1,2,7,99]

Both verify `mesh.geometry_id` matches the original GeometryId after
sorting.  Combined with the Swift-side `geometryId` mapping, the
full pipeline is authoritative end-to-end.

---

## Data Flow (final)

```
model.geometries[i].id() = GeometryId (e.g. 7)
  ↓
TessellationRegistry { GeometryId(7) → TessellatedMeshData }
  ↓
build_render_packet: sort by GeometryId
  mesh[2].geometry_id = 7
  ↓
C ABI: mmf_mesh_geometry_id(doc, 2) → 7
       mmf_node_geometry_id(doc, 5) → 7
  ↓
Swift: NodeInfo.geometryId = 7
       Mesh.geometryId = 7
  ↓
geomIdToNodeIdx[7] = 5
  ↓
MetalRenderer: mesh[2].nodeIndex = 5
```

No heuristics.  Every layer uses the same authoritative GeometryId.

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
| `crates/mmforge-bridge/src/lib.rs` | `mmf_node_geometry_id` function |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | `mmf_node_geometry_id` declaration |
| `macos/MMForge/RustBridge/RustBridge.swift` | `NodeInfo.geometryId`; `Mesh.geometryId` in DTO |
| `macos/MMForge/Document/MMForgeDocument.swift` | `uploadToRenderer` uses `mesh.geometryId` → `geomIdToNodeIdx` |
