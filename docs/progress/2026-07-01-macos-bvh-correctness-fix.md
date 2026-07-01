# BVH Correctness Fix — Explicit Children + Sorted Indices

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix BVH algorithm: explicit left/right children, sorted
        triangle index mapping, verification tests

---

## Fixes

### 1. BVHNode: explicit left/right children

**Before**: Internal nodes used `leftIndex` and assumed
`rightChild = leftIndex + 1`.  This broke when the BVH builder
appended nodes out of order.

**After**: `BVHNode` stores explicit `leftChild` and `rightChild`
indices.  The traversal uses these directly:

```swift
struct BVHNode {
    var boundsMin: simd_float3
    var boundsMax: simd_float3
    var leftChild: Int    // internal node child
    var rightChild: Int   // internal node child
    var triIndex: Int     // leaf: index into sortedTriIndices
    var triCount: Int     // leaf: triangle count
    var isLeaf: Bool { triCount > 0 }
}
```

### 2. Sorted triangle index mapping

**Before**: Leaf nodes indexed directly into the `indices` array
using `triOffset + i`, but the BVH sorts triangles during build.
This meant leaf bounds didn't match the tested triangles.

**After**: `MeshBVH` stores `sortedTriIndices: [Int]` — a mapping
from sorted position to original triangle index.  Leaves reference
ranges in this sorted array:

```swift
let sortedIdx = node.triIndex + i
let triIdx = sortedTriIndices[sortedIdx]  // original index
let i0 = Int(indices[triIdx * 3])
```

### 3. Leaf bounds from actual triangles

Leaf AABBs are computed from the actual triangle vertices in the
`TriInfo` array, which is sorted during build.  The leaf's
`boundsMin`/`boundsMax` exactly covers its triangles.

---

## Verification Tests (12 tests)

| # | Test | Coverage |
|---|------|----------|
| 1 | Ray-triangle hit | Möller–Trumbore correctness |
| 2 | Ray-triangle miss | Outside triangle |
| 3 | BVH build (12 triangles) | Node count, sorted indices |
| 4 | BVH empty | Edge case |
| 5 | Closest hit (2 triangles) | z=1 vs z=5, picks closer |
| 6 | Clip excludes behind origin | tMin enforcement |
| 7 | tMax excludes hit | tMax enforcement |
| 8 | AABB hit | Slab method |
| 9 | AABB miss | Outside box |
| 10 | Right child hit (8 triangles) | Explicit left/right children |

Run via: `swift macos/MMForgeTests/BVHPickingTests.swift`

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Metal/Picking.swift` | BVHNode explicit children, sortedTriIndices, MeshBVH refactor |
| `macos/MMForgeTests/BVHPickingTests.swift` | New: 12 standalone verification tests |
