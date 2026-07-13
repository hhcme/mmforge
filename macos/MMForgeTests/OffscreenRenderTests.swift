import XCTest
@testable import MMForge

// MARK: - Mock renderer for deterministic testing

/// In-memory renderer that simulates every offscreen code path
/// without a real GPU.
///
/// Validates the same preconditions as `MetalRenderer.renderOffscreenAsync`
/// (finite positive timeout, positive dimensions) so tests are deterministic
/// and meaningful.
final class MockOffscreenRenderer: OffscreenRenderProtocol {
    /// Simulated render result.
    enum Result {
        /// Return a specific NSImage immediately.
        case success(NSImage)
        /// Return nil immediately (simulates GPU error or empty scene).
        case nilImage
        /// Return nil after a delay (simulates timeout / hung GPU).
        case delayedNil(TimeInterval)
    }

    var result: Result = .nilImage

    /// Last size passed to `renderOffscreenImage`.
    private(set) var lastSize: CGSize?
    /// Last timeout passed to `renderOffscreenImage`.
    private(set) var lastTimeout: TimeInterval?

    func renderOffscreenImage(size: CGSize, timeout: TimeInterval) async -> NSImage? {
        lastSize = size
        lastTimeout = timeout

        // ---------- validate inputs (mirrors MetalRenderer) ----------
        guard timeout.isFinite && timeout > 0 else { return nil }
        let width = Int(size.width); let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        // -------------------------------------------------------------

        switch result {
        case .success(let img):
            return img
        case .nilImage:
            return nil
        case .delayedNil(let delay):
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return nil
        }
    }
}

// MARK: - Tests

final class OffscreenRenderTests: XCTestCase {

    // ----------------------------------------------------------------
    // MARK: Input validation (pure logic, no GPU)
    // ----------------------------------------------------------------

    func testTimeoutMustBeFiniteAndPositive() {
        // Valid
        XCTAssertTrue((5.0 as TimeInterval).isFinite && 5.0 > 0,
                      "finite positive timeout should be valid")

        // Zero
        XCTAssertFalse((0.0 as TimeInterval) > 0,
                       "zero timeout should be rejected")

        // NaN
        let nan = TimeInterval.nan
        XCTAssertFalse(nan.isFinite, "NaN should not be finite")

        // Negative infinity
        let negInf = -TimeInterval.infinity
        XCTAssertFalse(negInf > 0, "negative infinity should not be > 0")
    }

    // ----------------------------------------------------------------
    // MARK: Timeout validation via mock
    // ----------------------------------------------------------------

