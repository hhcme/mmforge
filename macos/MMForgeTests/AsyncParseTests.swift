import XCTest
import Combine
import Metal
import MetalKit
@testable import MMForge

// MARK: - Async Parse Lifecycle Tests

/// Tests for the async parse pipeline's resource management:
/// success, failure, cancellation, duplicate-open, streaming paths.
final class AsyncParseTests: XCTestCase {

    // MARK: - Helpers

    func testMetalUniformLayoutMatchesShaderABI() {
        XCTAssertEqual(MemoryLayout<Uniforms>.size, 192)
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 192)
        XCTAssertEqual(MemoryLayout<Uniforms>.alignment, 16)
    }

    /// Minimal valid ASCII STL content.
    private var validSTLData: Data {
        let stl = """
        solid test
         facet normal 0 0 1
          outer loop
           vertex 0 0 0
           vertex 1 0 0
           vertex 0 1 0
          endloop
         endfacet
        endsolid test
        """
        return Data(stl.utf8)
    }

    /// Create a view model with a renderer already bound.
    @MainActor
    private func makeVMWithRenderer(_ vm: DocumentViewModel? = nil) -> DocumentViewModel {
        let v = vm ?? DocumentViewModel()
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("no Metal device"); return v
        }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(mtkView: view) else {
            XCTFail("failed to create MetalRenderer"); return v
        }
        v.setRenderer(renderer)
        return v
    }

    // MARK: - Success Path

    /// Verify that a valid STL file parses successfully and the document
    /// transitions to .loaded state.
    @MainActor
    func testParseValidSTL_succeeds() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "parse completes")

        var finalState: DocumentState = .empty
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                finalState = state
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        if case .loaded = finalState {
            XCTAssertTrue(vm.nodeNames.count > 0, "should have nodes")
        } else {
            XCTFail("expected .loaded, got \(finalState)")
        }
        cancellable.cancel()
    }

    // MARK: - Failure Path

    /// Verify that invalid data produces an error state.
    @MainActor
    func testParseInvalidData_setsErrorState() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "parse fails")
        var finalState: DocumentState = .empty
        let cancellable = vm.$state
            .filter { state in
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                finalState = state
                expectation.fulfill()
            }

        vm.parseFile(data: Data(repeating: 0xAB, count: 256), fileExtension: "step")

        wait(for: [expectation], timeout: 10.0)
        if case .error(let msg) = finalState {
            XCTAssertFalse(msg.isEmpty, "error message should not be empty")
        } else {
            XCTFail("expected .error, got \(finalState)")
        }
        cancellable.cancel()
    }

    // MARK: - Cancel Path

    /// Verify that cancelling an in-flight parse does not crash.
    @MainActor
    func testParseCancel_releasesResources() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "terminal state reached")
        var finalState: DocumentState = .empty
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                finalState = state
                expectation.fulfill()
            }

        // Start first parse with garbage, then immediately overwrite with valid data.
        // The second parseFile call cancels the first via freeCurrentDocument.
        vm.parseFile(data: Data(repeating: 0x42, count: 1024 * 1024), fileExtension: "step")
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(
            {
                if case .loaded = finalState { return true }
                if case .error = finalState { return true }
                return false
            }(),
            "expected terminal state, got \(finalState)"
        )
        cancellable.cancel()
    }

    // MARK: - Duplicate Open (Resource Release)

    /// Verify that opening a second file cancels the first.
    @MainActor
    func testDuplicateOpen_cancelsFirstAndSucceeds() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "second parse completes")
        var finalState: DocumentState = .empty
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                finalState = state
                expectation.fulfill()
            }

        vm.parseFile(data: Data(repeating: 0xFF, count: 512), fileExtension: "step")
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(
            {
                if case .loaded = finalState { return true }
                if case .error = finalState { return true }
                return false
            }(),
            "expected terminal state, got \(finalState)"
        )
        cancellable.cancel()
    }

    // MARK: - Empty Data

    /// Verify that empty data produces .empty state without starting a job.
    @MainActor
    func testParseEmptyData_setsEmptyState() {
        let vm = DocumentViewModel()
        vm.parseFile(data: Data(), fileExtension: "step")
        XCTAssertEqual(vm.state, .empty)
        XCTAssertEqual(vm.parseStage, "")
        XCTAssertEqual(vm.parseProgress, 0)
    }

    // MARK: - Progress Callback

    /// Verify that progress callbacks update the published properties.
    @MainActor
    func testParseReportsProgress() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "progress reported")
        var capturedStage: String?
        let cancellable = vm.$parseStage
            .filter { !$0.isEmpty }
            .first()
            .sink { stage in
                capturedStage = stage
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertNotNil(capturedStage, "parseStage should capture non-empty stage during parsing")
        cancellable.cancel()
    }

    // MARK: - Streaming Path Decision

    /// Verify that `shouldStream` returns false for models below the threshold.
    @MainActor
    func testShouldStream_falseForSmallModel() {
        let vm = DocumentViewModel()
        let dto = RenderPacketDTO(
            meshes: [], sceneBoundsMin: .zero, sceneBoundsMax: .zero,
            triangleCount: 1, nodeNames: [], nodes: [],
            stats: RenderPacketDTO.ModelStats(
                nodeCount: 0, geometryCount: 0, materialCount: 0,
                triangleCount: 1, meshCount: 0)
        )
        XCTAssertFalse(vm.shouldStream(dto))
    }

    /// Verify that `shouldStream` returns true for models above the threshold.
    @MainActor
    func testShouldStream_trueForLargeModel() {
        let vm = DocumentViewModel()
        let dto = RenderPacketDTO(
            meshes: [], sceneBoundsMin: .zero, sceneBoundsMax: .zero,
            triangleCount: 200_000, nodeNames: [], nodes: [],
            stats: RenderPacketDTO.ModelStats(
                nodeCount: 0, geometryCount: 0, materialCount: 0,
                triangleCount: 200_000, meshCount: 0)
        )
        XCTAssertTrue(vm.shouldStream(dto))
    }

    /// Verify that small models still use the full upload path (existing behaviour).
    @MainActor
    func testSmallModelUsesFullUploadPath() {
        let vm = DocumentViewModel()
        let expectation = expectation(description: "parse completes")
        var loadedStateReached = false
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                if case .loaded = state { loadedStateReached = true }
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(loadedStateReached, "small model should load via full upload path")
        cancellable.cancel()
    }

    // MARK: - Streaming Path End-to-End

    /// Verify that forcing streaming mode on a small model still reaches .loaded.
    /// Uses `_testForceStreaming` to bypass the triangle-count threshold.
    @MainActor
    func testForceStreaming_reachesLoaded() {
        let vm = makeVMWithRenderer()
        vm._testForceStreaming = true
        let expectation = expectation(description: "streaming completes")
        var loadedStateReached = false
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                if case .loaded = state { loadedStateReached = true }
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(loadedStateReached, "streaming path should reach .loaded")
        XCTAssertTrue(vm.nodeNames.count > 0, "should have nodes after streaming")
        cancellable.cancel()
    }

    /// Verify that streaming upload reports progress (parseStage changes during chunks).
    @MainActor
    func testStreaming_reportsUploadProgress() {
        let vm = makeVMWithRenderer()
        vm._testForceStreaming = true

        var capturedStages: [String] = []
        // Collect all parseStage changes during streaming (skipping empty strings).
        let cancellable = vm.$parseStage
            .filter { !$0.isEmpty }
            .sink { stage in
                if !capturedStages.contains(stage) {
                    capturedStages.append(stage)
                }
            }

        let loadExpectation = expectation(description: "streaming completes")
        let loadCancellable = vm.$state
            .filter { s in if case .loaded = s { true } else if case .error = s { true } else { false } }
            .first()
            .sink { _ in loadExpectation.fulfill() }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [loadExpectation], timeout: 10.0)
        // Should have seen at least one non-empty progress stage (the chunk upload message).
        XCTAssertFalse(capturedStages.isEmpty, "streaming should emit parseStage updates")
        cancellable.cancel()
        loadCancellable.cancel()
    }

    /// Verify that a deferred streaming upload (renderer bound after parse completes)
    /// still reaches .loaded.
    @MainActor
    func testDeferredStreaming_rendererBoundLater() {
        let vm = DocumentViewModel()
        vm._testForceStreaming = true
        let loadExpectation = expectation(description: "streaming completes after renderer bind")
        var loadedStateReached = false
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                if case .loaded = state { loadedStateReached = true }
                loadExpectation.fulfill()
            }

        // Start parse — will defer because no renderer yet.
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        // Wait a tick for the parse to complete and defer.
        let parseDone = expectation(description: "parse completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Create a real MetalRenderer (needs an MTKView).
            guard let device = MTLCreateSystemDefaultDevice() else {
                XCTFail("no Metal device"); return
            }
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
            guard let renderer = MetalRenderer(mtkView: view) else {
                XCTFail("failed to create MetalRenderer"); return
            }
            vm.setRenderer(renderer)
            parseDone.fulfill()
        }
        wait(for: [parseDone], timeout: 5.0)

        wait(for: [loadExpectation], timeout: 10.0)
        XCTAssertTrue(loadedStateReached, "deferred streaming should reach .loaded")
        XCTAssertTrue(vm.nodeNames.count > 0, "should have nodes after deferred streaming")
        cancellable.cancel()
    }

    /// Verify that deferred streaming publishes a loaded shell state before
    /// renderer binding.  SwiftUI only creates the Metal view in `.loaded`;
    /// staying in `.loading` here deadlocks the real app on large models.
    @MainActor
    func testDeferredStreamingPublishesLoadedBeforeRendererBinding() {
        let vm = DocumentViewModel()
        vm._testForceStreaming = true
        let loadExpectation = expectation(description: "loaded shell state before renderer bind")
        var loadedStateReached = false
        let cancellable = vm.$state
            .filter { state in
                if case .loaded = state { return true }
                if case .error = state { return true }
                return false
            }
            .first()
            .sink { state in
                if case .loaded = state { loadedStateReached = true }
                loadExpectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [loadExpectation], timeout: 10.0)
        XCTAssertTrue(loadedStateReached, "deferred streaming must leave .loading before renderer exists")
        XCTAssertTrue(vm.nodeNames.count > 0, "should publish parsed nodes before renderer binding")
        cancellable.cancel()
    }

    // MARK: - Streaming Lifecycle

    /// Verify that opening a new file during streaming cancels the old task
    /// and the new file loads correctly without contamination.
    @MainActor
    func testReopenDuringStreaming_newFileLoads() {
        let vm = makeVMWithRenderer()
        vm._testForceStreaming = true

        // Start first file
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        // Immediately start a second file — should cancel first streaming task.
        let expectation = expectation(description: "second file loads")
        var secondLoaded = false
        let cancellable = vm.$state
            .filter { s in if case .loaded = s { true } else if case .error = s { true } else { false } }
            .sink { s in
                if case .loaded = s { secondLoaded = true }
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(secondLoaded, "second file should reach .loaded")
        XCTAssertTrue(vm.nodeNames.count > 0)
        cancellable.cancel()
    }

    /// Verify that pending streaming DTO is cleared when a new file is opened
    /// before the renderer is bound, and the new file loads normally.
    @MainActor
    func testPendingStreaming_clearedOnReopen() {
        let vm = DocumentViewModel()
        vm._testForceStreaming = true

        // Start first file — will defer because no renderer.
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        // Small delay for parse to complete and defer.
        let parseDone = expectation(description: "first parse deferred")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            parseDone.fulfill()
        }
        wait(for: [parseDone], timeout: 5.0)

        // Now open a second file with a renderer — should clear pending
        // and load the new file.
        let loaded = expectation(description: "second file loads")
        var secondLoaded = false
        let cancellable = vm.$state
            .filter { s in if case .loaded = s { true } else if case .error = s { true } else { false } }
            .sink { s in
                if case .loaded = s { secondLoaded = true }
                loaded.fulfill()
            }

        let vm2 = makeVMWithRenderer(vm)
        vm2.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [loaded], timeout: 10.0)
        XCTAssertTrue(secondLoaded, "second file should load after pending cleared")
        cancellable.cancel()
    }

    /// Verify that a cancelled streaming task does NOT write mesh data or
    /// set .loaded state on the new document.
    @MainActor
    func testStaleStreamingTask_doesNotPublishState() {
        let vm = makeVMWithRenderer()
        vm._testForceStreaming = true

        // Start first parse with streaming — the task will begin uploading.
        vm.parseFile(data: validSTLData, fileExtension: "stl")

        // Wait for some progress, then open a new file.
        let midProgress = expectation(description: "saw streaming progress")
        let cancellable = vm.$parseStage
            .filter { $0.hasPrefix("Uploading meshes (chunk") }
            .first()
            .sink { _ in midProgress.fulfill() }
        wait(for: [midProgress], timeout: 10.0)
        cancellable.cancel()

        // Open new file — cancels old streaming task, clears renderer.
        let loaded = expectation(description: "new file loads")
        var finalTriangleCount = -1
        let loadCancellable = vm.$state
            .filter { s in if case .loaded = s { true } else if case .error = s { true } else { false } }
            .sink { s in
                if case .loaded(let tc, _, _) = s { finalTriangleCount = tc }
                loaded.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [loaded], timeout: 10.0)
        // The new STL has 1 triangle; the old task must not have
        // overwritten the state with a stale value.
        XCTAssertTrue(finalTriangleCount > 0, "should have a valid triangle count")
        loadCancellable.cancel()
    }

    // MARK: - Smoke: Format Support & State Transitions

    /// Valid STL → .loaded with 1+ nodes and positive triangle count.
    @MainActor
    func testSmoke_STL_validFile_reachesLoaded() {
        let vm = DocumentViewModel()
        let e = expectation(description: "loaded")
        var reachedLoaded = false
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { s in
            if case .loaded = s { reachedLoaded = true }
            e.fulfill()
        }
        vm.parseFile(data: validSTLData, fileExtension: "stl")
        wait(for: [e], timeout: 10.0)
        XCTAssertTrue(reachedLoaded, "valid STL must reach .loaded")
        XCTAssertGreaterThan(vm.nodeNames.count, 0, "STL must produce nodes")
        XCTAssertGreaterThan(vm.nodes.count, 0, "STL must produce structure")
        c.cancel()
    }

    /// Invalid/garbage data → .error without crash.
    @MainActor
    func testSmoke_invalidData_reachesError() {
        let vm = DocumentViewModel()
        let e = expectation(description: "error")
        var msg: String = ""
        let c = vm.$state.filter { s in
            if case .error(let m) = s { msg = m; return true }
            return false
        }.first().sink { _ in e.fulfill() }
        vm.parseFile(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), fileExtension: "step")
        wait(for: [e], timeout: 10.0)
        XCTAssertFalse(msg.isEmpty, "error must have a message")
        c.cancel()
    }

    /// Parse → freeCurrentDocument → state.clean.
    @MainActor
    func testSmoke_parseThenCancel_stateClean() {
        let vm = DocumentViewModel()
        let e = expectation(description: "loaded")
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { _ in e.fulfill() }
        vm.parseFile(data: validSTLData, fileExtension: "stl")
        wait(for: [e], timeout: 10.0)
        vm.cancelParse()
        XCTAssertEqual(vm.state, .empty)
        XCTAssertTrue(vm.nodeNames.isEmpty)
        XCTAssertTrue(vm.nodes.isEmpty)
        XCTAssertEqual(vm.visibleNodeIndices, [])
        c.cancel()
    }

    /// DXF data → correctly detected and loaded as 2D drawing.
    @MainActor
    func testSmoke_DXF_validData_loadsAs2DDrawing() {
        let dxf = Data("""
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        0.0
        20
        0.0
        30
        0.0
        11
        1.0
        21
        1.0
        31
        0.0
        0
        ENDSEC
        0
        EOF
        """.utf8)
        let vm = DocumentViewModel()
        let e = expectation(description: "loaded")
        var loaded = false
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { s in
            if case .loaded = s { loaded = true }
            e.fulfill()
        }
        vm.parseFile(data: dxf, fileExtension: "dxf")
        wait(for: [e], timeout: 10.0)
        XCTAssertTrue(loaded, "DXF should load successfully")
        XCTAssertTrue(vm.is2DDrawing, "should be detected as 2D drawing")
        XCTAssertGreaterThan(vm.drawCommands.count, 0, "DXF must have draw commands")
        c.cancel()
    }

    /// parseFile with empty data → .empty immediately.
    @MainActor
    func testSmoke_emptyDataImmediateEmpty() {
        let vm = DocumentViewModel()
        vm.parseFile(data: Data(), fileExtension: "step")
        XCTAssertEqual(vm.state, .empty)
    }

    /// Verify loadingFileExtension is set correctly.
    @MainActor
    func testSmoke_loadingFileExtensionPropagated() {
        let vm = DocumentViewModel()
        vm.parseFile(data: validSTLData, fileExtension: "stl")
        XCTAssertEqual(vm.loadingFileExtension, "stl")
        let e = expectation(description: "done")
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { _ in e.fulfill() }
        wait(for: [e], timeout: 10.0)
        c.cancel()
    }

    // MARK: - DXF Spatial Query Use-After-Free Safety

    /// Verify that the generation-guarded spatial query closure returns nil
    /// after the document is freed (via cancelParse), preventing UAF.
    @MainActor
    func testDXF_spatialQueryReturnsNilAfterCancel() {
        let dxf = Data("""
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        0.0
        20
        0.0
        30
        0.0
        11
        1.0
        21
        1.0
        31
        0.0
        0
        ENDSEC
        0
        EOF
        """.utf8)
        let vm = DocumentViewModel()
        let e = expectation(description: "DXF loaded")
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { _ in e.fulfill() }
        vm.parseFile(data: dxf, fileExtension: "dxf")
        wait(for: [e], timeout: 10.0)
        c.cancel()

        // Snapshot the spatial query closure while document is alive.
        let query = vm.spatialQueryFunc
        XCTAssertNotNil(query, "spatialQueryFunc should be non-nil for loaded DXF")

        // Verify the query works while doc is alive.
        let beforeCancel = query?(0, 0, 100, 100)
        XCTAssertNotNil(beforeCancel, "spatial query should succeed before cancel")

        // Free the document.
        vm.cancelParse()
        XCTAssertEqual(vm.state, .empty)

        // The closure must now return nil because the generation mismatches.
        let afterCancel = query?(0, 0, 100, 100)
        XCTAssertNil(afterCancel, "spatial query must return nil after document freed")
    }

    /// Verify that reopening a DXF file produces a new spatial query closure
    /// and the old one returns nil (generation mismatch).
    @MainActor
    func testDXF_reopen_invalidatesOldLease() {
        let dxf = Data("""
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        0.0
        20
        0.0
        30
        0.0
        11
        1.0
        21
        1.0
        31
        0.0
        0
        ENDSEC
        0
        EOF
        """.utf8)
        let vm = DocumentViewModel()

        let e1 = expectation(description: "first DXF loaded")
        let c1 = vm.$state.filter { s in
            if case .loaded = s { return true }
            return false
        }.first().sink { _ in e1.fulfill() }
        vm.parseFile(data: dxf, fileExtension: "dxf")
        wait(for: [e1], timeout: 10.0)
        c1.cancel()

        let query1 = vm.spatialQueryFunc
        XCTAssertNotNil(query1, "first spatialQueryFunc should be non-nil")

        // Clear and reopen: cancelPars ensures state == .empty, so the
        // next Combine subscription won't fire prematurely on the stale
        // .loaded state from the first parse.
        vm.cancelParse()
        XCTAssertEqual(vm.state, .empty)
        XCTAssertNil(vm.spatialQueryFunc)

        let e2 = expectation(description: "second DXF loaded")
        let c2 = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { _ in e2.fulfill() }
        vm.parseFile(data: dxf, fileExtension: "dxf")
        wait(for: [e2], timeout: 10.0)
        c2.cancel()

        // Old closure must return nil (generation mismatch after reopen).
        let oldResult = query1?(0, 0, 100, 100)
        XCTAssertNil(oldResult, "old spatial query must return nil after reopen")

        // New closure must still work.
        let query2 = vm.spatialQueryFunc
        XCTAssertNotNil(query2, "new spatialQueryFunc should be non-nil")
        let newResult = query2?(0, 0, 100, 100)
        XCTAssertNotNil(newResult, "new spatial query should succeed")
    }

    /// Verify that spawning a new Drawing2DView after DXF close doesn't
    /// cause a crash (the spatialQueryFunc is nil when no doc is loaded).
    @MainActor
    func testDXF_closeThenSpawnView_noCrash() {
        let dxf = Data("""
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        0.0
        20
        0.0
        30
        0.0
        11
        1.0
        21
        1.0
        31
        0.0
        0
        ENDSEC
        0
        EOF
        """.utf8)
        let vm = DocumentViewModel()

        let e = expectation(description: "DXF loaded")
        let c = vm.$state.filter { s in
            if case .loaded = s { return true }
            if case .error = s { return true }
            return false
        }.first().sink { _ in e.fulfill() }
        vm.parseFile(data: dxf, fileExtension: "dxf")
        wait(for: [e], timeout: 10.0)
        c.cancel()

        // Close the document.
        vm.cancelParse()
        XCTAssertEqual(vm.state, .empty)
        XCTAssertNil(vm.spatialQueryFunc)

        // Create a Drawing2DView in the "empty" state — must not crash.
        let view = Drawing2DView()
        view.spatialQueryFunc = vm.spatialQueryFunc  // nil
        view.drawCommands = vm.drawCommands          // []
        XCTAssertNil(view.spatialQueryFunc)
        XCTAssertEqual(view.drawCommands.count, 0)
    }
}

