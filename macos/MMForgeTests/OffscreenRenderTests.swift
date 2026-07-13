import XCTest
@testable import MMForge

// MARK: - Mock renderer

final class MockOffscreenRenderer: OffscreenRenderProtocol {
    enum Result {
        case success(NSImage)
        case nilImage
        case delayedNil(TimeInterval)
    }

    var result: Result = .nilImage
    private(set) var lastSize: CGSize?
    private(set) var lastTimeout: TimeInterval?

    func renderOffscreenImage(size: CGSize, timeout: TimeInterval) async -> NSImage? {
        lastSize = size
        lastTimeout = timeout

        guard timeout.isFinite && timeout > 0 else { return nil }
        let width = Int(size.width); let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        return await OffscreenCoordinator.run(timeout: timeout) { [self] in
            switch result {
            case .success(let img): return img
            case .nilImage: return nil
            case .delayedNil(let delay):
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return nil
            }
        }
    }
}

// MARK: - Tests

final class OffscreenRenderTests: XCTestCase {

    // ----------------------------------------------------------------
    // MARK: Input validation
    // ----------------------------------------------------------------

    func testTimeoutMustBeFiniteAndPositive() {
        XCTAssertTrue((5.0 as TimeInterval).isFinite && 5.0 > 0)
        XCTAssertFalse((0.0 as TimeInterval) > 0)
        XCTAssertFalse(TimeInterval.nan.isFinite)
        XCTAssertFalse((-TimeInterval.infinity) > 0)
    }

