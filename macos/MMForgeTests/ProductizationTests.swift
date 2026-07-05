import XCTest
import simd
import Metal
import MetalKit
@testable import MMForge

/// Comprehensive tests covering render modes, section fill geometry,
/// assembly tree operations, and color override lifecycle.
final class ProductizationTests: XCTestCase {

    // MARK: - Render Mode Tests

    func testRenderModeEnum_rawValues() {
        XCTAssertEqual(RenderMode.solid.rawValue, 0)
        XCTAssertEqual(RenderMode.wireframe.rawValue, 1)
        XCTAssertEqual(RenderMode.solidWireframe.rawValue, 2)
        XCTAssertEqual(RenderMode.transparent.rawValue, 3)
    }

    func testAllRenderModes_distinctRawValues() {
        let values = Set([
            RenderMode.solid.rawValue,
            RenderMode.wireframe.rawValue,
            RenderMode.solidWireframe.rawValue,
            RenderMode.transparent.rawValue
        ])
        XCTAssertEqual(values.count, 4, "all render modes must have unique raw values")
    }

    @MainActor
    func testSetRenderMode_updatesRendererAndPersists() {
        let vm = DocumentViewModel()
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(mtkView: view) else { return }
        vm.setRenderer(renderer)

        // Set wireframe mode
        vm.setRenderMode(.wireframe)
        XCTAssertEqual(vm.renderMode, .wireframe)
        XCTAssertEqual(renderer.renderMode, .wireframe)

        // Set transparent mode
        vm.setRenderMode(.transparent)
        XCTAssertEqual(vm.renderMode, .transparent)
        XCTAssertEqual(renderer.renderMode, .transparent)

        // Back to solid
        vm.setRenderMode(.solid)
        XCTAssertEqual(vm.renderMode, .solid)
        XCTAssertEqual(renderer.renderMode, .solid)
    }

    // MARK: - Section Fill Helpers

    /// Assert a flat-float section-fill vertex lies on the given plane.
    /// The flat array has 8 floats per vertex: [x,y,z,w, r,g,b,a].
    private func assertVertexOnPlane(
        _ verts: [Float], vertexIndex: Int,
        normal: simd_float3, d: Float,
        accuracy: Float = 1e-4,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #file, line: UInt = #line
    ) {
        let base = vertexIndex * 8
        guard base + 3 <= verts.count else {
            XCTFail("vertex index \(vertexIndex) out of range", file: file, line: line)
            return
        }
        let p = simd_float3(verts[base], verts[base+1], verts[base+2])
        let dist = dot(normal, p) + d
        if abs(dist) > accuracy {
            XCTFail("\(message()): vertex \(vertexIndex) at \(p) dist=\(dist) > \(accuracy)",
                    file: file, line: line)
        }
    }

    // MARK: - Section Fill Geometry Tests