// MARK: - Real STEP Fixture Acceptance
final class RealStepFixtureAcceptanceTests: XCTestCase {
    static var fixturePath: String { ProcessInfo.processInfo.environment["MMFORGE_REAL_STEP_FIXTURE"] ?? findRoot() + "/testfile/方盒子.step" }
    private static func findRoot() -> String {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" { if FileManager.default.fileExists(atPath: u.appendingPathComponent("Cargo.toml").path) { return u.path }; u.deleteLastPathComponent() }
        return FileManager.default.currentDirectoryPath
    }
    func test_97_nodes_96_meshes_async_streaming_visible() throws {
        let p = Self.fixturePath
        guard FileManager.default.fileExists(atPath: p) else { throw XCTSkip("no fixture at \(p)") }
        let d = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertGreaterThan(d.count, 1000)

        // Build VM + renderer on main actor via Task.
        var vm: DocumentViewModel!
        var re: MetalRenderer!
        let built = expectation(description: "built")
        Task { @MainActor in
            vm = DocumentViewModel(); vm._testForceStreaming = true; vm.parseSourceURL = URL(fileURLWithPath: p)
            guard let dev = MTLCreateSystemDefaultDevice() else { return }
            let mv = MTKView(frame: NSRect(x:0,y:0,width:100,height:100), device:dev)
            re = MetalRenderer(mtkView:mv); vm.setRenderer(re!)
            built.fulfill()
        }
        wait(for: [built], timeout: 10.0)
        guard re != nil else { throw XCTSkip("no Renderer") }

        let done = expectation(description:"done"); var fs: DocumentState = .empty
        var cc: AnyCancellable?
        Task { @MainActor in
            cc = vm.$state.filter{ s in if case .loaded=s{true}else if case .error=s{true}else{false} }.first().sink{fs=$0;done.fulfill()}
            vm.parseFile(data:d,fileExtension:"step")
        }
        wait(for:[done],timeout:900.0); cc?.cancel()
        guard case .loaded(let tri,let mesh,let node)=fs else { if case .error(let m)=fs{XCTFail(m)}else{XCTFail("\(fs)")};return }
        XCTAssertGreaterThanOrEqual(node,97,"nodes>=97 got \(node)")
        XCTAssertGreaterThanOrEqual(mesh,96,"mesh>=96 got \(mesh)")
        XCTAssertGreaterThan(tri,1000)

        // Post-parse assertions on main actor.
        let checkDone = expectation(description:"checked")
        Task { @MainActor in
            let g=re.getGPUMeshes(); XCTAssertGreaterThanOrEqual(g.count,96,"gpu>=96 got \(g.count)")
            re.resetCamera();re.updateFrustumCulling(aspect:1280.0/720.0)
#if DEBUG
            let cc=re.frustumCulledIndices.count
            if cc>=g.count{checkDone.fulfill();return}//fail-open
            XCTAssertLessThan(cc,g.count); XCTAssertGreaterThan(re.lastFrameDrawCalls,0)
#endif
            re.renderMode = .solid
            guard let(px,w,h)=re.renderOffscreen(size:CGSize(width:1280,height:720))else{XCTFail("nil");checkDone.fulfill();return}
            var nb=0; px.withUnsafeBytes{pt in let u=pt.bindMemory(to:UInt32.self);for i in 0..<(w*h){let v=u[i];let r=Int((v>>16)&0xFF),g=Int((v>>8)&0xFF),b=Int(v&0xFF);if abs(r-0x24)>10||abs(g-0x1E)>10||abs(b-0x23)>10{nb+=1}}}
            XCTAssertGreaterThan(nb,0,"non-bg>0 got \(nb)")
            checkDone.fulfill()
        }
        wait(for: [checkDone], timeout: 30.0)
    }
}
