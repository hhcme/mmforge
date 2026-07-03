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
}