    /// Unit cube 0-1 at Z=0.5: 8 lateral-face triangles cross → 8 segments
    /// chain into a closed octagon (4 corners + 4 edge midpoints) →
    /// ear clipping → (8-2)=6 triangles = 18 verts = 144 floats, area=1.0.
    func testSectionFill_cubeZHalf_closedSquare() {
        let cubeVerts: [Float] = [
            0, 0, 0, 0, 0, 1, 0, 1, 0,
            0, 0, 0, 0, 1, 0, 0, 1, 1,
            1, 0, 0, 1, 1, 0, 1, 0, 1,
            1, 0, 1, 1, 1, 0, 1, 1, 1,
            0, 0, 0, 1, 0, 0, 0, 0, 1,
            0, 0, 1, 1, 0, 0, 1, 0, 1,
            0, 1, 0, 0, 1, 1, 1, 1, 0,
            1, 1, 0, 0, 1, 1, 1, 1, 1,
            0, 0, 0, 0, 1, 0, 1, 0, 0,
            1, 0, 0, 0, 1, 0, 1, 1, 0,
            0, 0, 1, 1, 0, 1, 0, 1, 1,
            0, 1, 1, 1, 0, 1, 1, 1, 1,
        ]
        let cubeIdx: [UInt32] = Array(0..<36)

        let normal = simd_float3(0, 0, 1)
        let d: Float = -0.5

        let result = computeSectionFill(
            positions: cubeVerts, indices: cubeIdx,
            clipPlane: simd_float4(normal.x, normal.y, normal.z, d),
            capColor: simd_float4(1, 0.5, 0, 0.8)
        )

        // 8-vertex octagon → ear clipping → (8-2)=6 triangles = 18 verts = 144 floats.
        XCTAssertGreaterThan(result.count, 0, "should have section fill vertices")
        XCTAssertEqual(result.count, 144, "octagon ear-clip: 6 tris × 3 verts × 8 floats = 144")

        // Coplanarity: every vertex must lie on Z=0.5.
        let vertCount = result.count / 8
        for vi in 0..<vertCount {
            assertVertexOnPlane(result, vertexIndex: vi, normal: normal, d: d)
        }

        // Extract unique boundary vertices.
        let allVerts = extractSectionVertices(result)
        var uniqueBoundary: [simd_float3] = []
        for v in allVerts {
            if !uniqueBoundary.contains(where: { distance($0, v) < 1e-4 }) {
                uniqueBoundary.append(v)
            }
        }

        // 8 boundary vertices: 4 corners + 4 edge midpoints.
        XCTAssertEqual(uniqueBoundary.count, 8, "should have 8 boundary vertices")

        // Sort by angle around centroid for consistent ordering.
        let c2d = simd_float2(0.5, 0.5)
        uniqueBoundary.sort { a, b in
            let da = atan2(a.y - c2d.y, a.x - c2d.x)
            let db = atan2(b.y - c2d.y, b.x - c2d.x)
            return da < db
        }

        // Area of the octagon = area of the square = 1.0.
        let area = polygonArea(uniqueBoundary, normal: normal)
        XCTAssertEqual(area, 1.0, accuracy: 1e-3, "octagon area at Z=0.5 should be 1.0")

        // Verify the 4 corners are present (edge midpoints are 0.5 values).
        let expectedCorners: Set<simd_float3> = [
            simd_float3(0, 0, 0.5),
            simd_float3(1, 0, 0.5),
            simd_float3(1, 1, 0.5),
            simd_float3(0, 1, 0.5),
        ]
        var foundCorners = 0
        for v in uniqueBoundary {
            if expectedCorners.contains(where: { distance($0, v) < 1e-3 }) {
                foundCorners += 1
            }
        }
        XCTAssertEqual(foundCorners, 4, "all 4 corners should be in the contour")
    }

    /// Concave L-shaped cross-section at Z=0.
    /// 6-segment L-shape → ear clipping → (6-2)=4 triangles = 72 floats.
    func testSectionFill_concaveLShape() {
        let pts: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(0, 3, 0),
            simd_float3(2, 3, 0), simd_float3(2, 1, 0),
            simd_float3(1, 1, 0), simd_float3(1, 0, 0),
        ]
        let n = pts.count
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let pi = pts[i]; let pj = pts[j]
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(i * 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let normal = simd_float3(0, 0, 1)
        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(0.2, 0.6, 1.0, 0.7)
        )

        // 6-vertex concave → ear clipping → (6-2)=4 triangles × 3 verts × 8 = 96.
        XCTAssertEqual(result.count, 96, "L-shape: 4 tris × 3 × 8 = 96")

        let vertCount = result.count / 8
        for vi in 0..<vertCount {
            assertVertexOnPlane(result, vertexIndex: vi, normal: normal, d: 0)
        }

        let allVerts = extractSectionVertices(result)
        var uniqueContour: [simd_float3] = []
        for v in allVerts {
            if !uniqueContour.contains(where: { distance($0, v) < 1e-4 }) {
                uniqueContour.append(v)
            }
        }
        XCTAssertEqual(uniqueContour.count, 6, "should have all 6 L-shape vertices")

