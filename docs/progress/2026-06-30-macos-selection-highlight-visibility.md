# macOS Selection Highlight, Picking & Visibility

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Selection-highlight linkage, viewport picking, node visibility
        control, menu/toolbar entries, VoiceOver

---

## Summary

Sidebar selection now highlights the corresponding 3D mesh in the
viewport.  Clicking a mesh in the viewport selects the corresponding
node in the sidebar.  Each geometry node can be hidden/shown via an
eye icon.  Menu commands provide keyboard shortcuts for selection and
visibility control.

---

## Changes

### Metal Shader (`Shaders.metal`)

Extended `Uniforms` with `highlightColor: float4` (rgb = tint, a =
blend factor).  Fragment shader blends highlight over diffuse:

```metal
color = mix(color, u.highlightColor.rgb, u.highlightColor.a);
```

### MetalRenderer (`MetalRenderer.swift`)

**Per-mesh state:**
- `GPUMesh.visible: Bool` — skip in draw loop when false
- `GPUMesh.nodeIndex: Int` — maps mesh → scene tree node
- `GPUMesh.boundsMin/Max: simd_float3` — for picking

**Selection:**
- `selectedNodeIndex: Int?` — set by ViewModel
- Draw loop applies `highlightColor = (0.2, 0.5, 1.0, 0.4)` to
  selected mesh, `(0, 0, 0, 0)` to others

**Visibility:**
- `hiddenNodeIndices: Set<Int>` — set by ViewModel
- `setNodeVisible(index, visible:)` — per-mesh toggle
- `setHiddenNodes(indices:)` — bulk update

**Picking (CPU AABB ray test):**
- `pickNode(at: CGSize, point: CGPoint) -> Int?`
- Unprojects click point to world ray via inverse(projection * view)
- Slab-method ray-AABB intersection against all visible meshes
- Returns closest hit node index

**Matrix inverse:**
- Added `simd_float4x4.inverse` using cofactor expansion

### DocumentViewModel (`MMForgeDocument.swift`)

New properties:
- `@Published var hiddenNodeIndices: Set<Int> = []`

New methods:
- `selectNode(_ index: Int?)` — sets `selectedIndex`, notifies renderer
- `toggleNodeVisibility(_ index: Int)` — toggles hidden set + renderer
- `setAllNodesVisible()` — clears hidden set
- `hideSelectedNode()` — hides currently selected node

`uploadToRenderer` now passes `nodeIndex`, `boundsMin`, `boundsMax`
for each mesh (mapped from geometry nodes).

### StructureSidebar (`StructureSidebar.swift`)

- Eye icon button per geometry node (visible/hidden toggle)
- Selection highlight via `.listRowBackground(accentColor.opacity(0.15))`
- Double-click toggles visibility
- VoiceOver: `accessibilityValue` reports "visible"/"hidden"
- VoiceOver: `accessibilityLabel` on eye button

### ViewportContainer (`ViewportContainer.swift`)

- `NSClickGestureRecognizer` added for picking
- Click → `renderer.pickNode(at:point:)` → `viewModel.selectNode()`
- Dispatched to main actor for SwiftUI safety

### ContentView (`ContentView.swift`)

- `.focusedObject(viewModel)` for menu command access

### MMForgeApp (`MMForgeApp.swift`)

New `SelectionCommandsView` (menu commands):
- **Select Root** (Cmd+Shift+A) — select root node
- **Hide Selection** (Cmd+H) — hide selected node
- **Show All** (Cmd+Shift+H) — show all nodes

Uses `@FocusedObject` to access the current document's ViewModel.

---

## Data Flow

```
User clicks sidebar node
  → viewModel.selectNode(index)
  → renderer.setSelectedNode(index)
  → draw() applies highlightColor to matching mesh

User clicks viewport
  → NSClickGestureRecognizer
  → renderer.pickNode(at:point:)
    → unproject to world ray
    → ray vs AABB for each visible mesh
    → closest hit → node index
  → viewModel.selectNode(index)
  → sidebar highlights row + inspector shows properties

User toggles eye icon
  → viewModel.toggleNodeVisibility(index)
  → renderer.setNodeVisible(index, visible:)
  → draw() skips hidden meshes
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 84 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Metal/Shaders.metal` | `highlightColor` in Uniforms + blend in fragment |
| `macos/MMForge/Metal/MetalRenderer.swift` | Per-mesh visibility/highlight, picking, matrix inverse |
| `macos/MMForge/Views/ViewportContainer.swift` | Click gesture for picking |
| `macos/MMForge/Views/StructureSidebar.swift` | Eye icon toggle, selection highlight, VoiceOver |
| `macos/MMForge/Views/ContentView.swift` | `.focusedObject`, selection menu commands |
| `macos/MMForge/App/MMForgeApp.swift` | `SelectionCommandsView` with Cmd+H/Shift+H/Shift+A |
| `macos/MMForge/Document/MMForgeDocument.swift` | `hiddenNodeIndices`, selection/visibility methods |

---

## Apple HIG Compliance

- ✅ Sidebar rows: `accessibilityLabel` + `accessibilityValue` (visible/hidden)
- ✅ Eye icon: `accessibilityLabel` ("Show/Hide {name}")
- ✅ Menu commands: Cmd+H (Hide), Cmd+Shift+H (Show All), Cmd+Shift+A (Select Root)
- ✅ Viewport: click-to-select with visual feedback
- ✅ Selection highlight: accent blue tint on selected mesh
- ✅ `@FocusedObject` pattern for document-scoped menu commands
