#!/usr/bin/env swift
// Standalone BVH picking verification — runs without Xcode test target.
// Usage: swift macos/MMForgeTests/BVHPickingTests.swift

import Foundation

// Minimal simd imports for standalone test.
#if canImport(simd)
import simd
#else
// Fallback: define simd types inline for Linux CI.
#endif

// MARK: - Inline Ray/Hit/BVH types (matches Picking.swift)

struct Ray {
    let origin: SIMD3<Float>
    let dir: SIMD3<Float>
    let invDir: SIMD3<Float>
    init(origin: SIMD3<Float>, dir: SIMD3<Float>) {
        self.origin = origin
        self.dir = dir
        self.invDir = SIMD3<Float>(
            abs(dir.x) > 1e-12 ? 1.0 / dir.x : Float.infinity,
            abs(dir.y) > 1e-12 ? 1.0 / dir.y : Float.infinity,
            abs(dir.z) > 1e-12 ? 1.0 / dir.z : Float.infinity
        )
    }
}

struct HitResult {
    let t: Float
    let point: SIMD3<Float>
    let normal: SIMD3<Float>
    let triangleIndex: Int
}

func rayTriangleIntersect(
    ray: Ray, v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
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

struct BVHNode {
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var leftChild: Int
    var rightChild: Int
    var triIndex: Int
    var triCount: Int
    var isLeaf: Bool { triCount > 0 }
}

struct MeshBVH {
    let nodes: [BVHNode]
    let sortedTriIndices: [Int]
    let positions: [Float]
    let indices: [UInt32]

    func intersect(ray: Ray, tMin: Float, tMax: Float) -> HitResult? {
        guard !nodes.isEmpty else { return nil }
        var bestT = tMax
        var bestHit: HitResult?
        intersectNode(ray: ray, nodeIndex: 0, tMin: tMin, bestT: &bestT, bestHit: &bestHit)
        return bestHit
    }

    private func intersectNode(ray: Ray, nodeIndex: Int, tMin: Float,
                                bestT: inout Float, bestHit: inout HitResult?) {
        let node = nodes[nodeIndex]
        guard rayAABB(ray: ray, bmin: node.boundsMin, bmax: node.boundsMax,
                      tMin: tMin, tMax: bestT) else { return }
        if node.isLeaf {
            for i in 0..<node.triCount {
                let sortedIdx = node.triIndex + i
                let triIdx = sortedTriIndices[sortedIdx]
                let i0 = Int(indices[triIdx * 3])
                let i1 = Int(indices[triIdx * 3 + 1])
                let i2 = Int(indices[triIdx * 3 + 2])
                let v0 = vertex(i0), v1 = vertex(i1), v2 = vertex(i2)
                if let hit = rayTriangleIntersect(ray: ray, v0: v0, v1: v1, v2: v2,
                                                   tMin: tMin, tMax: bestT) {
                    if hit.t < bestT {
                        bestT = hit.t
                        bestHit = HitResult(t: hit.t, point: hit.point,
                                            normal: hit.normal, triangleIndex: triIdx)
                    }
                }
            }
        } else {
            intersectNode(ray: ray, nodeIndex: node.leftChild,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
            intersectNode(ray: ray, nodeIndex: node.rightChild,
                          tMin: tMin, bestT: &bestT, bestHit: &bestHit)
        }
    }

    private func vertex(_ index: Int) -> SIMD3<Float> {
        let o = index * 3
        return SIMD3<Float>(positions[o], positions[o+1], positions[o+2])
    }
}

func rayAABB(ray: Ray, bmin: SIMD3<Float>, bmax: SIMD3<Float>,
             tMin: Float, tMax: Float) -> Bool {
    let t1 = (bmin - ray.origin) * ray.invDir
    let t2 = (bmax - ray.origin) * ray.invDir
    let tmin3 = simd_min(t1, t2)
    let tmax3 = simd_max(t1, t2)
    let tmin = max(tmin3.x, max(tmin3.y, tmin3.z))
    let tmax = min(tmax3.x, min(tmax3.y, tmax3.z))
    return tmin <= tmax && tmax >= tMin && tmin <= tMax
}

func buildMeshBVH(positions: [Float], indices: [UInt32]) -> MeshBVH {
    let triCount = indices.count / 3
    guard triCount > 0 else {
        return MeshBVH(nodes: [], sortedTriIndices: [], positions: positions, indices: indices)
    }
    struct TriInfo {
        var centroid: SIMD3<Float>
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var originalIndex: Int
    }
    func vert(_ positions: [Float], _ index: Int) -> SIMD3<Float> {
        let o = index * 3
        return SIMD3<Float>(positions[o], positions[o+1], positions[o+2])
    }
    var triInfos: [TriInfo] = []
    for i in 0..<triCount {
        let i0 = Int(indices[i*3]), i1 = Int(indices[i*3+1]), i2 = Int(indices[i*3+2])
        let v0 = vert(positions, i0), v1 = vert(positions, i1), v2 = vert(positions, i2)
        let bmin = simd_min(v0, simd_min(v1, v2))
        let bmax = simd_max(v0, simd_max(v1, v2))
        triInfos.append(TriInfo(centroid: (v0+v1+v2)/3.0, boundsMin: bmin, boundsMax: bmax, originalIndex: i))
    }
    var nodes: [BVHNode] = []
    var sortedIndices: [Int] = []
    func build(begin: Int, end: Int) -> Int {
        let nodeIndex = nodes.count
        nodes.append(BVHNode(boundsMin: .zero, boundsMax: .zero, leftChild: 0, rightChild: 0, triIndex: 0, triCount: 0))
        var nodeMin = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var nodeMax = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)
        for i in begin..<end {
            nodeMin = simd_min(nodeMin, triInfos[i].boundsMin)
            nodeMax = simd_max(nodeMax, triInfos[i].boundsMax)
        }
        let count = end - begin
        if count <= 4 {
            let triIndex = sortedIndices.count
            for i in begin..<end { sortedIndices.append(triInfos[i].originalIndex) }
            nodes[nodeIndex] = BVHNode(boundsMin: nodeMin, boundsMax: nodeMax, leftChild: 0, rightChild: 0, triIndex: triIndex, triCount: count)
            return nodeIndex
        }
        let extent = nodeMax - nodeMin
        let axis: Int
        if extent.x >= extent.y && extent.x >= extent.z { axis = 0 }
        else if extent.y >= extent.z { axis = 1 }
        else { axis = 2 }
        let mid = (begin + end) / 2
        triInfos[begin..<end].sort { $0.centroid[axis] < $1.centroid[axis] }
        let left = build(begin: begin, end: mid)
        let right = build(begin: mid, end: end)
        nodes[nodeIndex] = BVHNode(boundsMin: nodeMin, boundsMax: nodeMax, leftChild: left, rightChild: right, triIndex: 0, triCount: 0)
        return nodeIndex
    }
    _ = build(begin: 0, end: triCount)
    return MeshBVH(nodes: nodes, sortedTriIndices: sortedIndices, positions: positions, indices: indices)
}

// MARK: - Tests

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(message) (\(file):\(line))")
    }
}

// Test 1: Ray-triangle hit
do {
    let ray = Ray(origin: SIMD3<Float>(0.25, 0.25, -1), dir: SIMD3<Float>(0, 0, 1))
    let hit = rayTriangleIntersect(ray: ray, v0: SIMD3<Float>(0,0,0), v1: SIMD3<Float>(1,0,0), v2: SIMD3<Float>(0,1,0), tMin: 0, tMax: 100)
    assert(hit != nil, "ray-triangle should hit")
    if let h = hit {
        assert(abs(h.t - 1.0) < 1e-5, "t should be 1.0, got \(h.t)")
    }
}

// Test 2: Ray-triangle miss
do {
    let ray = Ray(origin: SIMD3<Float>(2, 2, -1), dir: SIMD3<Float>(0, 0, 1))
    let hit = rayTriangleIntersect(ray: ray, v0: SIMD3<Float>(0,0,0), v1: SIMD3<Float>(1,0,0), v2: SIMD3<Float>(0,1,0), tMin: 0, tMax: 100)
    assert(hit == nil, "ray-triangle should miss")
}

// Test 3: BVH build with 12 triangles (cube)
do {
    let p: [Float] = [
        0,0,0, 1,0,0, 1,1,0, 0,1,0,
        0,0,1, 1,0,1, 1,1,1, 0,1,1,
    ]
    let idx: [UInt32] = [0,1,2, 0,2,3, 4,6,5, 4,7,6, 0,3,7, 0,7,4, 1,5,6, 1,6,2, 0,4,5, 0,5,1, 3,2,6, 3,6,7]
    let bvh = buildMeshBVH(positions: p, indices: idx)
    assert(!bvh.nodes.isEmpty, "BVH should have nodes")
    assert(bvh.sortedTriIndices.count == 12, "should have 12 sorted indices, got \(bvh.sortedTriIndices.count)")
}

