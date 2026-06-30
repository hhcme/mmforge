# macOS Camera & View Controls

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Camera/view controls — orthographic projection, named views,
        scroll wheel zoom, keyboard shortcuts, menu/toolbar entries

---

## Summary

The Metal viewer now supports orthographic/perspective projection
toggle, 7 standard CAD view directions, scroll wheel zoom, keyboard
shortcuts, and a dedicated Camera menu.

---

## Camera Enhancements

### Orthographic Projection

`CameraState` extended with:
- `isOrthographic: Bool` — toggles between perspective and ortho
- `orthoScale: Float` — controls ortho viewport size

`projectionMatrix(aspect:)` returns either:
- Perspective: `simd_float4x4(perspectiveFovY:...)`
- Orthographic: `simd_float4x4(orthoLeft:right:bottom:top:near:far:)`

Zoom in ortho mode scales `orthoScale` instead of `distance`.

Pan sensitivity scales with `orthoScale` in ortho mode.

### Named Views (7 directions)

```swift
enum NamedView {
    case front, back, left, right, top, bottom, isometric
}
```

Each sets `yaw` and `pitch` to standard CAD angles:

| View | Yaw | Pitch |
|------|-----|-------|
| Front | 0 | 0 |
| Back | π | 0 |
| Left | π/2 | 0 |
| Right | -π/2 | 0 |
| Top | 0 | π/2 - 0.01 |
| Bottom | 0 | -(π/2 - 0.01) |
| Isometric | π/4 | π/4 |

### Reset Camera

`resetCamera()` calls `fitToView()` then resets yaw/pitch to defaults
and disables orthographic mode.

---

## UI Integration

### Toolbar

- **Fit** button (Cmd+F) — fit model to viewport
- **Home** button — reset camera to defaults
- **View** menu dropdown — Front/Back/Left/Right/Top/Bottom/Isometric
- **Render mode** picker — unchanged

### Camera Menu (new)

Dedicated `CommandMenu("Camera")` with:
- Fit to View (Cmd+F)
- Home / Reset Camera (Cmd+H)
- Front/Back/Left/Right/Top/Bottom/Isometric View
- Toggle Perspective/Orthographic (Cmd+P)

### Keyboard Shortcuts (ViewportContainer)

| Key | Action |
|-----|--------|
| F | Fit to view |
| H | Home / reset camera |
| I | Isometric view |
| P | Toggle perspective/orthographic |
| Scroll wheel | Zoom (perspective: distance, ortho: scale) |

### Gestures (unchanged)

| Gesture | Action |
|---------|--------|
| Drag | Orbit (yaw + pitch) |
| Alt+Drag | Pan |
| Pinch/Scroll | Zoom |
| Click | Pick node |

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
| `MetalRenderer.swift` | `CameraState` with ortho + named views; `setNamedView`, `toggleProjection`, `resetCamera`; ortho matrix init |
| `DocumentViewModel.swift` | `setNamedView`, `toggleProjection`, `resetCamera` methods |
| `ViewportContainer.swift` | Scroll wheel zoom monitor; keyboard shortcuts (F/H/I/P) |
| `ContentView.swift` | View preset dropdown in toolbar; Home button |
| `MMForgeApp.swift` | `CameraCommandsView` menu; fixed brace mismatch |