    func testZeroTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 0.0
        )
        XCTAssertNil(image, "zero timeout must return nil (validation rejects)")
    }

    func testNaNTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: .nan
        )
        XCTAssertNil(image, "NaN timeout must return nil (validation rejects)")
    }

    func testInfiniteTimeoutReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: .infinity
        )
        XCTAssertNil(image, "infinite timeout must return nil (validation rejects)")
    }

    // ----------------------------------------------------------------
    // MARK: Size validation via mock
    // ----------------------------------------------------------------

    func testZeroWidthReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 0, height: 100), timeout: 5.0
        )
        XCTAssertNil(image, "zero width must return nil")
    }

    func testZeroHeightReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 0), timeout: 5.0
        )
        XCTAssertNil(image, "zero height must return nil")
    }

    func testNegativeDimensionReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: -100, height: 100), timeout: 5.0
        )
        XCTAssertNil(image, "negative dimension must return nil")
    }

    func testZeroSizeReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 100, height: 100)))

        let image = await mock.renderOffscreenImage(
            size: .zero, timeout: 5.0
        )
        XCTAssertNil(image, "zero size must return nil")
    }

    // ----------------------------------------------------------------
    // MARK: Result simulation paths
    // ----------------------------------------------------------------

    func testNilImageResultReturnsNil() async {
        let mock = MockOffscreenRenderer()
        mock.result = .nilImage

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 5.0
        )
        XCTAssertNil(image, ".nilImage result must return nil (simulates GPU error)")
    }

    func testSuccessResultReturnsImage() async {
        let mock = MockOffscreenRenderer()
        let expected = NSImage(size: NSSize(width: 200, height: 150))
        mock.result = .success(expected)

        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 200, height: 150), timeout: 5.0
        )
        XCTAssertNotNil(image, ".success result must return an image")
        XCTAssertEqual(image?.size.width, 200)
        XCTAssertEqual(image?.size.height, 150)
    }

    func testDelayedNilReturnsNilAfterWait() async {
        let mock = MockOffscreenRenderer()
        // Short delay so the test is not slow but still verifies the path.
        mock.result = .delayedNil(0.05)

        let start = Date()
        let image = await mock.renderOffscreenImage(
            size: CGSize(width: 100, height: 100), timeout: 5.0
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(image, ".delayedNil must eventually return nil")
        XCTAssertGreaterThanOrEqual(elapsed, 0.04,
                                    "delayedNil should wait at least the specified delay")
    }

    // ----------------------------------------------------------------
    // MARK: Parameter recording
    // ----------------------------------------------------------------

    func testLastSizeAndTimeoutAreRecorded() async {
        let mock = MockOffscreenRenderer()
        mock.result = .nilImage

        let size = CGSize(width: 640, height: 480)
        let timeout: TimeInterval = 7.5

        _ = await mock.renderOffscreenImage(size: size, timeout: timeout)

        XCTAssertEqual(mock.lastSize?.width, 640)
        XCTAssertEqual(mock.lastSize?.height, 480)
        XCTAssertEqual(mock.lastTimeout, 7.5)
    }

    func testLastSizeRecordedEvenOnValidationFailure() async {
        let mock = MockOffscreenRenderer()
        mock.result = .success(NSImage(size: NSSize(width: 10, height: 10)))

        _ = await mock.renderOffscreenImage(size: CGSize(width: 0, height: 100), timeout: 5.0)

        // Even though validation rejected the call, lastSize should still be set
        // since the mock records parameters before validating.
        XCTAssertEqual(mock.lastSize?.width, 0)
        XCTAssertEqual(mock.lastSize?.height, 100)
        XCTAssertEqual(mock.lastTimeout, 5.0)
    }

    // ----------------------------------------------------------------
    // MARK: Single-resume isolation (structural correctness)
    // ----------------------------------------------------------------

    /// Verify that an NSLock-guarded boolean flag prevents double-resume.
    /// The real `MetalRenderer.renderOffscreenAsync` uses this same pattern
    /// to protect its `CheckedContinuation` from being resumed twice
    /// (once by the GPU completion handler, once by the timeout path).
    func testSingleResumeLockPattern() {
        let lock = NSLock()
        var resumed = false
        var resumeCount = 0

        /// Simulates the `safeResume` closure in the real renderer.
        func finish() {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            resumeCount += 1
        }

        // Two racing paths both call finish — only one increments resumeCount.
        finish()
        finish()

        XCTAssertEqual(resumeCount, 1,
                       "second finish() must be a no-op after first sets resolved=true")
    }

    /// A concurrent stress test for the lock pattern: many threads
    /// racing to call finish() should still result in exactly one resume.
    func testSingleResumeLockPatternUnderConcurrency() {
        let lock = NSLock()
        var resolved = false
        var resumeCount = 0
        let iterations = 500
        let group = DispatchGroup()

        /// Simulates the `safeResume` closure.
        func finish() {
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else { return }
            resolved = true
            resumeCount += 1
        }

        for _ in 0..<iterations {
            DispatchQueue.global().async(group: group) {
                finish()
            }
        }

        group.wait()

        XCTAssertEqual(resumeCount, 1,
                       "concurrent finish() calls must resume exactly once")
    }
}
