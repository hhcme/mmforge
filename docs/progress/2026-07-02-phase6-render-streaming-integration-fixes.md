# Phase 6 Round 8: Streaming/Frustum Integration Fixes

**Date**: 2026-07-02
**Scope**: Fix four blocking issues from the Round 7 integration: frustum visibility
separation, chunk upload path, unsafe buffer, and budget rebuild API.

## Fixes

### 1. Frustum culling: separated user + frame visibility

**Bug**: `cullByFrustum` directly set `gpuMeshes[i].visible = false` on culled
meshes, permanently destroying user visibility state.  On the next frame the
mesh stayed invisible even if the camera moved.  `restoreAllVisible` was the
only escape, requiring explicit call.

**Fix**: Added `frustumCulledIndices: Set<Int>` — a frame-local set rebuilt
each frame by `updateFrustumCulling(aspect:)`.  This set never touches
`gpuMeshes[*].visible`.  `drawPass` and `backToFrontIndices` now check
`mesh.visible && !frustumCulledIndices.contains(idx)` — two independent
layers:

- `gpuMeshes[*].visible` = user/manual hide (persistent)
- `frustumCulledIndices` = camera-side cull (rebuilt each frame)

`updateFrustumCulling` is called at the top of `draw(in:)` every frame.

### 2. Chunk streaming upload path

Added a complete, opt-in chunk upload pipeline from Rust to Metal:

- `RustBridge.uploadChunk(from:chunkIndex:nodeMap:nodeInfos:into:)` — iterates
  all meshes in chunk `chunkIndex`, reads positions/normals/indices via
  `mmf_chunk_mesh_*`, and calls `renderer.upload(...)` per mesh.

- `RustBridge.rebuildChunks(for:budgetBytes:)` — resets then rebuilds chunks
  with a new budget (calls `mmf_reset_streaming_packet` + `mmf_build_streaming_packet`).

- `DocumentViewModel` public entry points:
  - `uploadChunk(chunkIndex:dto:)` — upload one chunk (progressive, no clear)
  - `buildChunks(budgetBytes:)` → builds streaming packet
  - `rebuildChunks(budgetBytes:)` → reset + rebuild
  - `chunkCount()` → number of chunks
  - `chunkInfo(index:)` → ChunkInfo? for one chunk

Existing `uploadToRenderer(dto:)` full-packet path is **unchanged** — chunk
upload coexists as an additional opt-in path.

### 3. Unsafe buffer in `chunkInfo`

**Bug**: `withUnsafeMutablePointer(to: &minOut.x)` passes a pointer to a single
`Float` (the `.x` component of `simd_float3`), relying on the caller
(`mmf_chunk_bounds`) to write three consecutive `f32` values starting from that
address.  While `simd_float3` happens to be laid out as three consecutive
floats in memory, the coding pattern is unsound in Swift.

**Fix**: Replaced with `[Float](repeating: 0, count: 3)` arrays and
`withUnsafeMutableBufferPointer` — a properly sized contiguous buffer:

```swift
var mins = [Float](repeating: 0, count: 3)
var maxs = [Float](repeating: 0, count: 3)
let boundsOk = mins.withUnsafeMutableBufferPointer { minBuf in
    maxs.withUnsafeMutableBufferPointer { maxBuf in
        mmf_chunk_bounds(docPtr, index, minBuf.baseAddress, maxBuf.baseAddress)
    }
}
```

Then read back as `simd_float3(mins[0], mins[1], mins[2])`.

### 4. Budget rebuild / reset API

**Bug**: `mmf_build_streaming_packet` was idempotent — once built, subsequent
calls with different budgets returned the same chunk count.

**Fix**: Added `mmf_reset_streaming_packet(doc)` that clears
`streaming_packet` so the next `mmf_build_streaming_packet` rebuilds with the
new budget.

Test: `reset_rebuild_chunks_with_new_budget` — builds with tiny budget (many
chunks), resets, rebuilds with large budget (fewer chunks), confirms reset is
required for budget change.

## Files Changed

| File | Change |
|------|--------|
| `macos/MMForge/Metal/MetalRenderer.swift` | `frustumCulledIndices`, `updateFrustumCulling` called from `draw()`, separate check in `drawPass` + `backToFrontIndices` |
| `macos/MMForge/RustBridge/RustBridge.swift` | Fix `chunkInfo` buffer; add `uploadChunk`, `rebuildChunks` |
| `macos/MMForge/Document/MMForgeDocument.swift` | Add `uploadChunk`, `buildChunks`, `rebuildChunks`, `chunkCount`, `chunkInfo` entry points |
| `crates/mmforge-bridge/src/lib.rs` | Add `mmf_reset_streaming_packet` |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | Declare `mmf_reset_streaming_packet` |
| `crates/mmforge-bridge/src/job.rs` | Add `reset_rebuild_chunks_with_new_budget` test |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 272 tests pass (50+71+39+6+12+5+89) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 278 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
