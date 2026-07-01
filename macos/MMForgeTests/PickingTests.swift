import XCTest
import simd
@testable import MMForge

// MARK: - BVH / Ray-Triangle Picking Tests
//
// Tests reference the production code in Picking.swift via
// `@testable import MMForge`.  No implementation is duplicated.

final class PickingTests: XCTestCase {

    // MARK: - Ray–Triangle

    func testRayTriangleHit() {
        let ray = Ray(origin: simd_float3(0.25, 0.25, -1), dir: simd_float3(0, 0, 1))
        let hit = rayTriangleIntersect(
            ray: ray,
            v0: simd_float3(0, 0, 0), v1: simd_float3(1, 0, 0), v2: simd_float3(0, 1, 0),
            tMin: 0, tMax: 100
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.t ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertEqual(hit?.point.x ?? 0, 0.25, accuracy: 1e-5)
        XCTAssertEqual(hit?.point.y ?? 0, 0.25, accuracy: 1e-5)
        XCTAssertEqual(hit?.point.z ?? 0, 0.0, accuracy: 1e-5)
    }

    func testRayTriangleMiss() {
        let ray = Ray(origin: simd_float3(2, 2, -1), dir: simd_float3(0, 0, 1))
        let hit = rayTriangleIntersect(
            ray: ray,
            v0: simd_float3(0, 0, 0), v1: simd_float3(1, 0, 0), v2: simd_float3(0, 1, 0),
            tMin: 0, tMax: 100
        )
        XCTAssertNil(hit)
    }

    func testDegenerateTriangleCollinear() {
        // Three collinear points — zero-area triangle.
        let ray = Ray(origin: simd_float3(0.5, 0.5, -1), dir: simd_float3(0, 0, 1))
        let hit = rayTriangleIntersect(
            ray: ray,
            v0: simd_float3(0, 0, 0), v1: simd_float3(1, 0, 0), v2: simd_float3(2, 0, 0),
            tMin: 0, tMax: 100
        )
        XCTAssertNil(hit, "collinear triangle should not be hit")
    }

    func testDegenerateTriangleCoincident() {
        // Three identical points — zero-area triangle.
        let ray = Ray(origin: simd_float3(0, 0, -1), dir: simd_float3(0, 0, 1))
        let hit = rayTriangleIntersect(
            ray: ray,
            v0: simd_float3(1, 1, 1), v1: simd_float3(1, 1, 1), v2: simd_float3(1, 1, 1),
            tMin: 0, tMax: 100
        )
        XCTAssertNil(hit, "coincident triangle should not be hit")
    }

    // MARK: - Ray–AABB

    func testRayAABBHit() {
        let ray = Ray(origin: simd_float3(0.5, 0.5, -1), dir: simd_float3(0, 0, 1))
        XCTAssertTrue(rayAABB(ray: ray, bmin: simd_float3(0, 0, 0), bmax: simd_float3(1, 1, 1), tMin: 0, tMax: 100))
    }

    func testRayAABBMiss() {
        let ray = Ray(origin: simd_float3(5, 5, -1), dir: simd_float3(0, 0, 1))
        XCTAssertFalse(rayAABB(ray: ray, bmin: simd_float3(0, 0, 0), bmax: simd_float3(1, 1, 1), tMin: 0, tMax: 100))
    }

    func testRayAABBParallelToFace() {
        // Ray parallel to the z-min face, outside the box.
        let ray = Ray(origin: simd_float3(0.5, -1, 0.5), dir: simd_float3(0, 0, 1))
        XCTAssertFalse(rayAABB(ray: ray, bmin: simd_float3(0, 0, 0), bmax: simd_float3(1, 1, 1), tMin: 0, tMax: 100))
    }

    func testRayAABBParallelInside() {
        // Ray parallel to an axis, inside the box.
        let ray = Ray(origin: simd_float3(0.5, 0.5, 0.5), dir: simd_float3(0, 0, 1))
        XCTAssertTrue(rayAABB(ray: ray, bmin: simd_float3(0, 0, 0), bmax: simd_float3(1, 1, 1), tMin: 0, tMax: 100))
    }

    func testRayAABBOnEdge() {
        // Ray starts exactly on the box edge.
        let ray = Ray(origin: simd_float3(0, 0, -1), dir: simd_float3(0, 0, 1))
        XCTAssertTrue(rayAABB(ray: ray, bmin: simd_float3(0, 0, 0), bmax: simd_float3(1, 1, 1), tMin: 0, tMax: 100))
    }

    // MARK: - BVH Build

    func testBVHBuildNonEmpty() {
        let (positions, indices) = makeCubeMesh()
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        XCTAssertFalse(bvh.nodes.isEmpty)
        XCTAssertEqual(bvh.sortedTriIndices.count, 12)
    }

    func testBVHBuildEmpty() {
        let bvh = buildMeshBVH(positions: [], indices: [])
        XCTAssertTrue(bvh.nodes.isEmpty)
        XCTAssertTrue(bvh.sortedTriIndices.isEmpty)
    }

    func testBVHBuildEmptyIndices() {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let bvh = buildMeshBVH(positions: positions, indices: [])
        XCTAssertTrue(bvh.nodes.isEmpty)
    }

    func testBVHBuildSingleTriangle() {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let indices: [UInt32] = [0, 1, 2]
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        XCTAssertEqual(bvh.nodes.count, 1)
        XCTAssertTrue(bvh.nodes[0].isLeaf)
        XCTAssertEqual(bvh.sortedTriIndices.count, 1)
    }

    // MARK: - BVH Query

    func testBVHClosestHit() {
        // Two triangles at z=1 and z=5.  Should hit the closer one.
        let positions: [Float] = [0,0,1, 1,0,1, 0.5,1,1, 0,0,5, 1,0,5, 0.5,1,5]
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5]
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        let ray = Ray(origin: simd_float3(0.5, 0.5, -1), dir: simd_float3(0, 0, 1))
        let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 100)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.t ?? 0, 2.0, accuracy: 1e-5)
    }

    func testBVHRightChildHit() {
        // 8 triangles: 4 at x=0..1, 4 at x=2..3.  BVH splits on X.
        // Ray hits the right group.
        var positions: [Float] = []
        var indices: [UInt32] = []
        for i in 0..<4 {
            let base = UInt32(positions.count / 3)
            let z = Float(i) * 0.5
            positions.append(contentsOf: [0, 0, z, 1, 0, z, 0.5, 1, z])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        for i in 0..<4 {
            let base = UInt32(positions.count / 3)
            let z = Float(i) * 0.5
            positions.append(contentsOf: [2, 0, z, 3, 0, z, 2.5, 1, z])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        let ray = Ray(origin: simd_float3(2.5, 0.5, -1), dir: simd_float3(0, 0, 1))
        let hit = bvh.intersect(ray: ray, tMin: 0, tMax: 100)
        XCTAssertNotNil(hit, "BVH should find triangle in right child")
    }

    func testBVHTMinExcludesBehindOrigin() {
        let (positions, indices) = makeCubeMesh()
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        let ray = Ray(origin: simd_float3(0.5, 0.5, -1), dir: simd_float3(0, 0, -1))
        XCTAssertNil(bvh.intersect(ray: ray, tMin: 0, tMax: 100))
    }

    func testBVHTMaxExcludesHit() {
        let (positions, indices) = makeCubeMesh()
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        let ray = Ray(origin: simd_float3(0.5, 0.5, -1), dir: simd_float3(0, 0, 1))
        // Cube face is at z=0, ray starts at z=-1, so t=1.  tMax=0.5 excludes.
        XCTAssertNil(bvh.intersect(ray: ray, tMin: 0, tMax: 0.5))
    }

    func testBVHSortedLeafAccess() {
        // Verify that the BVH correctly maps sorted indices back to
        // original triangles.
        let (positions, indices) = makeCubeMesh()
        let bvh = buildMeshBVH(positions: positions, indices: indices)
        // All sorted indices should be valid original triangle indices.
        for idx in bvh.sortedTriIndices {
            XCTAssertGreaterThanOrEqual(idx, 0)
            XCTAssertLessThan(idx, 12)
        }
        // All original triangles should be represented.
        let sorted = Set(bvh.sortedTriIndices)
        XCTAssertEqual(sorted.count, 12, "all 12 triangles should be in sorted index")
    }

    // MARK: - Helpers

    private func makeCubeMesh() -> (positions: [Float], indices: [UInt32]) {
        let positions: [Float] = [
            0,0,0, 1,0,0, 1,1,0, 0,1,0,
            0,0,1, 1,0,1, 1,1,1, 0,1,1,
        ]
        let indices: [UInt32] = [
            0,1,2, 0,2,3,   // front
            4,6,5, 4,7,6,   // back
            0,3,7, 0,7,4,   // left
            1,5,6, 1,6,2,   // right
            0,4,5, 0,5,1,   // bottom
            3,2,6, 3,6,7,   // top
        ]
        return (positions, indices)
    }
}