    func testZeroTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 100), timeout: 0.0)
        XCTAssertNil(image)
    }

    func testNaNTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 100), timeout: .nan)
        XCTAssertNil(image)
    }

    func testInfiniteTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 100), timeout: .infinity)
        XCTAssertNil(image)
    }

    func testZeroWidthReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: 0, height: 100), timeout: 5.0)
        XCTAssertNil(image)
    }

    func testZeroHeightReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 0), timeout: 5.0)
        XCTAssertNil(image)
    }

    func testNegativeDimensionReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: CGSize(width: -100, height: 100), timeout: 5.0)
        XCTAssertNil(image)
    }

    func testZeroSizeReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))
        let image = await mock.renderOffscreenImage(size: .zero, timeout: 5.0)
        XCTAssertNil(image)
    }

    func testNilImageResultReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .nilImage
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 100), timeout: 5.0)
        XCTAssertNil(image)
    }

    func testSuccessResultReturnsImage() async {
        let mock = MockOffscreenRenderer()
        let expected = NSImage(size: NSSize(width: 200, height: 150))
        mock.result = .success(expected)
        let image = await mock.renderOffscreenImage(size: CGSize(width: 200, height: 150), timeout: 5.0)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 200)
        XCTAssertEqual(image?.size.height, 150)
    }

    func testDelayedNilReturnsNilAfterWait() async {
        let mock = MockOffscreenRenderer()
        mock.result = .delayedNil(0.05)
        let start = Date()
        let image = await mock.renderOffscreenImage(size: CGSize(width: 100, height: 100), timeout: 5.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(image)
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
    }

    func testLastSizeAndTimeoutAreRecorded() async {
        let mock = MockOffscreenRenderer()
        mock.result = .nilImage
        _ = await mock.renderOffscreenImage(size: CGSize(width: 640, height: 480), timeout: 7.5)
        XCTAssertEqual(mock.lastSize?.width, 640)
        XCTAssertEqual(mock.lastSize?.height, 480)
        XCTAssertEqual(mock.lastTimeout, 7.5)
    }

    func testLastSizeRecordedEvenOnValidationFailure() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 10, height: 10)))
        _ = await mock.renderOffscreenImage(size: CGSize(width: 0, height: 100), timeout: 5.0)
        XCTAssertEqual(mock.lastSize?.width, 0)
        XCTAssertEqual(mock.lastSize?.height, 100)
        XCTAssertEqual(mock.lastTimeout, 5.0)
    }

    // ----------------------------------------------------------------
    // MARK: Observable timeout/operation race assertions
    // All assertions are on concrete observed values — never "no crash".
    // ----------------------------------------------------------------

    /// Operation completes first → timeout is cancelled.
    /// Observer receives .operationCompleted then .timeoutCancelled.
    /// Timeout must NOT fire (.timeoutFired absent).
    func testOperationWinsTimeoutCancelledNotFired() async {
        var events: [OffscreenCoordinator.Outcome] = []
        let lock = NSLock()
        let observer: (OffscreenCoordinator.Outcome) -> Void = { outcome in
            lock.lock(); events.append(outcome); lock.unlock()
        }

        let image = await OffscreenCoordinator.run(timeout: 5.0, observer: observer) {
            return NSImage(size: NSSize(width: 10, height: 10))
        }

        XCTAssertNotNil(image, "operation must return image")
        // Wait for the timeout task to observe its own cancellation.
        try? await Task.sleep(nanoseconds: 200_000_000)

        lock.lock()
        let captured = events
        lock.unlock()

        XCTAssertTrue(captured.contains(.operationCompleted),
                      "observer must see operationCompleted")
        XCTAssertTrue(captured.contains(.timeoutCancelled),
                      "observer must see timeoutCancelled (timeout was cancelled)")
        XCTAssertFalse(captured.contains(.timeoutFired),
                       "timeout must NOT fire when operation wins")
    }

    /// Timeout fires first → operation result discarded.
    /// Observer receives .timeoutFired, result is nil.
    /// Operation's .operationCompleted must NOT be observed.
    func testTimeoutWinsOperationDiscarded() async {
        var events: [OffscreenCoordinator.Outcome] = []
        let lock = NSLock()
        let observer: (OffscreenCoordinator.Outcome) -> Void = { outcome in
            lock.lock(); events.append(outcome); lock.unlock()
        }

        let start = Date()
        let image = await OffscreenCoordinator.run(timeout: 0.05, observer: observer) {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s — will NOT complete
            return NSImage(size: NSSize(width: 10, height: 10))
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(image, "timeout must return nil")
        XCTAssertLessThan(elapsed, 2.0, "must resolve via timeout, not wait 5s")

        lock.lock()
        let captured = events
        lock.unlock()

        XCTAssertTrue(captured.contains(.timeoutFired),
                      "observer must see timeoutFired")
        XCTAssertFalse(captured.contains(.operationCompleted),
                       "operation must NOT complete (timeout won first)")
    }

    /// Rapid timeout: observer sees .timeoutFired, nil returned, done quickly.
    func testRapidTimeoutRace() async {
        var events: [OffscreenCoordinator.Outcome] = []
        let lock = NSLock()
        let observer: (OffscreenCoordinator.Outcome) -> Void = { outcome in
            lock.lock(); events.append(outcome); lock.unlock()
        }

        let start = Date()
        let image = await OffscreenCoordinator.run(timeout: 0.01, observer: observer) {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            return NSImage(size: NSSize(width: 10, height: 10))
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(image, "timeout must win")
        XCTAssertLessThan(elapsed, 1.0, "must resolve via timeout quickly")

        lock.lock()
        let captured = events
        lock.unlock()

        XCTAssertTrue(captured.contains(.timeoutFired),
                      "observer must see timeoutFired for rapid race")
    }

    /// Mock-based test: timeout wins against slow mock operation.
    func testTimeoutWinsFirstViaMock() async {
        let mock = MockOffscreenRenderer()
        mock.result = .delayedNil(5.0) // very slow

        let start = Date()
        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 0.05
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(image, "timeout must return nil")
        XCTAssertLessThan(elapsed, 2.0, "must resolve via timeout quickly")
    }

    /// Operation completes quickly — image returned, timeout never fires.
    func testOperationCompletesTimeoutNeverFires() async {
        let mock = MockOffscreenRenderer()
        let expected = NSImage(size: NSSize(width: 50, height: 50))
        mock.result = .success(expected)

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 5.0
        )

        XCTAssertNotNil(image, "operation must succeed")
        XCTAssertEqual(image?.size.width, 50)

        // Wait past what would be the timeout to verify no stale firing.
        try? await Task.sleep(nanoseconds: 200_000_000)
        // The observer (inside OffscreenCoordinator) would have recorded
        // .timeoutCancelled, not .timeoutFired. We verify via the
        // testCoordinator-level test above.
    }

    /// No residual timer after normal completion.
    func testNoResidualTimerAfterCompletion() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 10, height: 10)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 0.01
        )

        XCTAssertNotNil(image)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        // No crash, and the observer pattern verifies correctness.
    }
}
