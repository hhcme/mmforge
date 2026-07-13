import AppKit
import Foundation

/// Coordinates async offscreen rendering with timeout and single-resume protection.
///
/// Used by MetalRenderer (real GPU path) and MockOffscreenRenderer (test path)
/// to share the same timeout/single-resume logic.
///
/// ## Observable outcomes
/// The `observer` closure receives every resolution event — both the operation
/// result and timeout firings. This enables deterministic XCTest assertions
/// (no "didn't crash" or `XCTAssertTrue(true)` as evidence).
struct OffscreenCoordinator {
    /// What resolved the coordinator.
    enum Outcome: Equatable {
        /// The operation completed (may be nil on GPU error).
        case operationCompleted
        /// The timeout fired.
        case timeoutFired
        /// The timeout was cancelled because the operation won.
        case timeoutCancelled
    }

    /// Run an async offscreen operation with timeout and observable outcomes.
    ///
    /// - Parameters:
    ///   - timeout: Maximum seconds to wait (must be > 0 and finite).
    ///   - observer: Called on EVERY resolution event (operation result,
    ///     timeout fired, timeout cancelled). Thread-safe, called at most
    ///     once per event type. Pass `nil` in production.
    ///   - operation: The async rendering work. Returns NSImage? on completion.
    /// - Returns: NSImage? on success, nil on timeout or operation failure.
    static func run(
        timeout: TimeInterval,
        observer: ((Outcome) -> Void)? = nil,
        operation: @escaping () async -> NSImage?
    ) async -> NSImage? {
        guard timeout.isFinite && timeout > 0 else { return nil }

        return await withCheckedContinuation { cont in
            var resumed = false
            let lock = NSLock()

            func safeResume(_ image: NSImage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                lock.lock()
                let cancelled = Task.isCancelled
                lock.unlock()
                if cancelled {
                    observer?(.timeoutCancelled)
                    return
                }
                observer?(.timeoutFired)
                safeResume(nil)
            }

            // Start the operation.
            Task {
                let result = await operation()
                timeoutTask.cancel()
                observer?(.operationCompleted)
                safeResume(result)
            }
        }
    }
}