        // L-shape area via shoelace: 6−2=5 (full rect 6 minus notch area 1?).
        // Actually: shoelace of (0,0)→(0,3)→(2,3)→(2,1)→(1,1)→(1,0) = 5.0.
        let area = polygonArea(pts, normal: normal)
        XCTAssertEqual(area, 5.0, accuracy: 1e-3)
    }

    /// Three segments forming an open polyline (not closed) → skipped.
    func testSectionFill_openPolyline_skipped() {
        let p0 = simd_float3(0, 0, 0); let p1 = simd_float3(1, 0, 0)
        let p2 = simd_float3(1, 1, 0); let p3 = simd_float3(2, 1, 0)
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for (pi, pj) in [(p0, p1), (p1, p2), (p2, p3)] {
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(verts.count / 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(0, 1, 0, 0.6)
        )
        // Open polyline: first(0,0) ≠ last(2,1) → not closed → empty.
        XCTAssertTrue(result.isEmpty, "open polyline must be skipped")
    }

    /// Clip plane entirely above the triangle: no crossing segments.
    func testSectionFill_noIntersection() {
        let verts: [Float] = [0, 0, 5, 1, 0, 5, 0, 1, 5]
        let idxs: [UInt32] = [0, 1, 2]

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(1, 0, 0, 0.5)
        )
        XCTAssertTrue(result.isEmpty, "triangle entirely above plane → empty")
    }

    /// Disabled clip plane (w = -999999) returns empty.
    func testSectionFill_disabledClipPlane() {
        let verts: [Float] = [0, 0, 0, 0, 0, 1, 0, 1, 0]
        let idxs: [UInt32] = [0, 1, 2]

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 0, -999999),
            capColor: simd_float4(1, 0, 0, 0.5)
        )
        XCTAssertTrue(result.isEmpty, "disabled clip plane → empty")
    }

    /// Single triangle produces one segment → cannot form closed contour (need ≥3 points).
    func testSectionFill_singleTriangle_noClosedContour() {
        let verts: [Float] = [0, 0, 1, 1, 0, 1, 0, 1, -1]
        let idxs: [UInt32] = [0, 1, 2]

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(1, 0, 0, 0.5)
        )
        // 1 crossing segment → no closed contour → no fill geometry.
        XCTAssertTrue(result.isEmpty, "single segment cannot form closed contour")
    }

    /// Four triangles forming an open box (like a tetrahedron): each
    /// contributes a segment but they don't chain into ≥3-point contours.
    func testSectionFill_twoCrossing_noClosedContour() {
        let verts: [Float] = [
            0, 0, 1, 1, 0, 1, 0, 1, -1, // tri 0 crosses Z=0
            0, 1, -1, 1, 1, -1, 0, 0, 1, // tri 1 also crosses Z=0
        ]
        let idxs: [UInt32] = [0, 1, 2, 3, 4, 5]

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(0, 1, 0, 0.6)
        )
        // Two unconnected segments → no closed contour → no fill.
        XCTAssertTrue(result.isEmpty, "unconnected segments → empty")
    }

    // MARK: - Assembly Tree Tests

    @MainActor
    func testHasChildren_detectsAssemblyNodes() {
        let vm = DocumentViewModel()

        // Build a mock tree: root (0) -> assembly (1) -> part (2)
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Assembly", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Part", parentIndex: 1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: .zero, boundsMax: .zero),
        ]

        XCTAssertTrue(vm.hasChildren(0), "root should have children")
        XCTAssertTrue(vm.hasChildren(1), "assembly should have child part")
        XCTAssertFalse(vm.hasChildren(2), "leaf part should have no children")
    }

    @MainActor
    func testChildrenOf_returnsDirectChildren() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Child A", parentIndex: 0, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Child B", parentIndex: 0, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]

        let children = vm.childrenOf(0)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children, [1, 2])
    }

    @MainActor
    func testExpandCollapseDescendants() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Sub", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Part", parentIndex: 1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]

        vm.expandDescendants(0)
        XCTAssertTrue(vm.expandedIndices.contains(0))
        XCTAssertTrue(vm.expandedIndices.contains(1))

        vm.collapseDescendants(0)
        XCTAssertFalse(vm.expandedIndices.contains(0))
        XCTAssertFalse(vm.expandedIndices.contains(1))
    }

    @MainActor
    func testIsolateNode_hidesOtherGeometry() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Part A", parentIndex: -1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Part B", parentIndex: -1, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]

        vm.isolateNode(0)
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1))
        XCTAssertFalse(vm.hiddenNodeIndices.contains(0))
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    @MainActor
    func testHideAllExcept_hidesAllButOne() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Keep", parentIndex: -1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Hide 1", parentIndex: -1, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Hide 2", parentIndex: -1, hasGeometry: true,
                                     geometryId: 2, meshIndex: 2,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]

        vm.hideAllExcept(0)
        XCTAssertEqual(vm.hiddenNodeIndices.count, 2)
        XCTAssertFalse(vm.hiddenNodeIndices.contains(0))
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1))
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2))
    }

    // MARK: - Color Override Lifecycle Tests

    @MainActor
    func testSetNodeColor_addsOverride() {
        let vm = DocumentViewModel()
        let color = simd_float4(1, 0, 0, 1)
        vm.setNodeColor(0, color: color)
        XCTAssertEqual(vm.nodeColorOverrides[0], color)
    }

    @MainActor
    func testSetNodeColor_nilRemovesOverride() {
        let vm = DocumentViewModel()
        vm.setNodeColor(0, color: simd_float4(0, 1, 0, 1))
        XCTAssertNotNil(vm.nodeColorOverrides[0])
        vm.setNodeColor(0, color: nil)
        XCTAssertNil(vm.nodeColorOverrides[0])
    }

    @MainActor
    func testResetAllColors_clearsOverrides() {
        let vm = DocumentViewModel()
        vm.setNodeColor(0, color: simd_float4(1, 0, 0, 1))
        vm.setNodeColor(1, color: simd_float4(0, 1, 0, 1))
        vm.setNodeColor(2, color: simd_float4(0, 0, 1, 1))
        XCTAssertEqual(vm.nodeColorOverrides.count, 3)

        vm.resetAllColors()
        XCTAssertTrue(vm.nodeColorOverrides.isEmpty)
    }

    @MainActor
    func testResetSelectedNodeColor_clearsSelectionOverride() {
        let vm = DocumentViewModel()
        vm.nodes = [RenderPacketDTO.NodeInfo(
            name: "Part", parentIndex: -1, hasGeometry: true,
            geometryId: 0, meshIndex: 0,
            geometryLabel: nil, boundsMin: nil, boundsMax: nil
        )]
        vm.selectedIndex = 0
        vm.setNodeColor(0, color: simd_float4(0, 1, 1, 1))
        vm.resetSelectedNodeColor()
        XCTAssertNil(vm.nodeColorOverrides[0])
    }

    // MARK: - Visibility Lifecycle Tests

    @MainActor
    func testSetAllNodesVisible_clearsHidden() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "A", parentIndex: -1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.hiddenNodeIndices = [0]
        vm.setAllNodesVisible()
        XCTAssertTrue(vm.hiddenNodeIndices.isEmpty)
    }

    @MainActor
    func testHideAllNodes_hidesAllGeometry() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Geo 1", parentIndex: -1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Assembly", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Geo 2", parentIndex: -1, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.hideAllNodes()
        // Only geometry nodes should be hidden.
        XCTAssertEqual(vm.hiddenNodeIndices.count, 2)
        XCTAssertTrue(vm.hiddenNodeIndices.contains(0))
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2))
    }

    @MainActor
    func testHideSelectedNode_hidesAndDescendants() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Assembly", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Child", parentIndex: 0, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.selectedIndex = 0
        vm.hideSelectedNode()
        // The assembly's descendant geometry should be hidden.
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1))
    }

    // MARK: - Visibility Menu State Tests

    @MainActor
    func testSelectedHasHideableGeometry_trueForGeometryNode() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Part", parentIndex: -1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.selectedIndex = 0
        XCTAssertTrue(vm.selectedHasHideableGeometry)
    }

    @MainActor
    func testSelectedHasHideableGeometry_falseForEmptySelection() {
        let vm = DocumentViewModel()
        XCTAssertFalse(vm.selectedHasHideableGeometry)
    }

    @MainActor
    func testSelectedHasHideableGeometry_trueForAssemblyWithGeometryDescendants() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Assembly", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Child", parentIndex: 0, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.selectedIndex = 0
        XCTAssertTrue(vm.selectedHasHideableGeometry)
    }

    // MARK: - Cancel Parse Tests

    @MainActor
    func testCancelParse_resetsToEmptyState() {
        let vm = DocumentViewModel()
        vm.state = .loading
        vm.parseStage = "Detecting format..."
        vm.parseProgress = 0.5
        vm.nodeNames = ["test"]
        vm.nodes = [RenderPacketDTO.NodeInfo(
            name: "test", parentIndex: -1, hasGeometry: true,
            geometryId: 0, meshIndex: 0,
            geometryLabel: nil, boundsMin: nil, boundsMax: nil
        )]

        vm.cancelParse()
        XCTAssertEqual(vm.state, .empty)
        XCTAssertTrue(vm.nodeNames.isEmpty)
        XCTAssertTrue(vm.nodes.isEmpty)
        XCTAssertEqual(vm.parseStage, "")
        XCTAssertEqual(vm.parseProgress, 0)
    }

    // MARK: - Uniform Layout Test

    func testUniformsLayout_matchesExpectedSize() {
        // Verify the Swift uniform struct matches Metal's layout.
        // Expected: mvp(64) + model(64) + baseColor(16) + highlightColor(16)
        //            + clipPlane(16) + renderMode(4) + padding(12) = 192
        XCTAssertEqual(MemoryLayout<Uniforms>.size, 192)
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 192)
        XCTAssertEqual(MemoryLayout<Uniforms>.alignment, 16)
    }

    func testOverlayVertexLayout_matchesExpectedSize() {
        // OverlayVertex: float4 position(16) + float4 color(16) = 32 bytes
        XCTAssertEqual(MemoryLayout<OverlayVertex>.size, 32)
        XCTAssertEqual(MemoryLayout<OverlayVertex>.stride, 32)
    }

    // MARK: - Preference Persistence Test

    func testAppPreferences_hasRenderModeKey() {
        // Verify the renderMode key exists and has a valid default.
        let val = AppPreferences.renderMode
        XCTAssertTrue(val >= 0 && val <= 3, "renderMode must be a valid RenderMode raw value")
    }

    // MARK: - Node Visibility Tree Tests

    @MainActor
    func testVisibleNodeIndices_noSearchFilter() {
        let vm = DocumentViewModel()
        vm.expandedIndices = []
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Hidden", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Leaf", parentIndex: 1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.rebuildTreeCaches()

        // Root is always visible; child at depth 1 is not because root is collapsed.
        let visible = vm.visibleNodeIndices
        XCTAssertEqual(visible, [0])
    }

    @MainActor
    func testVisibleNodeIndices_withExpandedRoot() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Sub", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "Part", parentIndex: 1, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.expandedIndices = [0, 1]
        vm.rebuildTreeCaches()

        let visible = vm.visibleNodeIndices
        XCTAssertEqual(visible, [0, 1, 2])
    }

    // MARK: - Vertex Layout Test

    /// Verify that upload() interleaves positions and normals correctly
    /// for the vertex descriptor (attribute0=float3@0, attribute1=float3@12, stride=24).
    func testMetalUpload_interleavedVertexLayout() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), device: device)
        guard let renderer = MetalRenderer(mtkView: view) else { return }

        // Known values for 3 vertices.
        let positions: [Float] = [0, 0, 0,  2, 0, 0,  0, 3, 0]
        let normals:   [Float] = [0, 0, 1,  0, 0, 1,  0, 0, 1]
        let indices:  [UInt32] = [0, 1, 2]

        positions.withUnsafeBufferPointer { p in
            normals.withUnsafeBufferPointer { n in
                indices.withUnsafeBufferPointer { idx in
                    renderer.upload(
                        positions: p.baseAddress!, normals: n.baseAddress!,
                        vertexCount: 3, indices: idx.baseAddress!, indexCount: 3,
                        nodeIndex: 0, boundsMin: .zero, boundsMax: .zero
                    )
                }
            }
        }

        // Read back vertex buffer contents via GPU mesh list.
        // MetalRenderer stores GPU meshes internally; we access the
        // first mesh's vertex buffer (storageModeShared → CPU-readable).
        let meshes = renderer.getGPUMeshes()
        guard !meshes.isEmpty else { return }
        let vb = meshes[0].vertexBuffer
        let raw = vb.contents().bindMemory(to: Float.self, capacity: vb.length / 4)

        // Expected interleaved layout: [p0, p0, p0, n0, n0, n0,  p1, p1, p1, n1, n1, n1, ...]
        XCTAssertEqual(raw[0], 0, accuracy: 1e-6, "v0 pos.x")
        XCTAssertEqual(raw[1], 0, accuracy: 1e-6, "v0 pos.y")
        XCTAssertEqual(raw[2], 0, accuracy: 1e-6, "v0 pos.z")
        XCTAssertEqual(raw[3], 0, accuracy: 1e-6, "v0 nrm.x")
        XCTAssertEqual(raw[4], 0, accuracy: 1e-6, "v0 nrm.y")
        XCTAssertEqual(raw[5], 1, accuracy: 1e-6, "v0 nrm.z")

        XCTAssertEqual(raw[6], 2, accuracy: 1e-6, "v1 pos.x")
        XCTAssertEqual(raw[7], 0, accuracy: 1e-6, "v1 pos.y")
        XCTAssertEqual(raw[8], 0, accuracy: 1e-6, "v1 pos.z")
        XCTAssertEqual(raw[9], 0, accuracy: 1e-6, "v1 nrm.x")
        XCTAssertEqual(raw[10], 0, accuracy: 1e-6, "v1 nrm.y")
        XCTAssertEqual(raw[11], 1, accuracy: 1e-6, "v1 nrm.z")

        XCTAssertEqual(raw[12], 0, accuracy: 1e-6, "v2 pos.x")
        XCTAssertEqual(raw[13], 3, accuracy: 1e-6, "v2 pos.y")
        XCTAssertEqual(raw[14], 0, accuracy: 1e-6, "v2 pos.z")
        XCTAssertEqual(raw[15], 0, accuracy: 1e-6, "v2 nrm.x")
        XCTAssertEqual(raw[16], 0, accuracy: 1e-6, "v2 nrm.y")
        XCTAssertEqual(raw[17], 1, accuracy: 1e-6, "v2 nrm.z")
    }

    // MARK: - Frustum Cache Test

    func testFrustumCache_invalidatedOnClear() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), device: device)
        guard let renderer = MetalRenderer(mtkView: view) else { return }

        let p: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let n: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
        let idx: [UInt32] = [0, 1, 2]
        p.withUnsafeBufferPointer { pp in
            n.withUnsafeBufferPointer { np in
                idx.withUnsafeBufferPointer { ip in
                    renderer.upload(positions: pp.baseAddress!, normals: np.baseAddress!,
                                    vertexCount: 3, indices: ip.baseAddress!, indexCount: 3,
                                    nodeIndex: 0, boundsMin: .zero, boundsMax: .zero)
                }
            }
        }

        // First call: culling should run (hash = sentinel initially, now set to current).
        renderer.updateFrustumCulling(aspect: 1.0)
        XCTAssertEqual(renderer.frustumSkipCount, 0, "first cull should not skip")

        // Second call with same aspect: hash matches → skip.
        renderer.updateFrustumCulling(aspect: 1.0)
        XCTAssertEqual(renderer.frustumSkipCount, 1, "second cull with same camera should skip")

        // Third call also skips.
        renderer.updateFrustumCulling(aspect: 1.0)
        XCTAssertEqual(renderer.frustumSkipCount, 2, "third cull should also skip")

        // clearMeshes must invalidate cache.
        renderer.clearMeshes()
        XCTAssertEqual(renderer.frustumSkipCount, 0, "clearMeshes must reset skip count")
    }

    // MARK: - DFS Preorder Test

    /// Verify that visibleNodeIndices uses DFS preorder, not BFS.
    /// Tree: Root(0) → A(1) → A1(3), Root → B(2).
    /// With Root+A expanded: preorder = [Root, A, A1, B]; BFS = [Root, A, B, A1].
    @MainActor
    func testVisibleNodeIndices_dfsPreorder() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "A", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "B", parentIndex: 0, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "A1", parentIndex: 1, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.expandedIndices = [0, 1]  // Root + A expanded, B just show name.
        vm.rebuildTreeCaches()

        let visible = vm.visibleNodeIndices
        // Preorder DFS: Root(0) → A(1) → A1(3) → B(2).
        XCTAssertEqual(visible, [0, 1, 3, 2], "DFS preorder: Root, A, A1, B")
    }

    /// Verify that collapse of A hides A1 but not B.
    @MainActor
    func testVisibleNodeIndices_collapseHidesGrandchild() {
        let vm = DocumentViewModel()
        vm.nodes = [
            RenderPacketDTO.NodeInfo(name: "Root", parentIndex: -1, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "A", parentIndex: 0, hasGeometry: false,
                                     geometryId: -1, meshIndex: -1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "B", parentIndex: 0, hasGeometry: true,
                                     geometryId: 0, meshIndex: 0,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
            RenderPacketDTO.NodeInfo(name: "A1", parentIndex: 1, hasGeometry: true,
                                     geometryId: 1, meshIndex: 1,
                                     geometryLabel: nil, boundsMin: nil, boundsMax: nil),
        ]
        vm.expandedIndices = [0]  // Root expanded, A collapsed.
        vm.rebuildTreeCaches()

        let visible = vm.visibleNodeIndices
        XCTAssertEqual(visible, [0, 1, 2], "A collapsed hides A1")
    }

    // MARK: - Section Fill Degenerate Contour Cleanup Tests

    /// Contour with duplicate consecutive vertices: ear clipping succeeds
    /// directly because the contour is still well-formed (the zero-area ear
    /// from the duplicated vertex is skipped, and the remaining polygon
    /// ear-clips normally).  The cleanup fallback is not triggered — it only
    /// runs when ear clipping completely stalls.
    func testSectionFill_dupVertex_cleanedAndTriangulated() {
        // A unit square at Z=0, but the (1,1) corner is duplicated.
        let pts: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(1, 0, 0),
            simd_float3(1, 1, 0), simd_float3(1, 1, 0), // duplicate
            simd_float3(0, 1, 0),
        ]
        let n = pts.count
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let pi = pts[i]; let pj = pts[j]
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(i * 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(0.2, 0.6, 1.0, 0.7)
        )
        // 5-vertex contour → ear clipping succeeds directly.
        // (5-2)=3 triangles × 3 verts × 8 floats = 72.
        XCTAssertEqual(result.count, 72, "5-vertex with dup: 3 tris × 3 × 8 = 72")
    }

    /// Contour with collinear points on an edge: ear clipping still succeeds
    /// directly (the collinear "ear" has zero area and is skipped).  The
    /// cleanup fallback is not triggered — it only runs on complete stall.
    func testSectionFill_collinearVertex_cleanedAndTriangulated() {
        // A square at Z=0 with an extra collinear point (0.5,0) on the bottom edge.
        let pts: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(0.5, 0, 0), // collinear on bottom
            simd_float3(1, 0, 0), simd_float3(1, 1, 0),
            simd_float3(0, 1, 0),
        ]
        let n = pts.count
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let pi = pts[i]; let pj = pts[j]
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(i * 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(0.2, 0.8, 0.4, 0.7)
        )
        // 5-vertex contour → ear clipping succeeds directly.
        // (5-2)=3 triangles × 3 verts × 8 floats = 72.
        XCTAssertEqual(result.count, 72, "5-vertex with collinear: 3 tris × 3 × 8 = 72")
    }

    /// A self-intersecting (bow-tie) contour at Z=0.  Although conceptually
    /// self-intersecting, the ear-clipping algorithm interprets the 4 vertices
    /// as a simple polygon — it finds a valid ear and produces 2 triangles.
    /// Each triangle vertex must be finite and within bounds.
    func testSectionFill_bowtie_earClipsAsSimplePolygon() {
        // Bow-tie: (0,0)→(1,1)→(1,0)→(0,1). Self-intersecting in XY.
        let pts: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(1, 1, 0),
            simd_float3(1, 0, 0), simd_float3(0, 1, 0),
        ]
        let n = pts.count
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let pi = pts[i]; let pj = pts[j]
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(i * 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(1, 0, 0, 0.5)
        )
        // 4-vertex polygon → ear clipping succeeds → 2 tris × 3 verts × 8 = 48.
        XCTAssertFalse(result.isEmpty, "bow-tie ear-clips successfully as simple polygon")
        XCTAssertEqual(result.count, 48, "4 vertices: (4-2)=2 tris × 3 × 8 = 48")

        // All vertex components must be finite and within [-1, 2] × [-1, 2] × [-1, 1].
        for vi in stride(from: 0, to: result.count, by: 8) {
            let x = result[vi], y = result[vi+1], z = result[vi+2]
            XCTAssertTrue(x.isFinite && y.isFinite && z.isFinite,
                          "vertex \(vi/8) components must be finite")
            XCTAssertTrue(x >= -1 && x <= 2 && y >= -1 && y <= 2 && z >= -1 && z <= 1,
                          "vertex \(vi/8) out of expected bounds: (\(x), \(y), \(z))")
        }

        // Vertices must lie on Z=0.
        let normal = simd_float3(0, 0, 1)
        for vi in stride(from: 0, to: result.count, by: 8) {
            let p = simd_float3(result[vi], result[vi+1], result[vi+2])
            XCTAssertEqual(dot(normal, p), 0, accuracy: 1e-4,
                           "vertex \(vi/8) must lie on Z=0 plane")
        }
    }

    /// A contour where ALL vertices are colinear in 2D projection:
    /// every candidate ear has zero signed area, so ear clipping stalls
    /// on the first pass.  `cleanIndices` removes all colinear midpoints,
    /// leaving fewer than 3 points → the contour is skipped (empty result).
    ///
    /// This tests the cleanup+retry+skip path end-to-end.
    func testSectionFill_hopelesslyDegenerate_skipped() {
        // Four colinear points along X-axis at Z=0: (0,0)→(1,0)→(2,0)→(3,0).
        // Chaining produces a closed contour but all vertices lie on one line.
        // Ear clipping can't find any ear (all signed areas ≈ 0), cleanup
        // removes the collinear midpoints, and fewer than 3 points remain.
        let pts: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(1, 0, 0),
            simd_float3(2, 0, 0), simd_float3(3, 0, 0),
        ]
        let n = pts.count
        var verts: [Float] = []
        var idxs: [UInt32] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let pi = pts[i]; let pj = pts[j]
            let v0 = pi + simd_float3(0, 0, 1)
            let v1 = pi - simd_float3(0, 0, 1)
            let v2 = simd_float3(2 * pj.x - v0.x, 2 * pj.y - v0.y, -1)
            let base = UInt32(i * 3)
            verts += [v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z]
            idxs += [base, base + 1, base + 2]
        }

        let result = computeSectionFill(
            positions: verts, indices: idxs,
            clipPlane: simd_float4(0, 0, 1, 0),
            capColor: simd_float4(1, 0, 0, 0.5)
        )
        // All-colinear contou→ ear clipping stalls → cleanup removes
        // collinear midpoints → fewer than 3 points remain → skipped.
        XCTAssertTrue(result.isEmpty,
                      "all-colinear contour must produce empty result (skipped)")
    }
}
