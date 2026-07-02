# Phase 6 Round 4: Render Streaming, LOD, Memory Budget, Frustum Culling

**Date**: 2026-07-02
**Scope**: Implement the remaining Phase 6 infrastructure for large-model handling: memory budget tracking, render packet streaming/chunking, LOD level selection, and view-frustum culling.

## New Modules

All four new modules are in `crates/mmforge-render/src/`. No new crate or dependency was added.

### 1. Memory Budget (`memory.rs`)

**Purpose**: Track GPU resource allocation against a configurable budget to prevent memory exhaustion on large models.

- `MemoryBudget` — atomic `capacity`/`used` tracker with thread-safe `reserve`/`release`/`reset`.
  - `capacity()` / `used()` / `available()` / `usage_fraction()`
  - `reserve(bytes) -> bool` compares-and-swaps atomically, rejects over-budget
  - `release(bytes)` / `reset()` for lifecycle management
- `gpu_mesh_memory_bytes(vc, ic)` — estimates 24 bytes/vertex (pos+normal interleaved) + 4 bytes/index
- `gpu_mesh_memory_with_uvs(vc, ic)` — estimates 32 bytes/vertex (pos+normal+uv) + 4 bytes/index

Common presets: 64 MB (mobile), 256 MB (desktop), 1 GB (workstation).

**Tests** (7): new budget zero usage, reserve within/over budget, release frees space, usage fraction, mesh cost estimation both with and without UVs.

### 2. Frustum Culling (`frustum.rs`)

**Purpose**: Extract 6 view-frustum planes from a view-projection matrix and test AABB/sphere visibility.

- `Frustum` — six planes (left, right, bottom, top, near, far) as `Vec4`.
  - `from_view_projection(&vp)` — Gribb/Hartmann plane extraction from combined projection×view
  - `normalise()` — unit-length plane normals (required before intersection queries)
  - `intersects_aabb(&BoundingBox)` — n-vertex/p-vertex optimisation per plane
  - `intersects_sphere(center, radius)` — signed-distance test per plane
  - `planes() -> [Vec4; 6]` — all six planes for uniforms or iteration

**Architecture note**: Reuses `OrbitCamera` methods (`view_matrix`, `projection_matrix`) to construct the VP matrix, keeping the frustum module independent of any specific camera type.

**Tests** (7): central box visible, box behind camera culled, box far away culled, sphere inside/outside, empty AABB rejected, all planes provided.

### 3. LOD System (`lod.rs`)

**Purpose**: Select mesh quality level based on camera distance.

- `LodLevel` (`Preview`, `Standard`, `High`) — ordinal with `deflection_fraction()` mapping to tessellation quality table:
  - Preview: 0.002× diag (fast)
  - Standard: 0.0005× diag (balanced)
  - High: 0.0001× diag (full, for inspection)
- `LodSelector` — `near`/`far` distance thresholds with `scaled(factor)` for model-size adaptation.
  - `select(distance) -> LodLevel` — simple distance-based selection
  - `select_for_bounds(center, eye) -> LodLevel` — convenience using camera eye position
  - `can_share_mesh(from, to) -> bool` — currently true (all LODs share single tessellated mesh; simplification deferred)
- `LodSelection { level, visible }` — result type for batch LOD assignment.

**Tests** (7): deflection fractions match spec, distance selection, threshold edge cases, scaled thresholds, bounds-based selection, ordinal ordering, can_share_mesh.

### 4. RenderPacket Streaming (`streaming.rs`)

**Purpose**: Split a monolithic `RenderPacket` into memory-budgeted `RenderChunk`s for incremental GPU upload.

- `RenderChunk` — self-contained subset: `meshes`, `materials`, `instances`, `instance_indices` (mapping back to original packet), `chunk_bounds`, `stats`.
- `StreamingPacket` — greedy chunking algorithm:
  - `from_packet(&RenderPacket, &MemoryBudget) -> StreamingPacket`
  - Iterates meshes in packet order; when next mesh would exceed budget, finishes current chunk and starts new one
  - Guarantees at least one mesh per chunk (graceful degradation)
  - Re-indexes local `mesh_id` within each chunk
  - Copies materials into every chunk for consistent bindings
  - `chunk_count()`, `chunk(idx)`, `iter_chunks()`, `into_chunks()`

**Tests** (7): empty packet → no chunks, single small mesh in one chunk, multiple meshes split at budget boundary, single large mesh gets own chunk, chunk bounds cover all meshes, `iter_chunks` count matches, `into_chunks` consumes.

## Public API Surface

Updated `lib.rs` to export all new types:

```rust
pub mod frustum;
pub mod lod;
pub mod memory;
pub mod streaming;

pub use frustum::Frustum;
pub use lod::{LodLevel, LodSelection, LodSelector};
pub use memory::{gpu_mesh_memory_bytes, MemoryBudget};
pub use streaming::{RenderChunk, StreamingPacket};
```

## Files Changed

| File | Action |
|------|--------|
| `crates/mmforge-render/src/memory.rs` | New — 164 lines |
| `crates/mmforge-render/src/frustum.rs` | New — 208 lines |
| `crates/mmforge-render/src/lod.rs` | New — 175 lines |
| `crates/mmforge-render/src/streaming.rs` | New — 326 lines |
| `crates/mmforge-render/src/lib.rs` | Modified — added 4 modules + re-exports |

**No files outside `mmforge-render` were changed.** The new types are purely additive and no existing code was broken.

## Verification Results

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 246 tests pass (was 218: +28 new) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 252 tests pass (incl. all new + OCCT E2E) |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles and links |

### Test Breakdown

| Crate | Tests (locked) | Tests (+occt) |
|-------|---------------|---------------|
| mmforge-bridge | 46 | 46 |
| mmforge-core | 71 | 71 |
| mmforge-format-dxf | 39 | 39 |
| mmforge-format-iges | 6 | 6 |
| mmforge-format-step | 12 | 13 |
| mmforge-geometry | 5 | 10 |
| mmforge-render | **67** | **67** |
| **Total** | **246** | **252** |

The `mmforge-render` test count grew from 39 to 67 (+28 new tests across the four new modules).

## Architecture Decisions

1. **All new code is in `mmforge-render`** — follows the existing crate boundary: no platform, GPU, or UI dependency.

2. **Frustum is camera-agnostic** — accepts any `&glam::Mat4` (projection × view), so it works with `OrbitCamera`, fly-cam, or future camera types.

3. **Streaming is greedy, not optimal** — a greedy bin-packing approach is simple and predictable. Optimal packing (knapsack) would add complexity with minimal benefit for the common case where meshes are roughly uniform in size.

4. **LOD currently shares the single tessellated mesh** — `can_share_mesh()` always returns true because we don't yet have mesh simplices. Adding coarser LODs via mesh simplification (e.g. fast-quadric or edge-collapse) is a future task.

5. **MemoryBudget is lock-free** — uses `AtomicUsize` CAS loops instead of `Mutex`, suitable for hot paths in background threads.

## Known Limitations

- LOD does not yet generate simplified meshes; all levels use the same geometry.
- Frustum culling is not yet integrated into the bridge/Swift pipeline — it provides the math but the renderer must call it.
- Streaming chunks are CPU-side only; there is no GPU-side streaming ring buffer.
- No `xcodebuild test` was run for this round since no Swift files were changed.

## Next Steps

- Integrate frustum culling into the render pipeline (Metal renderer visibility test)
- Add LOD-driven quality control to the tessellation pipeline
- Use `MemoryBudget` + `StreamingPacket` in the Swift DTO builder for progressive loading
- Implement mesh simplifier for true multi-resolution LOD
