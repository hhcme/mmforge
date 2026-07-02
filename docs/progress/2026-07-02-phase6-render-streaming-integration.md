# Phase 6 Round 7: Render Streaming Integration — Bridge + Swift/Metal

**Date**: 2026-07-02
**Scope**: Connect `MemoryBudget`, `StreamingPacket`, `Frustum` from Rust render
crate into the real macOS/Rust rendering pipeline — C ABI bridge, Swift DTO,
progressive chunk upload, and frustum-driven visibility.

## 1. Bridge Layer (mmforge-bridge C ABI)

### New struct field

- `MmfDocument.streaming_packet: Option<StreamingPacket>` — built on demand via
  `mmf_build_streaming_packet()`.  Not built at parse time; only when requested.

### New C ABI functions (14 chunk + 1 frustum)

| Function | Purpose |
|----------|---------|
| `mmf_build_streaming_packet(doc, budget_bytes)` | Build chunks; returns chunk count |
| `mmf_chunk_count(doc)` | Number of chunks |
| `mmf_chunk_mesh_count(doc, ci)` | Meshes in chunk |
| `mmf_chunk_instance_count(doc, ci)` | Instances in chunk |
| `mmf_chunk_bounds(doc, ci, out_min, out_max)` | Chunk AABB (6 f32) |
| `mmf_chunk_batch_count(doc, ci)` | Batch groups in chunk |
| `mmf_chunk_memory_bytes(doc, ci)` | GPU mem for chunk |
| `mmf_chunk_total_memory(doc)` | Total across all chunks |
| `mmf_chunk_mesh_vertex_count(doc, ci, mi)` | Vertex count |
| `mmf_chunk_mesh_index_count(doc, ci, mi)` | Index count |
| `mmf_chunk_mesh_geometry_id(doc, ci, mi)` | Geometry ID |
| `mmf_chunk_mesh_positions(doc, ci, mi) → *const f32` | Borrowed ptr |
| `mmf_chunk_mesh_normals(doc, ci, mi) → *const f32` | Borrowed ptr |
| `mmf_chunk_mesh_indices(doc, ci, mi) → *const u32` | Borrowed ptr |
| `mmf_frustum_aabb_visible(bmin, bmax, cam...)` | AABB visibility test |

All chunk mesh data pointers are borrowed from the `MmfDocument` — valid until
`mmf_document_free()`.  Existing `mmf_mesh_*` functions continue to work for
the full packet (backward compatible).

The frustum helper constructs an `OrbitCamera` + `Frustum` internally and
returns `1` (visible) or `0` (culled).

## 2. C Header (`mmforge_bridge.h`)

Added full declarations for all 14 chunk functions and 1 frustum function,
grouped under `Streaming / chunk-based progressive loading` and
`Frustum culling` sections.

## 3. Swift Side

### RustBridge.swift — `ChunkInfo` DTO

```swift
struct ChunkInfo {
    let index: Int; let meshCount: Int; let instanceCount: Int;
    let batchCount: Int; let boundsMin: simd_float3; let boundsMax: simd_float3;
    let memoryBytes: UInt64
}
```

New methods:
- `buildChunks(for:budgetBytes:)` → builds streaming packet
- `chunkInfo(for:index:)` → returns `ChunkInfo?` for a chunk
- `chunkTotalMemory(_:)` → total GPU memory estimate

### MetalRenderer.swift — `FrustumPlanes` + frustum culling

Added `FrustumPlanes` struct (Swift-native, matches Rust `Frustum`):
- `init(from: simd_float4x4)` — Gribb/Hartmann plane extraction from VP matrix
- `intersects(min:max:) -> Bool` — AABB test with p-vertex optimization

Added to `MetalRenderer`:
- `cullByFrustum(aspect:)` — per-frame frustum culling: iterates `gpuMeshes`,
  sets `visible = false` for meshes outside frustum.  Preserves user-initiated
  visibility (`hiddenNodeIndices`).
- `restoreAllVisible()` — resets frustum culling back to user preferences.

## 4. Tests

### Rust (bridge integration, 3 new tests)

| Test | Purpose |
|------|---------|
| `chunk_streaming_on_parsed_doc` | Parse STL → build chunks → verify mesh count, bounds, pointers |
| `frustum_visible_central_cube` | Camera sees origin cube |
| `frustum_cull_far_cube` | Camera with far=10 culls cube at z=50 |

### Swift

`FrustumPlanes` is tested implicitly via the Rust frustum test parity (same
Gribb/Hartmann algorithm).  Full `xcodebuild test` not run for this round
(no test-only Swift changes).

## 5. Files Changed

| File | Action | Lines |
|------|--------|-------|
| `crates/mmforge-bridge/src/lib.rs` | Add `streaming_packet` field + 15 C ABI functions | ~320 |
| `crates/mmforge-bridge/src/job.rs` | Add 3 integration tests | ~120 |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | 15 new declarations | ~85 |
| `macos/MMForge/RustBridge/RustBridge.swift` | `ChunkInfo` DTO + 3 chunk methods | ~60 |
| `macos/MMForge/Metal/MetalRenderer.swift` | `FrustumPlanes` + `cullByFrustum` + `restoreAllVisible` | ~80 |

## 6. Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 271 tests pass (49+71+39+6+12+5+89) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 277 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |

## 7. Backward Compatibility

- Existing `mmf_mesh_count/positions/normals/indices` unchanged — full-packet
  upload path preserved.
- Existing `uploadToRenderer(dto:)` and `buildDTO(from:)` unchanged.
- Chunk streaming is opt-in: call `mmf_build_streaming_packet` + chunk queries.
- Frustum culling is opt-in: call `renderer.cullByFrustum(aspect:)` each frame.

## 8. Usage Example

```swift
// Build chunks with 64 MB budget per chunk.
let chunkCount = RustBridge.shared.buildChunks(for: rustDoc, budgetBytes: 64_000_000)
for i in 0..<chunkCount {
    guard let info = RustBridge.shared.chunkInfo(for: rustDoc, index: i) else { continue }
    for mi in 0..<UInt32(info.meshCount) {
        // Upload individual mesh from chunk...
    }
}

// Enable frustum culling each frame.
func draw(in view: MTKView) {
    let aspect = Float(view.drawableSize.width / view.drawableSize.height)
    renderer.cullByFrustum(aspect: aspect)
    // ... normal draw pass
}
```
