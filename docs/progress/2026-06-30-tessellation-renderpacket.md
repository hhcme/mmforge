# Tessellation & RenderPacket — Real OCCT B-Rep to GPU-Ready Mesh

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Implement real OCCT B-Rep tessellation → platform-neutral
        RenderPacket pipeline with debug JSON and fixture regression

---

## Summary

Real OCCT `BRepMesh_IncrementalMesh` tessellation is now operational.
STEP B-Rep shapes are tessellated into triangle meshes (positions,
normals, indices) and can be packed into a platform-neutral
`RenderPacket` for GPU upload.

E2E verified: `PQ-04909-A.STEP` → 3015 vertices, 4554 triangles.

---

## What Was Added

### C++ Shim — 8 new tessellation functions

| Function | Purpose |
|----------|---------|
| `mmforge_tessellate_shape` | BRepMesh_IncrementalMesh + face traversal |
| `mmforge_mesh_vertex_count` | Vertex count |
| `mmforge_mesh_triangle_count` | Triangle count |
| `mmforge_mesh_positions` | Flat float array [x0,y0,z0,...] |
| `mmforge_mesh_normals` | Flat float array [nx0,ny0,nz0,...] |
| `mmforge_mesh_indices` | Flat int array [i0,i1,i2,...] (0-based) |
| `mmforge_mesh_bbox` | AABB of tessellated mesh |
| `mmforge_mesh_free` | Free mesh buffers |

C++ implementation details:
- `BRepMesh_IncrementalMesh` with configurable linear deflection
- `TopExp_Explorer` iterates faces → `BRep_Tool::Triangulation`
- Handles face orientation (reversed winding)
- Normals from `Poly_Triangulation::Normal()` or cross-product fallback
- OCCT 1-based indices → 0-based in output
- Bounding box computed from actual vertex positions

### Rust Adapter — `TessellatedMesh`

`TessellatedMesh::tessellate(reader, shape, deflection)` — safe wrapper
that:
1. Calls `mmforge_tessellate_shape`
2. Copies positions, normals, indices into Rust `Vec`s
3. Copies bounding box
4. Frees the OCCT mesh on `Drop`

### tessellation.rs — `TessellatedMeshData`

Platform-neutral mesh container: `positions: Vec<[f32; 3]>`,
`normals: Vec<[f32; 3]>`, `indices: Vec<u32>`, `bounds: BoundingBox`.

### RenderPacketBuilder — `build_render_packet()`

`mmforge-render::builder::build_render_packet(mesh_data)` converts
`HashMap<GeometryId, TessellatedMeshData>` into a `RenderPacket` with:
- One `RenderMesh` per geometry
- One default `RenderMaterial` (steel-grey)
- One `RenderInstance` per mesh
- One `RenderBatch`
- Aggregate `scene_bounds` and `RenderStats`

Debug JSON via `RenderPacket::to_debug_json()`.

### Build.rs — 22 required symbols

Both `mmforge-geometry` and `mmforge-format-step` build.rs now require
22 symbols (14 existing + 8 tessellation).

---

## E2E Test Output (real OCCT 7.9.3)

```
tessellate[0]: 3015 vertices, 4554 triangles,
  bounds=BoundingBox {
    min: Vec3(-22.403, -5.588, -22.403),
    max: Vec3(22.403, 3.937, 22.403)
  }
```

Validations:
- ✅ vertex_count > 0
- ✅ triangle_count > 0
- ✅ bounds valid
- ✅ all positions finite
- ✅ all normals non-zero (length > 0.001)
- ✅ all indices in range [0, vertex_count)

---

## Quality Presets

| Quality | Deflection | PQ-04909-A (approx) |
|---------|-----------|---------------------|
| Preview | bbox_diag × 0.002 | ~500 triangles |
| Standard | bbox_diag × 0.0005 | ~4500 triangles |
| High | bbox_diag × 0.0001 | ~50000 triangles |

---

## Files Modified

| File | Change |
|------|--------|
| `shim/mmforge_occt_shim.h` | Added MmfMesh + 8 functions |
| `shim/mmforge_occt_shim.cpp` | Implemented BRepMesh tessellation |
| `src/occt/sys.rs` | Added MmfMesh + 8 extern declarations |
| `src/occt/adapter.rs` | Added TessellatedMesh + e2e test; fixed cfg gates |
| `src/tessellation.rs` | Added TessellatedMeshData |
| `build.rs` (geometry) | Updated REQUIRED_SHIM_SYMBOLS to 22 |
| `build.rs` (format-step) | Updated REQUIRED_SHIM_SYMBOLS to 22 |
| `mmforge-render/src/builder.rs` | New — RenderPacketBuilder |
| `mmforge-render/src/lib.rs` | Export builder module |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 79 tests pass |
| `cargo test --workspace --features occt` | ✅ 81 tests pass |
| `cargo test -p mmforge-geometry --features occt` (real OCCT) | ✅ 8 tests pass, tessellation verified |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Risks

| Risk | Mitigation |
|------|-----------|
| Tessellation performance on large models | Use Preview quality first, upgrade in background |
| Memory usage for large meshes | TessellatedMesh freed on Drop; positions/normals copied to Rust Vecs |
| OCCT version differences in BRepMesh API | Tested on 7.9; API stable since 7.5 |
| Fake shim doesn't test real tessellation | Real OCCT e2e test covers the full path |
| RenderPacketBuilder doesn't handle Mesh geometry yet | Only BRepHandleRef supported; Mesh geometry support is future work |
