import XCTest
@testable import MMForge
import Combine

/// Real-fixture bridge acceptance: loads actual STEP/IGES/STL/glTF/DXF/LSM
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
        XCTAssertGreaterThan(dto.sceneBoundsMin.x, 15.0, "min X should be ~20 (translated)")
        XCTAssertLessThan(dto.sceneBoundsMax.x, 35.0, "max X should be ~30")
        XCTAssertGreaterThan(dto.sceneBoundsMin.z, 2.0,  "min Z should be ~5 (translated)")
        XCTAssertLessThan(dto.sceneBoundsMax.z, 18.0, "max Z should be ~15")
        // Y should match original (no translation in Y)
        XCTAssertLessThan(abs(dto.sceneBoundsMin.y), 3.0, "min Y should be ~0")
        XCTAssertGreaterThan(dto.sceneBoundsMax.y, 7.0, "max Y should be ~10")
        // Non-trivial extent
        XCTAssertGreaterThan(dto.sceneBoundsMax.x - dto.sceneBoundsMin.x, 5.0, "X extent")
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
    func test_real_assembly_selection_updates_selected_index() throws {
        let (vm, dto) = try makeAssemblyVM()

        // Select first leaf (index 1 — Base_Box)
        vm.selectedIndex = 1
        XCTAssertEqual(vm.selectedIndex, 1)
        let node = dto.nodes[1]
        XCTAssertTrue(node.hasGeometry, "selected node should have geometry")
        XCTAssertGreaterThanOrEqual(node.geometryId, 0)

        // Deselect
        vm.selectedIndex = nil
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

    @MainActor
    func test_real_assembly_hidden_node_then_toggle() throws {
        let (vm, _) = try makeAssemblyVM()

        // Hide Base_Box directly
        vm.hiddenNodeIndices.insert(1)
        XCTAssertTrue(vm.hiddenNodeIndices.contains(1), "Base_Box in hiddenNodeIndices")

        // Un-hide it
        vm.hiddenNodeIndices.remove(1)
        XCTAssertFalse(vm.hiddenNodeIndices.contains(1), "Base_Box removed from hiddenNodeIndices")
        XCTAssertEqual(vm.hiddenNodeIndices.count, 0, "no hidden nodes")
    }
}
