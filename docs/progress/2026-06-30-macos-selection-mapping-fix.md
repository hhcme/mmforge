# Selection/Highlight/Visibility — Stable Mesh↔Node Mapping Fix

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix mesh→node mapping to be deterministic and authoritative,
        not guessed from array order

---

## Problem

The previous implementation guessed the mesh→node mapping from array
order: `meshNodeIndices[i] = nodeIdx`.  This broke when:

- `HashMap` iteration in `build_render_packet` produced non-deterministic order
- Nodes and meshes had different ordering conventions
- Re-ordering geometries in the model changed the mapping silently

---

## Solution

### 1. Deterministic mesh ordering (`builder.rs`)

`build_render_packet` now sorts `mesh_data` by `GeometryId` before
iterating:

```rust
let mut sorted: Vec<_> = mesh_data.iter().collect();
sorted.sort_by_key(|(id, _)| id.get());
```

This guarantees `mesh_index == geometry_index` in the model.

### 2. Authoritative mapping function (`lib.rs`)

New C ABI function `mmf_node_mesh_index(doc, node_index) -> i32`:

- Returns the mesh index in the RenderPacket for a given node
- Maps: node → `geometry_id` → position in `model.geometries` → mesh index
- Returns -1 if node has no geometry

This is the single source of truth for the node↔mesh relationship.

### 3. Swift DTO uses `meshIndex` field

`RenderPacketDTO.NodeInfo` now includes `meshIndex: Int` (from
`mmf_node_mesh_index`).  `uploadToRenderer` builds the mapping
from `meshToNode[meshIdx] = nodeIdx` using the authoritative field.

### 4. `freeCurrentDocument` clears `hiddenNodeIndices`

Added `hiddenNodeIndices = []` to `freeCurrentDocument()` so
visibility state is properly reset when opening a new file.

### 5. Removed `Cmd+H` shortcut

`Cmd+H` conflicts with macOS HIG "Hide Application".  Removed the
keyboard shortcut from "Hide Selection" — it remains as a menu item
without a shortcut.  "Show All" keeps `Cmd+Shift+H`.

### 6. Regression test (`builder.rs`)

`multi_geometry_deterministic_order` test:
- Inserts 4 geometries in reverse order (3, 1, 0, 2)
- Verifies meshes are sorted by GeometryId (0, 1, 2, 3)
- Verifies each mesh's position data encodes the original GeometryId

---

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-render/src/builder.rs` | Sort mesh_data by GeometryId; regression test |
| `crates/mmforge-bridge/src/lib.rs` | `mmf_node_mesh_index` function |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | `mmf_node_mesh_index` declaration |
| `macos/MMForge/RustBridge/RustBridge.swift` | `meshIndex` in `NodeInfo` |
| `macos/MMForge/Document/MMForgeDocument.swift` | `uploadToRenderer` uses `meshIndex`; `freeCurrentDocument` clears `hiddenNodeIndices` |
| `macos/MMForge/App/MMForgeApp.swift` | Removed `Cmd+H` from Hide Selection |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 85 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |
