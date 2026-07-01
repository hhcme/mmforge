# Section Fill Layout Fix — OverlayVertex Consistency

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix section fill vertex layout to match overlay pipeline,
        add indexCount guard, sync section fill after mesh upload

---

## Fixes

### 1. Section fill vertex layout matches overlay pipeline

**Before**: `computeSectionFillVertices` emitted 7 floats per vertex
(position xyz + color rgba = 28 bytes).  The overlay pipeline expects
`OverlayVertex` with `float4 position + float4 color = 32 bytes`.

**After**: Each vertex emits 8 floats:
```
position.x, position.y, position.z, 1.0,  // float4 (w=1)
color.r, color.g, color.b, color.a         // float4
```

Stride: 32 bytes — matches `OverlayVertex` exactly.

### 2. indexCount % 3 guard

Added `guard idxCount % 3 == 0, idxCount > 0` before iterating
triangles.  Prevents out-of-bounds access when index count is not
a multiple of 3.

### 3. Section fill recalculated after mesh upload

`uploadToRenderer` now calls `renderer.updateSectionFill()` when
`clipEnabled` is true.  Previously, uploading meshes with clip active
would show no section fill until the clip plane was toggled.

### 4. Vertex count calculation fixed

`sectionFillVertexCount = floatCount / 8` (was `/7`).

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test-without-building` | ✅ 22/22 pass |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Metal/SectionFill.swift` | float4+float4 layout (32 bytes), indexCount guard |
| `macos/MMForge/Metal/MetalRenderer.swift` | `sectionFillVertexCount = floatCount / 8` |
| `macos/MMForge/Document/MMForgeDocument.swift` | `updateSectionFill()` after `uploadToRenderer` when clip active |
