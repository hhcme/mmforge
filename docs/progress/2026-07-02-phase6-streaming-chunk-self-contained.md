# Phase 6 Round 6: Streaming Chunk Self-Contained Semantics

**Date**: 2026-07-02
**Scope**: Make RenderChunk fully self-contained — add `batches` field, enforce
chunk-local `mesh_id` invariants, add comprehensive regression tests.

## Changes

### 1. RenderChunk gains `batches: Vec<RenderBatch>`

The `batches` vector built by `finish_chunk` (grouping consecutive instances by
`material_id`) was previously discarded — only `stats.batch_count` stored its
length.  Now `RenderChunk` carries the actual batch array:

```rust
pub struct RenderChunk {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    pub instance_indices: Vec<usize>,
    pub batches: Vec<RenderBatch>,    // ← NEW
    pub chunk_bounds: BoundingBox,
    pub stats: RenderStats,
}
```

`RenderBatch` is already exported from `crate::packet`, no additional re-export
needed.

Invariant enforced: `chunk.stats.batch_count == chunk.batches.len()`.

### 2. Chunk-local mesh_id enforced

`finish_chunk` now rewrites each mesh's `mesh_id` to its index in the chunk:

```rust
for (i, mesh) in chunk_meshes.iter_mut().enumerate() {
    mesh.mesh_id = i as u32;
}
```

This guarantees:
- `chunk.meshes[i].mesh_id == i` for all i.
- Every `chunk.instances[*].mesh_id` is a valid index into `chunk.meshes`.

The `mesh_remap` table already maps original mesh_index → chunk-local index for
instances; the mesh's own `mesh_id` field is now consistent with that remapping.

### 3. New regression tests (+8)

| Test | What it verifies |
|------|-----------------|
| `chunk_mesh_ids_are_local_indices` | `meshes[i].mesh_id == i` |
| `instance_mesh_id_indexes_into_chunk_meshes` | All `instances[*].mesh_id < meshes.len()` |
| `chunks_have_batches_field` | `chunk.batches` is non-empty |
| `batch_count_matches_stats_and_batches_len` | `stats.batch_count == batches.len()` |
| `batch_instance_ranges_cover_all_instances` | Every chunk instance is covered by exactly one batch |
| `batch_instance_ranges_are_contiguous_and_non_overlapping` | Batches partition `[0, instances.len())` contiguously |
| `multi_material_chunk_splits_batches` | 4 instances with 3 material changes → ≥3 batches |
| `multi_chunk_each_chunk_has_its_own_batches` | Budget split into 3+ chunks, each with valid self-contained batches |

## Files Changed

| File | Action |
|------|--------|
| `crates/mmforge-render/src/streaming.rs` | Add `batches` field, rewrite `mesh_id`, 8 new tests |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 268 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 274 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |

**streaming tests: 19** (was 11: +8 new)
