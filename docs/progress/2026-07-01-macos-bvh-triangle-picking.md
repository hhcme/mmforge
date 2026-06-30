# BVH Triangle Picking — Real Mesh Hit Detection

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Upgrade AABB picking to BVH-accelerated ray–triangle
        intersection for accurate node selection and measurement

---

## Summary

Picking now uses real mesh triangle data instead of AABB approximation.
Each uploaded mesh gets a CPU-side BVH built on upload.  Ray–triangle
intersection uses the Möller–Trumbore algorithm.  Hidden nodes,
clipping planes, and both camera projections are respected.

---

## Architecture

### Picking.swift (new)

- **`Ray`** — origin + dir + precomputed invDir
- **`HitResult`** — t, point, normal, triangleIndex
- **`BVHNode`** — flat node: AABB + leaf/internal flag + child/triangle refs
- **`MeshBVH`** — per-mesh BVH with `intersect(ray:tMin:tMax:)` query
- **`buildMeshBVH(positions:indices:)`** — top-down recursive builder
- **`rayTriangleIntersect()`** — Möller–Trumbore algorithm
- **`rayAABB()`** — fast slab test with precomputed invDir

### BVH Builder

Top-down recursive split:
1. Compute per-triangle centroid and AABB
2. Split on longest AABB axis at median centroid
3. Leaf threshold: ≤ 4 triangles
4. Flat node array for cache-friendly traversal

### Ray–Triangle (Möller–Trumbore)

Standard algorithm with:
- Early reject: `u < 0 || u > 1`
- Early reject: `v < 0 || u + v > 1`
- Backface culling: `t > tMin && t < tMax`
- Returns hit point, face normal, triangle index

### MetalRenderer Changes

- **`GPUMesh`**: added `bvh: MeshBVH` field
- **`upload()`**: copies positions/indices to CPU arrays, builds BVH
- **`pickNode()`**: AABB quick-reject → BVH query → closest triangle
- **`pickWorldPoint()`**: same as pickNode but returns hit point
- **`screenToRay()`**: extracted common ray computation
- **`clipInterval()`**: extracted common clip interval computation
- Removed old `rayAABBIntersectRange` (replaced by `rayAABB`)

---

## Data Flow

```
upload(positions, normals, indices, ...)
  → copy positions/indices to CPU arrays
  → buildMeshBVH(cpuPositions, cpuIndices)
  → GPUMesh { ..., bvh: MeshBVH }

pickNode(at:point:)
  → screenToRay → Ray
  → clipInterval → (clipTMin, clipTMax)
  → for each visible mesh:
      rayAABB(quick reject) → skip if no hit
      mesh.bvh.intersect(ray, tMin, tMax) → HitResult?
  → return closest nodeIndex

pickWorldPoint(at:point:)
  → same as pickNode
  → return hit.point (actual triangle surface point)
```

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
| `macos/MMForge/Metal/Picking.swift` | New: Ray, HitResult, BVHNode, MeshBVH, rayTriangleIntersect, rayAABB, buildMeshBVH |
| `macos/MMForge/Metal/MetalRenderer.swift` | GPUMesh.bvh, upload builds BVH, pickNode/pickWorldPoint use BVH |
| `macos/MMForge.xcodeproj/project.pbxproj` | Added Picking.swift to project |
