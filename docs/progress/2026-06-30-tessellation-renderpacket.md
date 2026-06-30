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

Full pipeline E2E verified: STEP → parse+tessellate → LsmModel +
TessellationRegistry → RenderPacket → debug JSON.

E2E output: `PQ-04909-A.STEP` → 1 mesh, 4554 triangles.

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

### TessellationRegistry — `parse_step_with_tessellation()`

`mmforge_format_step::parse_step_with_tessellation(path)` reads a STEP
file and tessellates all B-Rep shapes in one pass (reader alive during
tessellation).  Returns `(ParseOutput, TessellationRegistry)` where the
registry maps `GeometryId` → `TessellatedMeshData`.

This solves the B-Rep lifecycle problem: tessellation must happen while
the OCCT reader and shapes are still alive.  The registry captures the
mesh data before the reader is dropped.

### Full Pipeline API

```
STEP file
  → parse_step_with_tessellation(path)
  → (ParseOutput { model, warnings, stats }, TessellationRegistry)
  → build_render_packet(&registry)
  → RenderPacket { meshes, materials, instances, batches, scene_bounds, stats }
  → to_debug_json()
```

### Build.rs — 22 required symbols

Both `mmforge-geometry` and `mmforge-format-step` build.rs now require
22 symbols (14 existing + 8 tessellation).

---

## E2E Test Output (real OCCT 7.9.3)

**Tessellation adapter test** (`tessellate_step_fixture`):
```
tessellate[0]: 3015 vertices, 4554 triangles,
  bounds=BoundingBox { min: Vec3(-22.403, -5.588, -22.403), max: Vec3(22.403, 3.937, 22.403) }
```

**Full pipeline test** (`e2e_step_tessellation_to_renderpacket`):
```
E2E pipeline: 2 nodes, 1 geometries, 1 meshes, 4554 triangles
  scene_bounds=BoundingBox { min: Vec3(-22.403, -5.588, -22.403), max: Vec3(22.403, 3.937, 22.403) }
  debug_json={"batch_count":1,"material_count":1,"mesh_count":1,"scene_bounds":{...},"stats":{...}}
```

Validations:
- ✅ TessellationRegistry non-empty, matches geometry count
- ✅ Every BRepHandleRef has corresponding mesh in registry
- ✅ vertex_count > 0, triangle_count > 0, bounds valid
- ✅ RenderPacket: meshes, instances, materials, batches correct
- ✅ scene_bounds valid
- ✅ debug JSON contains stats, mesh_count, triangle_count

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
| `shim/README.md` | Fixed symbol count 21→22 |
| `src/occt/sys.rs` | Added MmfMesh + 8 extern declarations |
| `src/occt/adapter.rs` | Added TessellatedMesh + e2e test; fixed cfg gates and clippy |
| `src/occt/step_reader.rs` | Added `read_step_file_with_tessellation` |
| `src/tessellation.rs` | Added TessellatedMeshData + TessellationRegistry |
| `build.rs` (geometry) | Updated REQUIRED_SHIM_SYMBOLS to 22 |
| `build.rs` (format-step) | Updated REQUIRED_SHIM_SYMBOLS to 22 |
| `mmforge-format-step/src/lib.rs` | Re-export `parse_step_with_tessellation` |
| `mmforge-format-step/src/parser.rs` | Added `parse_step_with_tessellation` + full pipeline e2e test |
| `mmforge-format-step/Cargo.toml` | Added mmforge-render dev-dependency |
| `mmforge-render/src/builder.rs` | New — RenderPacketBuilder |
| `mmforge-render/src/lib.rs` | Export builder module |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 79 tests pass |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 84 tests pass (55+13+8+8) |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` (real OCCT) | ✅ No warnings |

---

## Risks

| Risk | Mitigation |
|------|-----------|
| Tessellation performance on large models | Use Preview quality first, upgrade in background |
| Memory usage for large meshes | TessellatedMesh freed on Drop; positions/normals copied to Rust Vecs |
| OCCT version differences in BRepMesh API | Tested on 7.9; API stable since 7.5 |
| Fake shim doesn't test real tessellation | Real OCCT e2e test covers the full path |
| RenderPacketBuilder doesn't handle Mesh geometry yet | Only BRepHandleRef supported; Mesh geometry support is future work |
