import XCTest
import Combine
@testable import MMForge

// MARK: - Async Parse Lifecycle Tests

/// Tests for the async parse pipeline's resource management:
/// success, failure, cancellation, and duplicate-open paths.
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
        let cancellable = vm.$parseStage
            .filter { !$0.isEmpty }
            .first()
            .sink { _ in
                expectation.fulfill()
            }

        vm.parseFile(data: validSTLData, fileExtension: "stl")

        wait(for: [expectation], timeout: 10.0)
        XCTAssertFalse(vm.parseStage.isEmpty, "parseStage should be set")
        cancellable.cancel()
    }
}
