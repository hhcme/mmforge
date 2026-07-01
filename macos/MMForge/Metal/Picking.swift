import simd

// MARK: - Ray

struct Ray {
    let origin: simd_float3
    let dir: simd_float3
    let invDir: simd_float3

    init(origin: simd_float3, dir: simd_float3) {
        self.origin = origin
        self.dir = dir
        self.invDir = simd_float3(
            abs(dir.x) > 1e-12 ? 1.0 / dir.x : Float.infinity,
            abs(dir.y) > 1e-12 ? 1.0 / dir.y : Float.infinity,
            abs(dir.z) > 1e-12 ? 1.0 / dir.z : Float.infinity
        )
    }
}

// MARK: - Hit result

struct HitResult {
    let t: Float
    let point: simd_float3
    let normal: simd_float3
    let triangleIndex: Int  // original triangle index (into indices array)
}

// MARK: - Ray–Triangle (Möller–Trumbore)

func rayTriangleIntersect(
    ray: Ray,
    v0: simd_float3, v1: simd_float3, v2: simd_float3,
    tMin: Float, tMax: Float
) -> HitResult? {
    let e1 = v1 - v0
    let e2 = v2 - v0
    let pvec = cross(ray.dir, e2)
    let det = dot(e1, pvec)
    guard abs(det) > 1e-12 else { return nil }

    let invDet = 1.0 / det
    let tvec = ray.origin - v0
    let u = dot(tvec, pvec) * invDet
    guard u >= 0 && u <= 1 else { return nil }

    let qvec = cross(tvec, e1)
    let v = dot(ray.dir, qvec) * invDet
    guard v >= 0 && u + v <= 1 else { return nil }

    let t = dot(e2, qvec) * invDet
    guard t > tMin && t < tMax else { return nil }

    let normal = normalize(cross(e1, e2))
    let point = ray.origin + ray.dir * t
    return HitResult(t: t, point: point, normal: normal, triangleIndex: 0)
}

// MARK: - BVH Node

/// Flat BVH node.
///
/// Internal node: `isLeaf == false`, children at `leftChild` and `rightChild`.
/// Leaf node: `isLeaf == true`, holds `triCount` triangles starting at
/// `triIndex` in the **sorted** triangle array.
struct BVHNode {
    var boundsMin: simd_float3
    var boundsMax: simd_float3
    var leftChild: Int      // child node index (internal) or 0
    var rightChild: Int     // child node index (internal) or 0
    var triIndex: Int       // index into sortedTriIndices (leaf) or 0
    var triCount: Int       // triangle count (leaf) or 0
    var isLeaf: Bool { triCount > 0 }
}

// MARK: - MeshBVH

/// Per-mesh BVH for fast ray–triangle picking.
///
/// `sortedTriIndices` maps BVH leaf triangle indices back to the
/// original `indices` array.  Each leaf holds a contiguous range
/// `[triIndex, triIndex + triCount)` in this sorted array.
struct MeshBVH {
    let nodes: [BVHNode]
    let sortedTriIndices: [Int]  // sorted triangle indices into original indices
    let positions: [Float]       // flat [x0,y0,z0, ...]
    let indices: [UInt32]        // flat [i0,i1,i2, ...]

    /// Query the BVH for the closest ray–triangle hit.
    func intersect(ray: Ray, tMin: Float, tMax: Float) -> HitResult? {
        guard !nodes.isEmpty else { return nil }
        var bestT = tMax
        var bestHit: HitResult?
        intersectNode(ray: ray, nodeIndex: 0, tMin: tMin, bestT: &bestT, bestHit: &bestHit)
        return bestHit
    }

