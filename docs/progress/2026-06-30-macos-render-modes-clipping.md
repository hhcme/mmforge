# macOS Render Modes + Clipping Plane

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Solid, wireframe, solid+wireframe, transparent render modes;
        clipping plane with axis/distance control

---

## Summary

The Metal viewer now supports four render modes and a configurable
clipping plane.  Render mode is controlled via the toolbar picker and
inspector Settings tab.  Clipping is toggled via inspector or Cmd+K
menu command.

---

## Render Modes

| Mode | Pipeline | Depth Write | Fill Mode | Alpha |
|------|----------|-------------|-----------|-------|
| Solid | solidPipeline | Yes | Fill | 1.0 |
| Wireframe | wireframePipeline | Yes | Lines | 1.0 |
| Solid+Wire | solidPipeline + wireframePipeline | Yes + No | Fill + Lines | 1.0 |
| Transparent | transparentPipeline | No | Fill | 0.6 |

### Metal Pipelines

Three `MTLRenderPipelineState` objects created at init:

- **solidPipeline**: standard diffuse rendering
- **wireframePipeline**: same shaders, `fillMode = .lines` set per-draw
- **transparentPipeline**: alpha blending enabled
  (`sourceAlpha` / `oneMinusSourceAlpha`), depth write disabled

### Shader Changes

`Uniforms` extended with:
- `clipPlane: float4` — xyz=normal, w=distance; w=-999999 when disabled
- `renderMode: uint` — 0=solid, 1=wireframe, 2=solid+wire, 3=transparent

Vertex shader passes `worldPos` to fragment for clipping.

Fragment shader:
- Clips: `if (clipPlane.w > -999990) discard when dot(clipPlane.xyz, worldPos) + clipPlane.w < 0`
- Transparent: outputs with `baseColor.a` as alpha

---

## Clipping Plane

- **Enable/Disable**: Toggle in inspector Settings tab, or Cmd+K
- **Axis**: X / Y / Z picker (default Z)
- **Distance**: Slider -100 to 100 (default 0)
- Plane equation: `dot(normal, worldPos) + distance = 0`
- Fragments on the negative side are discarded

---

## UI Integration

### Toolbar
- Render mode segmented picker: Solid / Wireframe / Solid+Wire / Transparent
- Bound to `$viewModel.renderMode` with `onChange` forwarding to renderer

### Inspector Settings Tab
- Render mode picker (same options)
- Clipping Plane section:
  - Enable toggle
  - Axis picker (X/Y/Z)
  - Distance slider with value label

### Menu Commands
- Cmd+K: Toggle Clipping Plane

### VoiceOver
- Render mode picker: `accessibilityLabel("Render mode")`
- Clipping toggle: `accessibilityLabel`, `accessibilityHint`
- Axis/distance controls: proper labels and values

---

## Draw Loop

```swift
switch renderMode {
case .solid:
    drawPass(pipeline: solid, depthWrite: true, fillMode: .fill)
case .wireframe:
    drawPass(pipeline: wireframe, depthWrite: true, fillMode: .lines)
case .solidWireframe:
    drawPass(pipeline: solid, depthWrite: true, fillMode: .fill)
    drawPass(pipeline: wireframe, depthWrite: false, fillMode: .lines)
case .transparent:
    drawPass(pipeline: transparent, depthWrite: false, fillMode: .fill)
}
```

`drawPass` iterates visible meshes, sets per-mesh uniforms (including
clipPlane and renderMode), and issues `drawIndexedPrimitives`.

---

## Regression: Selection/Visibility Unchanged

Render modes and clipping do not affect:
- `selectedNodeIndex` highlight (still applied via `highlightColor`)
- `hiddenNodeIndices` visibility (still skipped in draw loop)
- Picking (`pickNode` ignores render mode)
- Sidebar selection state

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
| `Shaders.metal` | clipPlane, renderMode in Uniforms; clipping discard; transparent alpha |
| `MetalRenderer.swift` | RenderMode enum, 3 pipelines, clip state, drawPass helper |
| `MMForgeDocument.swift` | renderMode/clipEnabled/clipAxis/clipDistance + methods |
| `ContentView.swift` | Toolbar picker bound to renderMode |
| `InspectorPanel.swift` | Render mode + clipping controls in Settings |
| `MMForgeApp.swift` | Cmd+K toggle clipping command |