// Test 4: BVH empty
do {
    let bvh = buildMeshBVH(positions: [], indices: [])
    assert(bvh.nodes.isEmpty, "empty BVH should have no nodes")
}

// Test 5: Closest hit selection (two triangles at z=1 and z=5)
do {
    var positions: [Float] = [0,0,1, 1,0,1, 0.5,1,1, 0,0,5, 1,0,5, 0.5,1,5]
    let indices: [UInt32] = [0,1,2, 3,4,5]
    let bvh = buildMeshBVH(positions: positions, indices: indices)
    let ray = Ray(origin: SIMD3<Float>(0.5, 0.5, -1), dir: SIMD3<Float>(0, 0, 1))
    if let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 100) {
        assert(abs(hit.t - 2.0) < 1e-5, "should hit z=1 triangle (t=2.0), got \(hit.t)")
    } else {
        assert(false, "should hit closer triangle")
    }
}

// Test 6: Clip interval excludes behind origin
do {
    let p: [Float] = [0,0,0, 1,0,0, 0.5,1,0]
    let idx: [UInt32] = [0,1,2]
    let bvh = buildMeshBVH(positions: p, indices: idx)
    let ray = Ray(origin: SIMD3<Float>(0.5, 0.5, -1), dir: SIMD3<Float>(0, 0, -1))
    let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 100)
    assert(hit == nil, "ray pointing away should not hit")
}

// Test 7: tMax excludes hit
do {
    let p: [Float] = [0,0,0, 1,0,0, 0.5,1,0]
    let idx: [UInt32] = [0,1,2]
    let bvh = buildMeshBVH(positions: p, indices: idx)
    let ray = Ray(origin: SIMD3<Float>(0.5, 0.5, -1), dir: SIMD3<Float>(0, 0, 1))
    let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 0.5)
    assert(hit == nil, "tMax too small should exclude hit")
}

// Test 8: AABB hit
do {
    let ray = Ray(origin: SIMD3<Float>(0.5, 0.5, -1), dir: SIMD3<Float>(0, 0, 1))
    assert(rayAABB(ray: ray, bmin: SIMD3<Float>(0,0,0), bmax: SIMD3<Float>(1,1,1), tMin: 0, tMax: 100), "AABB should hit")
}

// Test 9: AABB miss
do {
    let ray = Ray(origin: SIMD3<Float>(5, 5, -1), dir: SIMD3<Float>(0, 0, 1))
    assert(!rayAABB(ray: ray, bmin: SIMD3<Float>(0,0,0), bmax: SIMD3<Float>(1,1,1), tMin: 0, tMax: 100), "AABB should miss")
}

// Test 10: BVH right child hit (8+ triangles)
do {
    var positions: [Float] = []
    var indices: [UInt32] = []
    for i in 0..<4 {
        let base = UInt32(positions.count / 3)
        let z = Float(i) * 0.5
        positions.append(contentsOf: [0, 0, z, 1, 0, z, 0.5, 1, z])
        indices.append(contentsOf: [base, base+1, base+2])
    }
    for i in 0..<4 {
        let base = UInt32(positions.count / 3)
        let z = Float(i) * 0.5
        positions.append(contentsOf: [2, 0, z, 3, 0, z, 2.5, 1, z])
        indices.append(contentsOf: [base, base+1, base+2])
    }
    let bvh = buildMeshBVH(positions: positions, indices: indices)
    let ray = Ray(origin: SIMD3<Float>(2.5, 0.5, -1), dir: SIMD3<Float>(0, 0, 1))
    let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 100)
    assert(hit != nil, "BVH should find triangle in right child")
}

// Summary
print("\n=== BVH Picking Tests ===")
print("Passed: \(passed)")
print("Failed: \(failed)")
if failed > 0 {
    print("RESULT: FAIL")
    exit(1)
} else {
    print("RESULT: PASS")
}