    private func intersectNode(ray: Ray, nodeIndex: Int,
                                tMin: Float, bestT: inout Float,
                                bestHit: inout HitResult?) {
        let node = nodes[nodeIndex]

        // AABB test — prune if ray doesn't hit this node's bounds.
        guard rayAABB(ray: ray, bmin: node.boundsMin, bmax: node.boundsMax,
                      tMin: tMin, tMax: bestT) else { return }

        if node.isLeaf {
            // Test each triangle in the leaf.
            for i in 0..<node.triCount {
                let sortedIdx = node.triIndex + i
                let triIdx = sortedTriIndices[sortedIdx]
                let i0 = Int(indices[triIdx * 3])
                let i1 = Int(indices[triIdx * 3 + 1])
                let i2 = Int(indices[triIdx * 3 + 2])
                let v0 = vertex(i0)
                let v1 = vertex(i1)
                let v2 = vertex(i2)
                if let hit = rayTriangleIntersect(ray: ray, v0: v0, v1: v1, v2: v2,
                                                   tMin: tMin, tMax: bestT) {
                    if hit.t < bestT {
                        bestT = hit.t
                        bestHit = HitResult(
                            t: hit.t, point: hit.point, normal: hit.normal,
                            triangleIndex: triIdx
                        )
                    }
                }
            }
        } else {
            // Recurse into explicit left/right children.
            intersectNode(ray: ray, nodeIndex: node.leftChild,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
            intersectNode(ray: ray, nodeIndex: node.rightChild,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
        }
    }

    private func vertex(_ index: Int) -> simd_float3 {
        let o = index * 3
        return simd_float3(positions[o], positions[o + 1], positions[o + 2])
    }
}

// MARK: - Ray–AABB (slab method)

/// Fast ray–AABB test (slab method).
///
/// Handles NaN from 0*infinity (ray parallel to axis, origin on boundary)
/// by treating NaN as "inside the slab" for that axis.
func rayAABB(ray: Ray, bmin: simd_float3, bmax: simd_float3,
             tMin: Float, tMax: Float) -> Bool {
    var tmin: Float = 0
    var tmax: Float = .infinity

    for axis in 0..<3 {
        let o = ray.origin[axis]
        let inv = ray.invDir[axis]
        let lo = bmin[axis]
        let hi = bmax[axis]

        let t1 = (lo - o) * inv
        let t2 = (hi - o) * inv

        if t1.isNaN || t2.isNaN {
            // Ray parallel to this axis and origin on boundary.
            // If origin is inside [lo, hi], continue (no constraint).
            // If outside, no hit.
            if o < lo - 1e-12 || o > hi + 1e-12 { return false }
            // else: no constraint from this axis
        } else {
            let axisMin = min(t1, t2)
            let axisMax = max(t1, t2)
            tmin = max(tmin, axisMin)
            tmax = min(tmax, axisMax)
            if tmin > tmax { return false }
        }
    }

    return tmax >= tMin && tmin <= tMax
}

// MARK: - BVH Builder

/// Build a BVH from triangle soup.
///
/// Input validation:
/// - `positions.count` must be a multiple of 3 (xyz triples).
/// - `indices.count` must be a multiple of 3 (triangle triples).
/// - Each index must be < `positions.count / 3`.
/// - Invalid triangles are silently skipped.
///
/// Returns an empty BVH if no valid triangles remain after filtering.
func buildMeshBVH(positions: [Float], indices: [UInt32]) -> MeshBVH {
    // Validate positions layout.
    guard positions.count % 3 == 0 else {
        return MeshBVH(nodes: [], sortedTriIndices: [],
                       positions: positions, indices: indices)
    }
    let vertexCount = positions.count / 3

    // Validate indices layout.
    guard indices.count % 3 == 0 else {
        return MeshBVH(nodes: [], sortedTriIndices: [],
                       positions: positions, indices: indices)
    }
    let triCount = indices.count / 3

    guard triCount > 0, vertexCount > 0 else {
        return MeshBVH(nodes: [], sortedTriIndices: [],
                       positions: positions, indices: indices)
    }

    // Per-triangle metadata (sorted during build).
    struct TriInfo {
        var centroid: simd_float3
        var boundsMin: simd_float3
        var boundsMax: simd_float3
        var originalIndex: Int  // index into original indices array
    }

    // Filter: only keep triangles whose indices are in range.
    var triInfos: [TriInfo] = []
    triInfos.reserveCapacity(triCount)
    for i in 0..<triCount {
        let i0 = Int(indices[i * 3])
        let i1 = Int(indices[i * 3 + 1])
        let i2 = Int(indices[i * 3 + 2])
        // Skip triangles with out-of-bounds indices.
        guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else {
            continue
        }
        let v0 = vert(positions, i0)
        let v1 = vert(positions, i1)
        let v2 = vert(positions, i2)
        let bmin = simd_min(v0, simd_min(v1, v2))
        let bmax = simd_max(v0, simd_max(v1, v2))
        triInfos.append(TriInfo(
            centroid: (v0 + v1 + v2) / 3.0,
            boundsMin: bmin, boundsMax: bmax,
            originalIndex: i
        ))
    }

    guard !triInfos.isEmpty else {
        return MeshBVH(nodes: [], sortedTriIndices: [],
                       positions: positions, indices: indices)
    }

    // Use filtered count — not the original triCount — for all
    // subsequent sizing and build calls.
    let validTriCount = triInfos.count

    var nodes: [BVHNode] = []
    nodes.reserveCapacity(validTriCount * 2)
    var sortedIndices: [Int] = []
    sortedIndices.reserveCapacity(validTriCount)

    func build(begin: Int, end: Int) -> Int {
        let nodeIndex = nodes.count
        nodes.append(BVHNode(
            boundsMin: .zero, boundsMax: .zero,
            leftChild: 0, rightChild: 0, triIndex: 0, triCount: 0
        ))

        // Compute node AABB from all triangles in [begin, end).
        var nodeMin = simd_float3(Float.infinity, Float.infinity, Float.infinity)
        var nodeMax = simd_float3(-Float.infinity, -Float.infinity, -Float.infinity)
        for i in begin..<end {
            nodeMin = simd_min(nodeMin, triInfos[i].boundsMin)
            nodeMax = simd_max(nodeMax, triInfos[i].boundsMax)
        }

        let count = end - begin
        if count <= 4 {
            // Leaf: append sorted triangle indices.
            let triIndex = sortedIndices.count
            for i in begin..<end {
                sortedIndices.append(triInfos[i].originalIndex)
            }
            nodes[nodeIndex] = BVHNode(
                boundsMin: nodeMin, boundsMax: nodeMax,
                leftChild: 0, rightChild: 0,
                triIndex: triIndex, triCount: count
            )
            return nodeIndex
        }

        // Internal node: split on longest axis at median centroid.
        let extent = nodeMax - nodeMin
        let axis: Int
        if extent.x >= extent.y && extent.x >= extent.z { axis = 0 }
        else if extent.y >= extent.z { axis = 1 }
        else { axis = 2 }

        let mid = (begin + end) / 2
        triInfos[begin..<end].sort { a, b in
            a.centroid[axis] < b.centroid[axis]
        }

        let left = build(begin: begin, end: mid)
        let right = build(begin: mid, end: end)

        nodes[nodeIndex] = BVHNode(
            boundsMin: nodeMin, boundsMax: nodeMax,
            leftChild: left, rightChild: right,
            triIndex: 0, triCount: 0
        )
        return nodeIndex
    }

    _ = build(begin: 0, end: validTriCount)

    return MeshBVH(
        nodes: nodes, sortedTriIndices: sortedIndices,
        positions: positions, indices: indices
    )
}

private func vert(_ positions: [Float], _ index: Int) -> simd_float3 {
    let o = index * 3
    return simd_float3(positions[o], positions[o + 1], positions[o + 2])
}
