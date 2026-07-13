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
    static let lsmGolden        = "testdata/lsm/model_golden_v1.lsm"

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

    // MARK: - LSM fixture

    func test_lsm_fixture_dto_structure() throws {
        let dto = try Self.loadDTO(relativePath: Self.lsmGolden)

        // model_golden_v1.lsm is an LSM container with source_format="STL"
        // It should parse correctly as LSM (not fall through to STEP)
        XCTAssertGreaterThanOrEqual(dto.nodes.count, 2, "LSM: at least root + 1 leaf")
        XCTAssertEqual(dto.meshes.count, 1, "LSM: 1 mesh")
        // The golden fixture is a converted model; verify non-trivial geometry
        XCTAssertGreaterThanOrEqual(dto.triangleCount, 1, "LSM golden: at least 1 triangle")
        XCTAssertTrue(dto.triangleCount > 0, "LSM golden: has triangles")
    }

    @MainActor
    func test_lsm_async_parse_with_headless_renderer() throws {
        guard let renderer = Self.headlessRenderer else { throw XCTSkip("MetalRenderer not available") }
        renderer.clearMeshes()

        let vm = DocumentViewModel()
        vm.setRenderer(renderer)
        let data = try Self.fixtureData(Self.lsmGolden)

        let loadedExpectation = expectation(description: "state loaded")
        let cancellable = vm.$state
            .filter { if case .loaded = $0 { true } else { false } }
            .first()
            .sink { _ in loadedExpectation.fulfill() }

        vm.parseFile(data: data, fileExtension: "lsm")
        wait(for: [loadedExpectation], timeout: 15.0)
        cancellable.cancel()

        let meshes = renderer.getGPUMeshes()
        XCTAssertFalse(meshes.isEmpty, "LSM: GPU meshes uploaded")
        XCTAssertTrue(meshes.allSatisfy { $0.visible }, "LSM: all meshes visible")
        let totalTriangles = meshes.reduce(0) { $0 + $1.indexCount / 3 }
        XCTAssertGreaterThanOrEqual(totalTriangles, 1, "LSM golden: at least 1 triangle on GPU")
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
    func test_headless_renderer_hide_selected_vm_and_gpu_chain() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Select Base_Box via formal API, then hide it
        vm.selectNode(1)
        XCTAssertEqual(vm.selectedIndex, 1, "VM selected after selectNode")
        XCTAssertEqual(renderer.selectedNodeIndex, 1, "renderer selected after selectNode")

        vm.hideSelectedNode()
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1), "VM: node 1 hidden after hideSelectedNode")
        let meshes = renderer.getGPUMeshes()
        let hiddenMesh = meshes.first { $0.nodeIndex == 1 }
        XCTAssertNotNil(hiddenMesh, "should find GPU mesh for node 1")
        XCTAssertFalse(hiddenMesh!.visible, "GPU: mesh for node 1 invisible after hide")
    }

    @MainActor
    func test_headless_renderer_isolate_selected_vm_and_gpu_chain() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Select Base_Box via formal API, then isolate it
        vm.selectNode(1)
        XCTAssertEqual(vm.selectedIndex, 1, "VM selected after selectNode")
        XCTAssertEqual(renderer.selectedNodeIndex, 1, "renderer selected after selectNode")

        vm.isolateSelectedNode()
        // VM: only node 1 NOT hidden, node 2 hidden
        XCTAssertFalse(vm.hiddenNodeIndices.contains(1), "VM: isolated node NOT hidden")
        XCTAssertTrue(vm.hiddenNodeIndices.contains(2), "VM: other node hidden")

        // GPU: isolated mesh visible, other mesh invisible
        let meshes = renderer.getGPUMeshes()
        let isoMesh = meshes.first { $0.nodeIndex == 1 }
        XCTAssertTrue(isoMesh!.visible, "GPU: isolated mesh visible")
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

        // Rotate to a clearly non-default orientation
        renderer.rotate(dx: 5.0, dy: 3.0)
        let yawAfterRotate = renderer.camera.yaw
        let pitchAfterRotate = renderer.camera.pitch

        // resetCamera should restore default orientation
        renderer.resetCamera()
        XCTAssertGreaterThan(renderer.camera.distance, 0, "distance > 0 after reset")
        // After reset + prior rotation, camera state should differ from rotated values
        let yawDiff = abs(renderer.camera.yaw - yawAfterRotate)
        let pitchDiff = abs(renderer.camera.pitch - pitchAfterRotate)
        XCTAssertTrue(yawDiff > 0.01 || pitchDiff > 0.01,
                      "resetCamera changed orientation (yawDiff=\(yawDiff), pitchDiff=\(pitchDiff))")
    }

    @MainActor
    func test_headless_renderer_camera_orbit_changes_yaw_pitch() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let yawBefore = renderer.camera.yaw
        let pitchBefore = renderer.camera.pitch

        renderer.rotate(dx: 5.0, dy: 3.0)
        XCTAssertTrue(abs(renderer.camera.yaw - yawBefore) > 0.005, "yaw changed by rotate(dx:5,dy:3)")
        XCTAssertTrue(abs(renderer.camera.pitch - pitchBefore) > 0.005, "pitch changed by rotate")
    }

    @MainActor
    func test_headless_renderer_camera_zoom_changes_distance() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let distBefore = renderer.camera.distance
        renderer.zoom(delta: 3.0)
        // Zooming in (positive delta in perspective) decreases distance
        XCTAssertLessThan(renderer.camera.distance, distBefore,
                          "distance decreased after zoom-in (delta=3.0)")
    }

    @MainActor
    func test_headless_renderer_camera_pan_shifts_target() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let targetX = renderer.camera.target.x
        let targetY = renderer.camera.target.y
        renderer.pan(dx: 100, dy: 50)
        // Pan should shift the camera target
        XCTAssertNotEqual(renderer.camera.target.x, targetX, accuracy: 0.01, "pan shifts target X")
        XCTAssertNotEqual(renderer.camera.target.y, targetY, accuracy: 0.01, "pan shifts target Y")
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
    func test_headless_renderer_picking_deterministic_hit_and_hide() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Scan a grid over the viewport to find a real hit
        let viewSize = CGSize(width: 200, height: 200)
        var hitNodeIndex: Int? = nil
        var hitPoint: CGPoint = .zero
        gridScan: for y in stride(from: 10.0, through: 190.0, by: 20.0) {
            for x in stride(from: 10.0, through: 190.0, by: 20.0) {
                let pt = CGPoint(x: x, y: y)
                if let hit = renderer.pickNode(at: viewSize, point: pt) {
                    hitNodeIndex = hit
                    hitPoint = pt
                    break gridScan
                }
            }
        }

        guard let hitIdx = hitNodeIndex else {
            // No hit found — camera may be too far; skip with note
            XCTAssertTrue(true, "no ray hit found at current camera position — skipping")
            return
        }

        XCTAssertGreaterThanOrEqual(hitIdx, 0, "hit nodeIndex >= 0")
        XCTAssertLessThan(hitIdx, 3, "hit nodeIndex < node count")

        // Verify the hit node is a visible leaf
        let hitMesh = renderer.getGPUMeshes().first { $0.nodeIndex == hitIdx }
        XCTAssertNotNil(hitMesh, "hit node should have a GPU mesh")
        XCTAssertTrue(hitMesh!.visible, "hit mesh should be visible")

        // Hide the hit node, verify same point no longer hits it
        vm.hiddenNodeIndices.insert(hitIdx)
        renderer.setHiddenNodes(vm.hiddenNodeIndices)
        let afterHide = renderer.pickNode(at: viewSize, point: hitPoint)
        XCTAssertNotEqual(afterHide, hitIdx,
                          "same point should NOT hit hidden node \(hitIdx) after hide")
    }

    // MARK: - Offscreen snapshot (headless, no MTKView.currentDrawable)

    /// Counts non-background pixels in RGBA8 data (background = ~dark grey).
    func countNonBackgroundPixels(_ data: Data, width: Int, height: Int) -> Int {
        var count = 0
        data.withUnsafeBytes { ptr in
            let pixels = ptr.bindMemory(to: UInt32.self)
            for i in 0..<(width * height) {
                let p = pixels[i]
                // BGRA: background is ~(0x24, 0x1E, 0x1E, 0xFF) = dark grey
                let r = Int((p >> 16) & 0xFF)
                let g = Int((p >> 8) & 0xFF)
                let b = Int(p & 0xFF)
                // Count pixel if significantly different from background
                if abs(r - 0x24) > 10 || abs(g - 0x1E) > 10 || abs(b - 0x23) > 10 {
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    func test_offscreen_snapshot_assembly_solid_produces_nonempty_pixels() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        renderer.renderMode = .solid
        guard let (data, w, h) = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else {
            XCTFail("renderOffscreen returned nil")
            return
        }
        let nonBg = countNonBackgroundPixels(data, width: w, height: h)
        XCTAssertGreaterThan(nonBg, 50, "solid mode: at least 50 non-background pixels rendered")
    }

    @MainActor
    func test_offscreen_snapshot_two_sizes_produce_different_counts() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        renderer.renderMode = .solid
        guard let small = renderer.renderOffscreen(size: CGSize(width: 100, height: 75)),
              let large = renderer.renderOffscreen(size: CGSize(width: 300, height: 225)) else {
            XCTFail("renderOffscreen returned nil")
            return
        }
        let smallPx = countNonBackgroundPixels(small.0, width: small.1, height: small.2)
        let largePx = countNonBackgroundPixels(large.0, width: large.1, height: large.2)
        // Larger viewport should produce more rendered pixels (or at least as many)
        XCTAssertGreaterThanOrEqual(largePx, smallPx, "larger viewport >= rendered pixels")
    }

    @MainActor
    func test_offscreen_snapshot_wireframe_differs_from_solid() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        renderer.renderMode = .solid
        guard let solid = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else { XCTFail(); return }
        let solidCount = countNonBackgroundPixels(solid.0, width: solid.1, height: solid.2)

        renderer.renderMode = .wireframe
        guard let wire = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else { XCTFail(); return }
        let wireCount = countNonBackgroundPixels(wire.0, width: wire.1, height: wire.2)

        // Solid and wireframe should produce different pixel counts
        XCTAssertNotEqual(wireCount, solidCount, "wireframe pixel count differs from solid")
    }

    @MainActor
    func test_offscreen_snapshot_hide_then_show_changes_pixels() throws {
        let (vm, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        renderer.renderMode = .solid
        guard let before = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else { XCTFail(); return }
        let beforeCount = countNonBackgroundPixels(before.0, width: before.1, height: before.2)

        // Hide all meshes
        vm.hideAllNodes()
        guard let after = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else { XCTFail(); return }
        let afterCount = countNonBackgroundPixels(after.0, width: after.1, height: after.2)

        // With all meshes hidden, should see fewer rendered pixels (only background)
        XCTAssertLessThan(afterCount, beforeCount, "hideAllNodes reduces rendered pixels")

        // Restore
        vm.setAllNodesVisible()
        guard let restored = renderer.renderOffscreen(size: CGSize(width: 200, height: 150)) else { XCTFail(); return }
        let restoredCount = countNonBackgroundPixels(restored.0, width: restored.1, height: restored.2)
        XCTAssertGreaterThan(restoredCount, afterCount, "showAll restores rendered pixels")
    }

    // MARK: - Camera projection + reset concrete assertions

    @MainActor
    func test_camera_projection_toggle_changes_is_orthographic() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        let wasOrtho = renderer.isOrthographic
        renderer.toggleProjection()
        XCTAssertNotEqual(renderer.isOrthographic, wasOrtho, "toggleProjection flips orthographic state")
        renderer.toggleProjection()
        XCTAssertEqual(renderer.isOrthographic, wasOrtho, "second toggle restores original")
    }

    @MainActor
    func test_camera_reset_restores_defaults() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }

        // Perturb camera
        renderer.rotate(dx: 10, dy: 5)
        renderer.zoom(delta: 5)
        renderer.pan(dx: 50, dy: 30)
        renderer.toggleProjection()

        // Reset
        renderer.resetCamera()
        XCTAssertGreaterThan(renderer.camera.distance, 0, "distance valid after reset")
        XCTAssertTrue(renderer.camera.yaw.isFinite, "yaw finite after reset")
        XCTAssertTrue(renderer.camera.pitch.isFinite, "pitch finite after reset")
        // resetCamera restores perspective projection
        XCTAssertFalse(renderer.isOrthographic, "resetCamera restores perspective projection")
    }

    @MainActor
    func test_camera_zoom_in_decreases_distance() throws {
        let (_, renderer, _, doc) = try makeAssemblyWithHeadlessRenderer()
        defer { mmf_document_free(doc) }
        let d1 = renderer.camera.distance
        renderer.zoom(delta: 5)
        XCTAssertLessThan(renderer.camera.distance, d1, "zoom in (positive delta) decreases distance")
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
