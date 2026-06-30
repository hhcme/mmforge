# macOS Structure Sidebar & Inspector — Apple HIG

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Apple HIG-compliant structure sidebar and inspector with
        real model data, selection, states, and VoiceOver

---

## Summary

The structure sidebar and inspector panel now display real model data
from the Rust bridge.  The sidebar shows the product structure tree
with proper indentation, selection, and empty/loading/error states.
The inspector shows model statistics, selected node properties, and
bounding box information.

---

## Changes

### Rust Bridge (`crates/mmforge-bridge/src/lib.rs`)

New C ABI functions:

| Function | Purpose |
|----------|---------|
| `mmf_node_parent(doc, index)` | Parent node index (-1 for root) |
| `mmf_node_has_geometry(doc, index)` | Whether node has geometry |
| `mmf_node_bounds(doc, index, out_min, out_max)` | Node bounding box |
| `mmf_node_geometry_label(doc, index)` | Geometry label (e.g. "PQ-04909-A [Solid]") |
| `mmf_geometry_count(doc)` | Number of geometries |

`MmfDocument` now stores `geometry_labels: Vec<CString>` alongside
`node_names`, freed on document drop.

### C Header (`mmforge_bridge.h`)

Added declarations for all 5 new functions.

### RustBridge.swift

`RenderPacketDTO` extended with:

- `NodeInfo` struct: name, parentIndex, hasGeometry, geometryLabel,
  boundsMin, boundsMax
- `ModelStats` struct: nodeCount, geometryCount, materialCount,
  triangleCount, meshCount
- `nodes: [NodeInfo]` and `stats: ModelStats` fields

C `int` boolean returns converted with `!= 0` for Swift compatibility.

### StructureSidebar.swift

Rewritten with:

- **Real tree**: indented nodes based on parent relationships
- **Icons**: `folder.fill` for root, `cube` for geometry nodes,
  `folder` for sub-assemblies
- **Selection**: `@Binding var selectedIndex` synced with inspector
- **States**: empty (no structure), loading (spinner), loaded (tree)
- **Accessibility**: `accessibilityLabel` on each node with name,
  geometry status, root indicator

### InspectorPanel.swift

Rewritten with:

- **Properties tab**: model stats (nodes, geometries, meshes, triangles,
  materials) + selected node details (name, parent, geometry label,
  bounding box with min/max/size)
- **Settings tab**: grid/axes/AA toggles + app version
- **States**: empty, loading, error, loaded with/without selection
- **Accessibility**: `accessibilityLabel` on all sections, `isHeader`
  traits on section headers, hint on toggles

### ContentView.swift

- Passes `viewModel` to both `StructureSidebar` and `InspectorPanel`
- VoiceOver labels on toolbar buttons (sidebar/inspector/fit view)
- `accessibilityLabel` on render mode picker

### DocumentViewModel

Extended with:
- `@Published nodes: [RenderPacketDTO.NodeInfo]`
- `@Published stats: RenderPacketDTO.ModelStats?`
- `@Published selectedIndex: Int?`
- Cleared in `freeCurrentDocument()`

---

## Data Flow

```
Rust LsmModel
  → mmf_node_count / mmf_node_name / mmf_node_parent
  → mmf_node_has_geometry / mmf_node_geometry_label / mmf_node_bounds
  → mmf_geometry_count / mmf_triangle_count / mmf_material_count
  → RenderPacketDTO.nodes / .stats
  → DocumentViewModel.nodes / .stats / .selectedIndex
  → StructureSidebar (tree with selection)
  → InspectorPanel (model stats + node properties)
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace` | ✅ 79 tests pass |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 84 tests pass |
| `xcodebuild -scheme MMForge build` (real OCCT) | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-bridge/src/lib.rs` | 5 new C ABI functions + geometry_labels |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | 5 new function declarations |
| `macos/MMForge/RustBridge/RustBridge.swift` | NodeInfo + ModelStats DTO, C int→Bool fix |
| `macos/MMForge/Views/StructureSidebar.swift` | Full rewrite with real tree |
| `macos/MMForge/Views/InspectorPanel.swift` | Full rewrite with real data |
| `macos/MMForge/Views/ContentView.swift` | ViewModel binding + VoiceOver |
| `macos/MMForge/Document/MMForgeDocument.swift` | nodes/stats/selectedIndex fields |

---

## Apple HIG Compliance

- ✅ Sidebar uses `List` with `.sidebar` style
- ✅ Inspector uses segmented `Picker` for tabs
- ✅ `LabeledContent` for property display
- ✅ `accessibilityLabel` on all interactive elements
- ✅ `accessibilityAddTraits(.isHeader)` on section headers
- ✅ `accessibilityHint` on toggles and selections
- ✅ Empty/loading/error states in both sidebar and inspector
- ✅ `Label` with system images for node icons
- ✅ `keyboardShortcut` on sidebar/inspector toggles
