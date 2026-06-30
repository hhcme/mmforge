import simd

// MARK: - Ray

struct Ray {
    let origin: simd_float3
    let dir: simd_float3
    let invDir: simd_float3  // 1/dir per axis (precomputed for AABB test)

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
    let t: Float           // ray parameter
    let point: simd_float3 // world-space hit point
    let normal: simd_float3 // face normal at hit point
    let triangleIndex: Int  // index of hit triangle
}

// MARK: - Ray–Triangle intersection (Möller–Trumbore)

/// Test ray against a single triangle.  Returns HitResult if t > tMin.
func rayTriangleIntersect(
    ray: Ray,
    v0: simd_float3, v1: simd_float3, v2: simd_float3,
    tMin: Float, tMax: Float
) -> HitResult? {
    let e1 = v1 - v0
    let e2 = v2 - v0
    let pvec = cross(ray.dir, e2)
    let det = dot(e1, pvec)

    // Ray parallel to triangle — no hit.
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

/// Flat BVH node.  If `triOffset >= 0`, it's a leaf holding
/// `triCount` triangles starting at `triOffset`.  Otherwise it's
/// an internal node with children at `leftIndex` and `leftIndex+1`.
struct BVHNode {
    var boundsMin: simd_float3
    var boundsMax: simd_float3
    var leftIndex: Int    // child index (internal) or triangle offset (leaf)
    var rightCount: Int   // right child index offset (internal) or triangle count (leaf)
    var isLeaf: Bool { rightCount < 0 }
    var triOffset: Int { leftIndex }
    var triCount: Int { -rightCount }
}

// MARK: - MeshBVH

/// Per-mesh BVH for fast ray–triangle picking.
/// Built once on mesh upload, queried for each pick.
struct MeshBVH {
    let nodes: [BVHNode]
    let positions: [Float]   // flat [x0,y0,z0, x1,y1,z1, ...]
    let indices: [UInt32]    // flat [i0,i1,i2, i3,i4,i5, ...]

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

        // AABB test for this node.
        guard rayAABB(ray: ray, bmin: node.boundsMin, bmax: node.boundsMax,
                      tMin: tMin, tMax: bestT) else { return }

        if node.isLeaf {
            // Test each triangle in the leaf.
            for i in 0..<node.triCount {
                let triIdx = node.triOffset + i
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
            // Recurse into children.
            intersectNode(ray: ray, nodeIndex: node.leftIndex,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
            intersectNode(ray: ray, nodeIndex: node.leftIndex + 1,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
        }
    }

    private func vertex(_ index: Int) -> simd_float3 {
        let offset = index * 3
        return simd_float3(positions[offset], positions[offset + 1], positions[offset + 2])
    }
}

/// Fast ray–AABB test using precomputed invDir.
func rayAABB(ray: Ray, bmin: simd_float3, bmax: simd_float3,
             tMin: Float, tMax: Float) -> Bool {
    let t1 = (bmin - ray.origin) * ray.invDir
    let t2 = (bmax - ray.origin) * ray.invDir
    let tmin3 = simd_min(t1, t2)
    let tmax3 = simd_max(t1, t2)
    let tmin = max(tmin3.x, max(tmin3.y, tmin3.z))
    let tmax = min(tmax3.x, min(tmax3.y, tmax3.z))
    return tmin <= tmax && tmax >= tMin && tmin <= tMax
}

// MARK: - BVH Builder

/// Build a BVH from triangle soup.  Top-down recursive split on
/// longest AABB axis at median centroid.
func buildMeshBVH(positions: [Float], indices: [UInt32]) -> MeshBVH {
    let triCount = indices.count / 3
    guard triCount > 0 else {
        return MeshBVH(nodes: [], positions: positions, indices: indices)
    }

    // Build triangle info: centroid + AABB per triangle.
    struct TriInfo {
        var centroid: simd_float3
        var boundsMin: simd_float3
        var boundsMax: simd_float3
        var index: Int
    }

    var triInfos: [TriInfo] = []
    triInfos.reserveCapacity(triCount)
    for i in 0..<triCount {
        let i0 = Int(indices[i * 3])
        let i1 = Int(indices[i * 3 + 1])
        let i2 = Int(indices[i * 3 + 2])
        let v0 = vert(positions, i0)
        let v1 = vert(positions, i1)
        let v2 = vert(positions, i2)
        let bmin = simd_min(v0, simd_min(v1, v2))
        let bmax = simd_max(v0, simd_max(v1, v2))
        triInfos.append(TriInfo(
            centroid: (v0 + v1 + v2) / 3.0,
            boundsMin: bmin, boundsMax: bmax, index: i
        ))
    }

    var nodes: [BVHNode] = []
    nodes.reserveCapacity(triCount * 2)

    func build(begin: Int, end: Int) -> Int {
        let nodeIndex = nodes.count
        nodes.append(BVHNode(boundsMin: .zero, boundsMax: .zero,
                             leftIndex: 0, rightCount: 0))

        // Compute node AABB.
        var nodeMin = simd_float3(Float.infinity, Float.infinity, Float.infinity)
        var nodeMax = simd_float3(-Float.infinity, -Float.infinity, -Float.infinity)
        for i in begin..<end {
            nodeMin = simd_min(nodeMin, triInfos[i].boundsMin)
            nodeMax = simd_max(nodeMax, triInfos[i].boundsMax)
        }

        let count = end - begin
        if count <= 4 {
            // Leaf node.
            nodes[nodeIndex] = BVHNode(
                boundsMin: nodeMin, boundsMax: nodeMax,
                leftIndex: begin, rightCount: -count
            )
            return nodeIndex
        }

        // Split on longest axis at median centroid.
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
            leftIndex: left, rightCount: right - left
        )
        return nodeIndex
    }

    _ = build(begin: 0, end: triCount)

    return MeshBVH(nodes: nodes, positions: positions, indices: indices)
}

private func vert(_ positions: [Float], _ index: Int) -> simd_float3 {
    let o = index * 3
    return simd_float3(positions[o], positions[o + 1], positions[o + 2])
}
