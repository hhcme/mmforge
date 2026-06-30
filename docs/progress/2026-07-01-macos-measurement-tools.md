# macOS Measurement Tools — Point-to-Point Distance

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Point-to-point distance measurement with Metal overlay,
        inspector Measure tab, toolbar/menu integration

---

## Summary

The Metal viewer now supports point-to-point distance measurement.
Click two points in the viewport to measure the Euclidean distance.
Measurements are rendered as yellow lines with endpoint markers in
the Metal overlay.  Results are listed in the inspector Measure tab
with per-axis deltas and individual delete.

---

## Measurement Flow

```
1. User clicks ruler toolbar button (or Cmd+M)
   → measurementMode = true

2. First click in viewport
   → renderer.pickWorldPoint() returns world-space point
   → stored as pendingPoint (cyan marker drawn)

3. Second click in viewport
   → Measurement(start, end) created
   → pendingPoint cleared
   → yellow line + endpoint markers drawn in overlay

4. Inspector Measure tab shows:
   - Distance (Δ value)
   - Per-axis deltas (X, Y, Z)
   - Delete button per measurement
   - Clear All button
```

---

## Metal Overlay

### Shader (`Shaders.metal`)

New `overlay_vertex` / `overlay_fragment` shaders:
- Input: `float3 position + float4 color` (28 bytes stride)
- No lighting, no clipping
- Alpha blending enabled in pipeline

### MetalRenderer

- `overlayPipeline`: separate MTLRenderPipelineState for overlay
- `overlayVertexBuffer`: MTLBuffer with `OverlayVertex` data
- `updateOverlay(measurements:pendingPoint:)`: builds vertex data
- `clearOverlay()`: clears buffer
- `pickWorldPoint(at:point:)`: returns world-space AABB hit point
- Overlay drawn after mesh passes, before `encoder.endEncoding()`

### Overlay Markers

- Measurement lines: yellow `(1.0, 0.85, 0.0, 1.0)`
- Pending point: cyan `(0.2, 0.8, 1.0, 1.0)`
- Endpoint markers: 3D cross (6 lines per point)
- Marker size scales with scene (0.5% of unit)

---

## UI Integration

### Toolbar

Ruler button toggles measurement mode:
```swift
Button(action: { viewModel.toggleMeasurementMode() }) {
    Image(systemName: viewModel.measurementMode ? "ruler.fill" : "ruler")
}
```

### Menu (SelectionCommandsView)

- Toggle Measurement (Cmd+M)
- Clear Measurements (disabled when empty)

### Inspector Measure Tab

- Measurement mode toggle
- Instructions text
- Pending point indicator
- Selected node bounding box size (X/Y/Z/Diagonal)
- Measurement results list with:
  - Distance (Δ value, monospaced)
  - Per-axis deltas (X, Y, Z)
  - Delete button per measurement
  - Clear All button

### ViewportContainer

Click handler checks `viewModel.measurementMode`:
- Active: calls `renderer.pickWorldPoint()` → `viewModel.addMeasurementPoint()`
- Inactive: calls `renderer.pickNode()` → `viewModel.selectNode()`

---

## Data Model

```swift
struct Measurement: Identifiable {
    let id = UUID()
    let start: simd_float3
    let end: simd_float3
    var distance: Float     // Euclidean distance
    var deltaX/Y/Z: Float  // per-axis deltas
}
```

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
| `Shaders.metal` | `OverlayVertexIn`, `overlay_vertex`, `overlay_fragment` |
| `MetalRenderer.swift` | Overlay pipeline, `updateOverlay`, `clearOverlay`, `pickWorldPoint`, marker drawing |
| `MMForgeDocument.swift` | `Measurement` struct, `measurementMode`, `measurements`, `pendingPoint`, measurement methods, `syncOverlay` |
| `InspectorPanel.swift` | Measure tab with toggle, results list, delete/clear |
| `ContentView.swift` | Ruler toolbar button |
| `MMForgeApp.swift` | Cmd+M toggle, Clear Measurements menu |
| `ViewportContainer.swift` | Measurement mode click handling |
