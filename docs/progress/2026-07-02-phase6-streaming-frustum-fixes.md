# Phase 6 Round 5: Streaming, Frustum, Memory Fixes

**Date**: 2026-07-02
**Scope**: Fix three blocking bugs from Round 4: incorrect instance↔mesh mapping in `StreamingPacket`, wrong row/column indexing in `Frustum::from_view_projection`, and non-atomic `MemoryBudget::release`.

## Bugs Fixed

### 1. StreamingPacket: instance↔mesh mapping and batch stats

**Bug**: `from_packet` assumed a 1:1 mapping `meshes[i] ↔ instances[i]` (linear
index correspondence).  Real `RenderPacket`s have instances pointing to meshes
via `mesh_id`, and multiple instances can share one mesh.  This caused chunks to
drop instances, carry wrong instance counts, and produce invalid `batch_count`.

**Fix**: Complete rewrite of `from_packet` + `finish_chunk`:
- Build `mesh_to_instances: HashMap<usize, Vec<usize>>` mapping each original
  mesh index to all instance indices referencing it.
- For each mesh assigned to a chunk, collect **all** instances with that
  `mesh_id`, deduplicating by original instance index.
- Remap each instance's `mesh_id` from the original (global) value to the
  chunk-local index via `mesh_remap: HashMap<usize, u32>`.
- Rebuild `RenderBatch` arrays by grouping consecutive instances by `material_id`
  (handles multi-material splits correctly).
- `stats.instance_count` is computed from `chunk_instance_indices.len()` **before**
  the move into `RenderChunk`, guaranteeing it matches actual instances.
- `stats.batch_count` reflects actual batch groups, not a hardcoded `1`.

Added tests:
- `multiple_instances_per_mesh_are_all_collected` — 2 meshes, 3 instances
  (mesh 0 instanced twice), verifies all 3 reach the chunk.
- `instance_mesh_ids_remapped_to_local` — verifies remapped mesh_ids are
  valid chunk-local indices.
- `stats_instance_count_matches_after_chunking` — sum of chunk instance
  counts equals total original instances.
- `stats_triangle_count_preserved` — sum of chunk triangle counts matches
  original packet.

### 2. Frustum::from_view_projection: row/column indexing + near/far formula

**Bug 1 — row/column indexing**: The original code used `m[3][0] + m[0][0]`
etc., interpreting `m[col][component]` incorrectly.  `glam`'s
`to_cols_array_2d()` returns `m[col][row_component]` where the outer index is
the column.  In column-major storage, row R is `(m[0][R], m[1][R], m[2][R], m[3][R])`.

The original code's `m[3][0]` (translation column x-component) was used where
`m[0][3]` (column-0's w-component, i.e., Row 3's first element) was needed.

**Bug 2 — near/far formula**: The original used D3D convention (near = Row 2)
instead of OpenGL (near = Row 3 + Row 2).  glam's `perspective_rh` produces
OpenGL-style [-1, 1] NDC z-range, requiring the OpenGL formulas.

**Fix**: Corrected all six plane extraction formulas:

```
Left:   (m[0][3]+m[0][0], m[1][3]+m[1][0], m[2][3]+m[2][0], m[3][3]+m[3][0])
Right:  (m[0][3]-m[0][0], m[1][3]-m[1][0], m[2][3]-m[2][0], m[3][3]-m[3][0])
Bottom: (m[0][3]+m[0][1], m[1][3]+m[1][1], m[2][3]+m[2][1], m[3][3]+m[3][1])
Top:    (m[0][3]-m[0][1], m[1][3]-m[1][1], m[2][3]-m[2][1], m[3][3]-m[3][1])
Near:   (m[0][3]+m[0][2], m[1][3]+m[1][2], m[2][3]+m[2][2], m[3][3]+m[3][2])
Far:    (m[0][3]-m[0][2], m[1][3]-m[1][2], m[2][3]-m[2][2], m[3][3]-m[3][2])
```

The fix was verified empirically: a probe test confirmed that for a camera at
z=10 looking at z=5 with near=0.1, the extracted near plane is
`(0, 0, -1, 9.949975)` — normal pointing toward -Z (into the frustum), plane
at z≈9.95, producing negative signed-distances for points between the eye and
the plane.

Added per-boundary tests: near, far, left, right, top, bottom (both AABB and
sphere), plus `signed_distances_consistent` for direct plane-value verification
with `Frustum::signed_distances()`.

### 3. MemoryBudget::release: CAS loop to prevent concurrent underflow

**Bug**: `release` used `fetch_sub(bytes.min(self.used()))` — the `self.used()`
load and the `fetch_sub` were not atomic together.  Two concurrent `release`
calls could both read the same `used` value, then both subtract, causing the
counter to wrap below zero (underflow).

**Fix**: Replaced with a CAS loop:
```rust
let mut current = self.used.load(Ordering::Relaxed);
loop {
    let new = current.saturating_sub(bytes);
    match self.used.compare_exchange_weak(current, new, …) {
        Ok(_) => return,
        Err(prev) => current = prev,
    }
}
```

Added tests: `release_more_than_used_clamps_to_zero`, `release_partial_frees_remaining`.

## Files Changed

| File | Action | Lines |
|------|--------|-------|
| `crates/mmforge-render/src/streaming.rs` | Rewrite `from_packet` + `finish_chunk`, add 4 tests | ~410 |
| `crates/mmforge-render/src/frustum.rs` | Fix row/col indexing, add per-boundary tests + `signed_distances` | ~370 |
| `crates/mmforge-render/src/memory.rs` | CAS loop for `release`, add 2 tests | ~20 |

## Verification Results

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 260 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 266 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles and links |

**render crate tests: 81** (was 67 in Round 4: +4 streaming, +7 frustum, +2 memory, +1 signed_distances)

| Module | Round 4 | Round 5 | Δ |
|--------|---------|---------|---|
| streaming | 7 | 11 | +4 |
| frustum | 7 | 14 | +7 |
| memory | 7 | 9 | +2 |
| Total (render) | 67 | 81 | +14 |
