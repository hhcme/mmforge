# Render Modes + Clipping — Review Fixes

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix setRenderer state sync, clipping-aware picking,
        transparent back-to-front sorting

---

## Fixes

### 1. `setRenderer` syncs renderMode + clipPlane

When a new renderer is created (e.g. on view re-appear), `setRenderer`
now forwards the current `renderMode` and calls `updateClipPlane()` so
the renderer starts with the correct state.

```swift
func setRenderer(_ renderer: MetalRenderer) {
    self.renderer = renderer
    renderer.renderMode = renderMode
    updateClipPlane()
    // ... upload pending DTO
}
```

### 2. `pickNode` respects clipping plane

When `clipPlane.w > -999990` (clipping enabled), `pickNode` now
skips meshes whose AABB center is on the negative side of the clip
plane.  This prevents selecting geometry that's clipped away.

```swift
if clipPlane.w > -999990 {
    let center = (mesh.boundsMin + mesh.boundsMax) * 0.5
    let normal = simd_float3(clipPlane.x, clipPlane.y, clipPlane.z)
    if dot(normal, center) + clipPlane.w < 0 { continue }
}
```

### 3. Transparent mode: back-to-front sorting

Added `backToFrontIndices()` method that sorts visible mesh indices
by distance from camera (farthest first).  Used in the transparent
draw pass for correct alpha blending.

```swift
case .transparent:
    let sorted = backToFrontIndices()
    drawPass(..., mode: 3, depthWrite: false, fillMode: .fill, meshOrder: sorted)
```

`drawPass` now accepts an optional `meshOrder: [Int]?` parameter.
When nil, iterates in default order.  When provided, iterates in the
given order (used for back-to-front transparent rendering).

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
| `macos/MMForge/Document/MMForgeDocument.swift` | `setRenderer` syncs renderMode + clipPlane |
| `macos/MMForge/Metal/MetalRenderer.swift` | `pickNode` clips; `backToFrontIndices`; `drawPass` meshOrder param |
