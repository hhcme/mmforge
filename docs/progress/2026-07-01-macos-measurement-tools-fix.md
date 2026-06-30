# Measurement Tools Fix — Overlay Layout + State Cleanup

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix OverlayVertex memory layout, clear measurement state on reload

---

## Fixes

### 1. OverlayVertex layout: simd_float3 → simd_float4

**Problem**: Swift's `simd_float3` has 16-byte alignment with padding,
but Metal's `float3` is 12 bytes with 4-byte alignment.  Using
`simd_float3` for position with offset=12/stride=28 caused a layout
mismatch between the Swift struct and the Metal vertex descriptor.

**Fix**: Changed position to `simd_float4` (16 bytes, 16-byte aligned).
Updated Metal vertex descriptor to `float4` at offset 0, `float4` at
offset 16, stride 32.  Updated Metal shader `OverlayVertexIn` to use
`float4 position`.

```swift
struct OverlayVertex {
    var position: simd_float4  // xyz in xyz, w unused
    var color: simd_float4
}
// stride = 32 bytes (2 × 16)
```

Metal vertex descriptor:
```
attribute[0]: float4, offset 0,  bufferIndex 0
attribute[1]: float4, offset 16, bufferIndex 0
layouts[0]:   stride 32
```

### 2. Clear measurement state on document reload

`freeCurrentDocument()` now clears:
- `renderer?.clearOverlay()`
- `measurementMode = false`
- `measurements = []`
- `pendingPoint = nil`

This prevents stale measurement overlays from the previous model
appearing after re-parse or file open.

### 3. Layout documentation

Added doc comment to `OverlayVertex` explaining the layout contract
and why `simd_float4` is used instead of `simd_float3`.

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
| `MetalRenderer.swift` | `OverlayVertex` uses `simd_float4`; vertex descriptor stride=32; `appendMarker` converts to `simd_float4` |
| `Shaders.metal` | `OverlayVertexIn.position` → `float4`; vertex shader uses `.xyz` |
| `MMForgeDocument.swift` | `freeCurrentDocument` clears measurement state + overlay |
