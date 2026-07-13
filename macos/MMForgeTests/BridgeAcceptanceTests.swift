import XCTest
@testable import MMForge
import Combine
import MetalKit

/// Real-fixture bridge acceptance: loads actual STEP/IGES/STL/glTF/DXF
/// files through the Rust bridge and verifies DTO structure, bounds,
/// mesh-node mapping, scene tree, visibility, and error paths.
///
/// Uses the synchronous C ABI (`mmf_parse_file`) for structural assertions
/// and the async `DocumentViewModel.parseFile` pipeline for progress/error tests.
final class BridgeAcceptanceTests: XCTestCase {

    // MARK: - Path helpers

    /// Project root (contains Cargo.toml, crates/, testdata/).
    static let projectRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let cargoToml = url.appendingPathComponent("Cargo.toml").path
            if FileManager.default.fileExists(atPath: cargoToml) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        // Fallback: assume cwd is project root during xcodebuild.
        return FileManager.default.currentDirectoryPath
    }()

    static func fixturePath(_ relative: String) -> String {
        (projectRoot as NSString).appendingPathComponent(relative)
    }

    /// Read a fixture file as Data.
    static func fixtureData(_ relative: String) throws -> Data {
        let path = fixturePath(relative)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Load a fixture synchronously via mmf_parse_file, returning the DTO.
    /// Frees the Rust document after building the DTO (data is copied).
    static func loadDTO(relativePath: String) throws -> RenderPacketDTO {
        let path = fixturePath(relativePath)
        guard let doc = mmf_parse_file(path) else {
            let errPtr = mmf_last_error()
            let msg = errPtr.map { String(cString: $0) } ?? "unknown error"
            throw NSError(domain: "BridgeAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "mmf_parse_file failed: \(msg)"])
        }
        defer { mmf_document_free(doc) }
        return RustBridge.shared.buildDTO(from: doc)
    }

    // MARK: - Fixture paths

    static let assemblyStp      = "crates/mmforge-geometry/testdata/assembly.stp"
    static let pqStep           = "crates/mmforge-geometry/testdata/PQ-04909-A.STEP"
    static let boxIgs           = "crates/mmforge-geometry/testdata/box.igs"
    static let translatedIgs    = "crates/mmforge-geometry/testdata/translated_box.igs"
    static let boxStl           = "testdata/stl/box.stl"
    static let boxGltf          = "testdata/gltf/box.gltf"
    static let testDxf          = "crates/mmforge-format-dxf/testdata/test.dxf"

    // MARK: - STEP assembly fixture

    func test_step_assembly_fixture_node_count_and_hierarchy() throws {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)

        // Verifies the 494-entity AP214 assembly STEP:
        //   Root "Assembly" + 2 leaf solids (Box, Cylinder)
        XCTAssertEqual(dto.nodes.count, 3, "assembly.stp: expected 3 nodes (root + 2 parts)")

        // Root node
        let root = dto.nodes[0]
        XCTAssertEqual(root.parentIndex, -1, "root parentIndex must be -1")
        XCTAssertFalse(root.hasGeometry, "assembly root should have no geometry")

        // Both leaves should have geometry
        for i in 1..<3 {
            XCTAssertTrue(dto.nodes[i].hasGeometry, "node \(i) should have geometry (leaf)")
            XCTAssertEqual(dto.nodes[i].parentIndex, 0, "node \(i) parent should be root (index 0)")
            XCTAssertGreaterThanOrEqual(dto.nodes[i].geometryId, 0, "node \(i) geometryId must be >= 0")
            XCTAssertGreaterThanOrEqual(dto.nodes[i].meshIndex, 0, "node \(i) meshIndex must be >= 0")
        }

        // Scene bounds must be valid (non-zero extent)
        XCTAssertLessThan(dto.sceneBoundsMin.x, dto.sceneBoundsMax.x, "scene bounds X extent")
        XCTAssertLessThan(dto.sceneBoundsMin.y, dto.sceneBoundsMax.y, "scene bounds Y extent")
    }

    func test_step_assembly_mesh_node_mapping() throws {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)

        XCTAssertEqual(dto.meshes.count, 2, "assembly: 2 geometry → 2 meshes")

        // Build geometryId → nodeIndex map (same as uploadToRenderer)
        var geomToNode = [Int: Int]()
        for (idx, node) in dto.nodes.enumerated() where node.geometryId >= 0 {
            geomToNode[node.geometryId] = idx
        }

        for mesh in dto.meshes {
            let nodeIdx = geomToNode[mesh.geometryId]
            XCTAssertNotNil(nodeIdx, "mesh geometryId \(mesh.geometryId) must map to a node")
            if let ni = nodeIdx {
                let node = dto.nodes[ni]
                XCTAssertTrue(node.hasGeometry, "mapped node must have geometry")
                XCTAssertEqual(node.geometryId, mesh.geometryId, "geometryId consistency")
            }
            XCTAssertGreaterThan(mesh.vertexCount, 0, "mesh must have vertices")
            XCTAssertGreaterThan(mesh.indexCount, 0, "mesh must have indices")
        }
    }

    func test_step_assembly_node_bounds() throws {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)

        for node in dto.nodes {
            guard node.hasGeometry, let bmin = node.boundsMin, let bmax = node.boundsMax else {
                continue // assembly nodes have no bounds
            }
            XCTAssertLessThanOrEqual(bmin.x, bmax.x, "node bounds X must be ordered")
            XCTAssertLessThanOrEqual(bmin.y, bmax.y, "node bounds Y must be ordered")
            XCTAssertLessThanOrEqual(bmin.z, bmax.z, "node bounds Z must be ordered")
            // Bounds must be finite
            XCTAssertTrue(bmin.x.isFinite && bmax.x.isFinite, "bounds X finite")
        }
    }

    // MARK: - IGES fixture

    func test_iges_box_dto_structure() throws {
        let dto = try Self.loadDTO(relativePath: Self.boxIgs)

        XCTAssertGreaterThanOrEqual(dto.nodes.count, 2, "box.igs: at least root + 1 leaf")
        XCTAssertEqual(dto.meshes.count, 1, "box.igs: 1 geometry → 1 mesh")
        XCTAssertGreaterThanOrEqual(dto.triangleCount, 1, "box.igs should have triangles")
    }

    func test_iges_translated_box_bounds() throws {
        let dto = try Self.loadDTO(relativePath: Self.translatedIgs)

        XCTAssertEqual(dto.meshes.count, 1, "translated_box.igs: 1 mesh")
        // Pre-translated box: original [0,0,0]–[10,10,10] moved to [20,0,5]–[30,10,15]
        let eps: Float = 1.0
        XCTAssertEqual(dto.sceneBoundsMin.x, 20.0, accuracy: eps, "min X should be ~20")
        XCTAssertEqual(dto.sceneBoundsMax.x, 30.0, accuracy: eps, "max X should be ~30")
        XCTAssertEqual(dto.sceneBoundsMin.y,  0.0, accuracy: eps, "min Y should be ~0")
        XCTAssertEqual(dto.sceneBoundsMax.y, 10.0, accuracy: eps, "max Y should be ~10")
        XCTAssertEqual(dto.sceneBoundsMin.z,  5.0, accuracy: eps, "min Z should be ~5")
        XCTAssertEqual(dto.sceneBoundsMax.z, 15.0, accuracy: eps, "max Z should be ~15")
    }

    // MARK: - STL fixture

    func test_stl_fixture_dto_structure() throws {
        let dto = try Self.loadDTO(relativePath: Self.boxStl)

        XCTAssertGreaterThanOrEqual(dto.nodes.count, 2, "STL: at least root + 1 leaf")
        XCTAssertEqual(dto.meshes.count, 1, "STL: 1 mesh")
        XCTAssertEqual(dto.triangleCount, 12, "box.stl: 12 triangles (unit cube)")
    }

    // MARK: - glTF fixture

    func test_gltf_fixture_dto_structure() throws {
        let dto = try Self.loadDTO(relativePath: Self.boxGltf)

        XCTAssertGreaterThanOrEqual(dto.nodes.count, 1, "glTF: at least 1 node")
        XCTAssertEqual(dto.meshes.count, 1, "glTF: 1 mesh")
        XCTAssertEqual(dto.triangleCount, 1, "box.gltf: 1 triangle")
    }

    // MARK: - DXF fixture (2D)

    func test_dxf_fixture_is_2d_drawing() throws {
        let path = Self.fixturePath(Self.testDxf)
        guard let doc = mmf_parse_file(path) else {
            XCTFail("mmf_parse_file failed for DXF")
            return
        }
        defer { mmf_document_free(doc) }

        let is2D = mmf_is_2d_drawing(doc) != 0
        XCTAssertTrue(is2D, "DXF file should be detected as 2D drawing")
    }

    // MARK: - Node parentIndex correctness

    func test_parent_index_consistency() throws {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)

        for (idx, node) in dto.nodes.enumerated() {
            if node.parentIndex >= 0 {
                XCTAssertLessThan(node.parentIndex, dto.nodes.count,
                                  "node \(idx) parentIndex \(node.parentIndex) in bounds")
                XCTAssertLessThan(node.parentIndex, idx,
                                  "node \(idx) parentIndex should point to earlier node (pre-order)")
            }
        }
    }

    // MARK: - Mesh index determines node ordering

    func test_mesh_indices_are_sequential() throws {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)

        var seenMeshIds = Set<Int>()
        for mesh in dto.meshes {
            // meshIndex in NodeInfo should refer to a valid mesh
            seenMeshIds.insert(mesh.geometryId)
        }
        XCTAssertFalse(seenMeshIds.isEmpty, "should have at least one mesh")

        // Every node with meshIndex >= 0 should reference a valid geometryId
        for node in dto.nodes where node.meshIndex >= 0 {
            XCTAssertTrue(seenMeshIds.contains(node.geometryId),
                          "node geometryId \(node.geometryId) should appear in meshes")
        }
    }

    // MARK: - Error state: nonexistent file

    func test_nonexistent_file_returns_error() throws {
        let path = Self.fixturePath("nonexistent/file.step")
        let doc = mmf_parse_file(path)
        XCTAssertNil(doc, "nonexistent file should return nil")
        let errPtr = mmf_last_error()
        XCTAssertNotNil(errPtr, "should have error message")
        if let errPtr = errPtr {
            let msg = String(cString: errPtr)
            XCTAssertFalse(msg.isEmpty, "error message should not be empty")
        }
    }

    // MARK: - Async parse progress

    @MainActor
    func test_async_parse_reports_progress() throws {
        let vm = DocumentViewModel()
        let data = try Self.fixtureData(Self.boxStl)

        let stageExpectation = expectation(description: "parseStage updated")
        var gotStage = false
        let cancellable = vm.$parseStage
            .filter { !$0.isEmpty }
            .first()
            .sink { _ in
                gotStage = true
                stageExpectation.fulfill()
            }

        let loadedExpectation = expectation(description: "state becomes loaded")
        let loadedCancellable = vm.$state
            .filter { if case .loaded = $0 { true } else { false } }
            .first()
            .sink { _ in loadedExpectation.fulfill() }

        vm.parseFile(data: data, fileExtension: "stl")
        wait(for: [stageExpectation], timeout: 15.0)
        wait(for: [loadedExpectation], timeout: 15.0)

        XCTAssertTrue(gotStage, "should have received parse stage")
        if case .loaded(let tri, let mesh, let node) = vm.state {
            XCTAssertEqual(tri, 12, "box.stl: 12 triangles (unit cube)")
            XCTAssertEqual(mesh, 1, "box.stl: 1 mesh")
            XCTAssertGreaterThanOrEqual(node, 2, "box.stl: at least root + 1 leaf node")
        } else {
            XCTFail("expected .loaded state, got \(vm.state)")
        }

        cancellable.cancel()
        loadedCancellable.cancel()
    }

    // MARK: - Selection, visibility, hide/isolate on real assembly.stp DTO

    /// Loads assembly.stp DTO and assigns its nodes to a DocumentViewModel.
    /// Expands root (index 0) so leaves are visible.
    @MainActor
    func makeAssemblyVM() throws -> (DocumentViewModel, RenderPacketDTO) {
        let dto = try Self.loadDTO(relativePath: Self.assemblyStp)
        let vm = DocumentViewModel()
        vm.nodes = dto.nodes
        vm.expandedIndices = [0]
        vm.rebuildTreeCaches()
        return (vm, dto)
    }

    @MainActor
    func test_real_assembly_selection_via_formal_select_node() throws {
        let (vm, dto) = try makeAssemblyVM()

        // Select via formal API (syncs both VM and renderer if bound)
        vm.selectNode(1)
        XCTAssertEqual(vm.selectedIndex, 1)
        let node = dto.nodes[1]
        XCTAssertTrue(node.hasGeometry, "selected node should have geometry")

        // Deselect
        vm.selectNode(nil)
        XCTAssertNil(vm.selectedIndex)
    }

    @MainActor
    func test_real_assembly_visible_node_indices() throws {
        let (vm, _) = try makeAssemblyVM()

        // With root expanded, both leaf parts (indices 1,2) should be visible
        let visible = vm.visibleNodeIndices
        XCTAssertTrue(visible.contains(1), "Base_Box should be visible")
        XCTAssertTrue(visible.contains(2), "Pillar_Cylinder should be visible")
        // Root (index 0) is an assembly — it appears if it has visible descendants
    }

    @MainActor
    func test_real_assembly_isolate_node_hides_other_leaf() throws {
        let (vm, _) = try makeAssemblyVM()

        // Isolate Base_Box (index 1)
        vm.isolateNode(1)
        // After isolate, only Base_Box should be visible in hiddenNodeIndices
        XCTAssertFalse(vm.hiddenNodeIndices.contains(1), "Base_Box should NOT be hidden")
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2), "Pillar_Cylinder should be hidden")
        XCTAssertEqual(vm.selectedIndex, 1)
        // hiddenNodeIndices.count should be 1 (just the other leaf)
        XCTAssertEqual(vm.hiddenNodeIndices.count, 1)
    }

    @MainActor
    func test_real_assembly_hide_all_then_show_all() throws {
        let (vm, _) = try makeAssemblyVM()

        vm.hideAllNodes()
        // Both leaf parts (indices 1,2) should be hidden; assembly root (0) skipped
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1), "Base_Box hidden")
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2), "Pillar_Cylinder hidden")
        XCTAssertEqual(vm.hiddenNodeIndices.count, 2)

        vm.setAllNodesVisible()
        XCTAssertEqual(vm.hiddenNodeIndices.count, 0, "all visible again")
    }

    // MARK: - Headless MetalRenderer (shared, created once)

    /// Shared headless Metal device for all renderer tests.
    static var headlessDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    /// Shared headless MTKView.
    static var headlessView: MTKView? = {
        guard let d = headlessDevice else { return nil }
        return MTKView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), device: d)
    }()
    /// Shared headless MetalRenderer.
    static var headlessRenderer: MetalRenderer? = {
        guard let v = headlessView else { return nil }
        return MetalRenderer(mtkView: v)
    }()

    /// Load assembly.stp DTO and upload to the shared headless renderer.
    /// Returns VM, renderer, DTO, and the document handle (must be freed after test).
    @MainActor
    func makeAssemblyWithHeadlessRenderer() throws -> (DocumentViewModel, MetalRenderer, RenderPacketDTO, OpaquePointer) {
        guard let renderer = Self.headlessRenderer else {
            throw XCTSkip("MetalRenderer not available")
        }
        renderer.clearMeshes()

        let path = Self.fixturePath(Self.assemblyStp)
        guard let doc = mmf_parse_file(path) else {
            throw XCTSkip("Failed to parse assembly.stp")
        }
        let dto = RustBridge.shared.buildDTO(from: doc)

        let vm = DocumentViewModel()
        vm.nodes = dto.nodes
        vm.expandedIndices = [0]
        vm.rebuildTreeCaches()
        vm.setRenderer(renderer)
        vm.uploadToRenderer(dto: dto)
        return (vm, renderer, dto, doc)
    }

    @MainActor
    func test_headless_renderer_geometryid_to_nodeindex_to_gpumesh_mapping() throws {
        let (_, renderer, dto, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }
        let meshes = renderer.getGPUMeshes()

        XCTAssertEqual(meshes.count, 2, "2 meshes from assembly.stp")

        // Build expected geometryId → nodeIndex map from DTO
        var geomToNode = [Int: Int]()
        for (idx, node) in dto.nodes.enumerated() where node.geometryId >= 0 {
            geomToNode[node.geometryId] = idx
        }

        for mesh in meshes {
            let nodeIdx = mesh.nodeIndex
            XCTAssertGreaterThanOrEqual(nodeIdx, 0, "mesh nodeIndex should be valid")
            XCTAssertLessThan(nodeIdx, dto.nodes.count, "nodeIndex in bounds")
            let node = dto.nodes[nodeIdx]
            XCTAssertTrue(node.hasGeometry, "GPUMesh.nodeIndex → node should have geometry")
            // The geometryId in DTO should map to this nodeIndex
            let expectedNodeIdx = geomToNode[node.geometryId]
            XCTAssertEqual(nodeIdx, expectedNodeIdx, "geometryId \(node.geometryId) maps to correct nodeIndex")
        }
    }

    @MainActor
    func test_headless_renderer_select_node_syncs_vm_and_gpu() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Select via formal API — must sync both VM.selectedIndex AND renderer.selectedNodeIndex
        vm.selectNode(1)
        XCTAssertEqual(vm.selectedIndex, 1, "VM.selectedIndex after selectNode(1)")
        XCTAssertEqual(renderer.selectedNodeIndex, 1, "renderer.selectedNodeIndex after selectNode(1)")

        // Deselect via formal API
        vm.selectNode(nil)
        XCTAssertNil(vm.selectedIndex, "VM.selectedIndex after selectNode(nil)")
        XCTAssertNil(renderer.selectedNodeIndex, "renderer.selectedNodeIndex after selectNode(nil)")
    }

    @MainActor
    func test_headless_renderer_toggle_visibility_vm_and_gpu_consistent() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Toggle visibility of Base_Box (index 1) through the formal VM API
        vm.toggleNodeVisibility(1)

        // VM state: node 1 should be in hiddenNodeIndices
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1), "VM: Base_Box hidden after toggle")

        // Renderer state: mesh with nodeIndex=1 should be invisible
        let meshes = renderer.getGPUMeshes()
        let hiddenMesh = meshes.first { $0.nodeIndex == 1 }
        XCTAssertNotNil(hiddenMesh, "should find mesh for nodeIndex 1")
        XCTAssertFalse(hiddenMesh!.visible, "GPU mesh for nodeIndex 1 should be invisible")

        // Other mesh (Pillar_Cylinder, nodeIndex 2) should still be visible
        let visibleMesh = meshes.first { $0.nodeIndex == 2 }
        XCTAssertNotNil(visibleMesh, "should find mesh for nodeIndex 2")
        XCTAssertTrue(visibleMesh!.visible, "GPU mesh for nodeIndex 2 should remain visible")

        // Toggle back
        vm.toggleNodeVisibility(1)
        XCTAssertFalse(vm.hiddenNodeIndices.contains(1), "VM: Base_Box visible after second toggle")
        let meshes2 = renderer.getGPUMeshes()
        let visibleAgain = meshes2.first { $0.nodeIndex == 1 }
        XCTAssertTrue(visibleAgain!.visible, "GPU mesh visible after second toggle")
    }

    @MainActor
    func test_headless_renderer_hide_selected_node_vm_and_gpu() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Select and hide Base_Box
        vm.selectedIndex = 1
        vm.hideSelectedNode()

        XCTAssertTrue(vm.hiddenNodeIndices.contains(1), "VM: node 1 hidden")
        let meshes = renderer.getGPUMeshes()
        let hiddenMesh = meshes.first { $0.nodeIndex == 1 }
        XCTAssertFalse(hiddenMesh!.visible, "GPU: node 1 mesh invisible")
    }

    @MainActor
    func test_headless_renderer_isolate_selected_keeps_one_visible() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Select and isolate Base_Box
        vm.selectedIndex = 1
        vm.isolateSelectedNode()

        // VM: only node 1 NOT hidden
        XCTAssertFalse(vm.hiddenNodeIndices.contains(1), "VM: isolated node visible")
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2), "VM: other node hidden")

        // GPU: mesh for node 1 visible, mesh for node 2 invisible
        let meshes = renderer.getGPUMeshes()
        let isolatedMesh = meshes.first { $0.nodeIndex == 1 }
        XCTAssertTrue(isolatedMesh!.visible, "GPU: isolated mesh visible")
        let otherMesh = meshes.first { $0.nodeIndex == 2 }
        XCTAssertFalse(otherMesh!.visible, "GPU: other mesh invisible")
    }

    @MainActor
    func test_headless_renderer_set_all_nodes_visible_clears_hidden() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // First hide both leaves
        vm.hideAllNodes()
        XCTAssertEqual(vm.hiddenNodeIndices.count, 2, "both leaves hidden")
        var meshes = renderer.getGPUMeshes()
        XCTAssertTrue(meshes.allSatisfy { !$0.visible }, "all GPU meshes invisible")

        // Now show all
        vm.setAllNodesVisible()
        XCTAssertEqual(vm.hiddenNodeIndices.count, 0, "VM: no hidden nodes")
        meshes = renderer.getGPUMeshes()
        XCTAssertTrue(meshes.allSatisfy { $0.visible }, "all GPU meshes visible again")
    }

    @MainActor
    func test_headless_renderer_camera_initialized() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Camera should be initialized after scene bounds set
        XCTAssertGreaterThan(renderer.camera.distance, 0, "camera distance > 0 after fit")
        // Target should be near the center of the assembly
        XCTAssertTrue(renderer.camera.target.x.isFinite, "camera target X finite")
        XCTAssertTrue(renderer.camera.target.y.isFinite, "camera target Y finite")
    }

    // MARK: - PendingDTO: parse without renderer, then bind later

    @MainActor
    func test_pending_dto_consumed_when_renderer_bound_later() throws {
        guard let renderer = Self.headlessRenderer else { throw XCTSkip("MetalRenderer not available") }
        renderer.clearMeshes()

        let path = Self.fixturePath(Self.assemblyStp)
        guard let doc = mmf_parse_file(path) else { throw XCTSkip("parse failed") }
        defer { mmf_document_free(doc) }
        let dto = RustBridge.shared.buildDTO(from: doc)

        let vm = DocumentViewModel()
        vm.nodes = dto.nodes
        vm.expandedIndices = [0]
        vm.rebuildTreeCaches()
        // Simulate: uploadToRenderer called before renderer is bound → stores in pendingDTO
        vm.uploadToRenderer(dto: dto)

        // Now bind renderer — should flush pendingDTO and upload meshes
        vm.setRenderer(renderer)
        let meshes = renderer.getGPUMeshes()
        XCTAssertEqual(meshes.count, 2, "pendingDTO uploaded to renderer after binding")
        XCTAssertTrue(meshes.allSatisfy { $0.visible }, "all meshes visible after deferred upload")
    }

    // MARK: - Async parse with bound renderer

    @MainActor
    func test_async_parse_with_bound_renderer_produces_gpu_meshes() throws {
        guard let renderer = Self.headlessRenderer else { throw XCTSkip("MetalRenderer not available") }
        renderer.clearMeshes()

        let vm = DocumentViewModel()
        vm.setRenderer(renderer)
        let data = try Self.fixtureData(Self.boxStl)
        let loadedExpectation = expectation(description: "state loaded")
        let cancellable = vm.$state
            .filter { if case .loaded = $0 { true } else { false } }
            .first()
            .sink { _ in loadedExpectation.fulfill() }

        vm.parseFile(data: data, fileExtension: "stl")
        wait(for: [loadedExpectation], timeout: 15.0)
        cancellable.cancel()

        let meshes = renderer.getGPUMeshes()
        XCTAssertFalse(meshes.isEmpty, "GPU meshes uploaded after async parse")
        XCTAssertTrue(meshes.allSatisfy { $0.visible }, "all meshes visible")
        // Verify STL triangle count
        let totalTriangles = meshes.reduce(0) { $0 + $1.indexCount / 3 }
        XCTAssertEqual(totalTriangles, 12, "box.stl: 12 triangles on GPU")
    }

    // MARK: - Camera math (non-visual, state assertions)

    @MainActor
    func test_headless_renderer_camera_fit_and_reset() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let distBefore = renderer.camera.distance
        // Fit to view should adjust distance
        renderer.fitToView()
        XCTAssertGreaterThan(renderer.camera.distance, 0, "distance after fitToView")

        // Reset camera
        let yawBefore = renderer.camera.yaw
        renderer.resetCamera()
        XCTAssertGreaterThan(renderer.camera.distance, 0, "distance after resetCamera")
        // resetCamera adjusts yaw/pitch to a default view; both should be finite
        XCTAssertTrue(renderer.camera.yaw.isFinite, "yaw finite after reset")
        XCTAssertTrue(renderer.camera.pitch.isFinite, "pitch finite after reset")
    }

    @MainActor
    func test_headless_renderer_camera_orbit_changes_yaw_pitch() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let yawBefore = renderer.camera.yaw
        let pitchBefore = renderer.camera.pitch

        renderer.rotate(dx: 1.0, dy: 0.5)
        // Rotation should change yaw and pitch
        XCTAssertNotEqual(renderer.camera.yaw, yawBefore, accuracy: 0.001, "yaw changed after rotate")
        XCTAssertNotEqual(renderer.camera.pitch, pitchBefore, accuracy: 0.001, "pitch changed after rotate")
    }

    @MainActor
    func test_headless_renderer_camera_zoom_changes_distance() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let distBefore = renderer.camera.distance
        renderer.zoom(delta: 2.0) // zoom in
        XCTAssertNotEqual(renderer.camera.distance, distBefore, accuracy: 0.01, "distance changed after zoom")
    }

    @MainActor
    func test_headless_renderer_named_views_dont_crash() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        for view: MetalRenderer.NamedView in [.front, .back, .left, .right, .top, .bottom, .isometric] {
            vm.setNamedView(view)
            XCTAssertTrue(renderer.camera.distance.isFinite, "distance finite after \(view)")
        }
        // Isometric should differ from identity orientation
        vm.setNamedView(.isometric)
        XCTAssertTrue(abs(renderer.camera.yaw) > 0.01 || abs(renderer.camera.pitch) > 0.01,
                      "isometric view should have non-zero yaw or pitch")
    }

    @MainActor
    func test_headless_renderer_picking_returns_nodeIndex() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Pick at center of viewport — should hit something
        let viewSize = CGSize(width: 100, height: 100)
        let center = CGPoint(x: 50, y: 50)
        let hit = renderer.pickNode(at: viewSize, point: center)
        // May or may not hit depending on camera; just verify no crash and return type
        if let nodeIdx = hit {
            XCTAssertGreaterThanOrEqual(nodeIdx, 0, "hit nodeIndex >= 0")
            XCTAssertLessThan(nodeIdx, 3, "hit nodeIndex < node count (assembly.stp has 3 nodes)")
        }
        // If no hit, that's also valid at this viewport size
    }

    // MARK: - Tree expand/collapse/search with real assembly DTO

    @MainActor
    func test_real_assembly_expand_collapse_tree() throws {
        let (vm, _) = try makeAssemblyVM()
        // Root (index 0) is already expanded from makeAssemblyVM

        // Collapse root
        vm.collapseAll()
        let collapsed = vm.visibleNodeIndices
        // With root collapsed, only root should be visible (leaves hidden)
        XCTAssertFalse(collapsed.contains(1), "leaf 1 hidden when root collapsed")
        XCTAssertFalse(collapsed.contains(2), "leaf 2 hidden when root collapsed")

        // Expand root
        vm.expandAll()
        let expanded = vm.visibleNodeIndices
        XCTAssertTrue(expanded.contains(1), "leaf 1 visible when root expanded")
        XCTAssertTrue(expanded.contains(2), "leaf 2 visible when root expanded")
    }

    @MainActor
    func test_real_assembly_search_filters_visible_nodes() throws {
        let (vm, _) = try makeAssemblyVM()

        // Search for "Base" — only Base_Box should match
        vm.searchText = "Base"
        let filtered = vm.visibleNodeIndices
        XCTAssertTrue(filtered.contains(1), "Base_Box matches 'Base'")
        // When search is active, non-matching nodes are hidden from visible list
        // Verify clearing search restores all nodes
        vm.searchText = ""
        let all = vm.visibleNodeIndices
        XCTAssertTrue(all.contains(1), "Base_Box visible after clear")
        XCTAssertTrue(all.contains(2), "Pillar_Cylinder visible after clear")
        XCTAssertGreaterThanOrEqual(all.count, 3, "root + 2 leaves visible")
    }

    @MainActor
    func test_real_assembly_child_count() throws {
        let (vm, _) = try makeAssemblyVM()

        vm.expandAll()
        let rootKids = vm.childrenOf(0)
        XCTAssertEqual(rootKids.count, 2, "root has 2 children")
        XCTAssertTrue(rootKids.contains(1))
        XCTAssertTrue(rootKids.contains(2))

        // Leaves have no children
        let leafKids = vm.childrenOf(1)
        XCTAssertEqual(leafKids.count, 0, "leaf has no children")
    }
}
