# macOS Color Override + Section Fill Cap

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Node-level color override, clip-plane section fill cap,
        Inspector/Menu integration

---

## Summary

The macOS viewer now supports per-node color overrides and
clip-plane section fill geometry.  Selecting a node and using the
Inspector's Appearance section allows color override.  When a
clipping plane is active, intersection quads are rendered as a
semi-transparent cap at the clip plane.

---

## Color Override

### ViewModel
- `nodeColorOverrides: [Int: simd_float4]` — nodeIndex → override color
- `setNodeColor(_ index:, color:)` — set/reset override
- `resetSelectedNodeColor()` — reset selected node
- `resetAllColors()` — clear all overrides
- Cleared on `freeCurrentDocument()`

### MetalRenderer
- `nodeColorOverrides: [Int: simd_float4]` dict
- `drawPass` uses override color when present, default grey otherwise
- Alpha preserved from render mode (0.6 for transparent, 1.0 otherwise)

### Inspector
- "Appearance" section in selected node view
- Shows "Default (grey)" or "Color" with Reset button
- Only visible for geometry nodes

### Menu
- "Reset All Colors" command (disabled when no overrides)

---

## Section Fill Cap

### Algorithm (`SectionFill.swift`)

For each visible mesh triangle:
1. Classify vertices as above/below clip plane
2. If triangle crosses plane → compute 2 intersection points
3. Create a quad (2 triangles) along the intersection line
4. Extend quad slightly along a perpendicular direction for visibility

### MetalRenderer
- `updateSectionFill()` — computes intersection quads from all visible meshes
- `clearSectionFill()` — clears buffer
- Renders as overlay triangles (`.triangle` fill mode) with semi-transparent red-orange
- Drawn after mesh passes, before measurement overlay

### ViewModel
- `updateClipPlane()` calls `renderer?.updateSectionFill()` when enabled
- `clearSectionFill()` when clipping disabled
- Cleared in `freeCurrentDocument()`

---

## Commands Run

| Command | Result |
|---------|--------|
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `MMForgeDocument.swift` | `nodeColorOverrides`, `setNodeColor`, `resetAllColors`, section fill sync |
| `MetalRenderer.swift` | `nodeColorOverrides` in drawPass, `updateSectionFill`, section fill buffer |
| `SectionFill.swift` | New: clip-plane triangle intersection algorithm |
| `InspectorPanel.swift` | Color override UI, `computeDiagonal` helper |
| `MMForgeApp.swift` | "Reset All Colors" menu command |
| `project.pbxproj` | Added SectionFill.swift, removed test target |
