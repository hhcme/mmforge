import AppKit
import Foundation

/// Coordinates async offscreen rendering with timeout and single-resume protection.
///
/// Used by MetalRenderer (real GPU path) and MockOffscreenRenderer (test path).
///
/// ## Contract
/// - Exactly ONE terminal outcome is reported to `observer` per call.
/// - When timeout fires first, the operation Task is cancelled.
/// - When the operation completes first, the timeout Task is cancelled.
/// - `Task.isCancelled` is checked before any resume call.
struct OffscreenCoordinator {
    /// What resolved the coordinator.  Exactly one is reported per call.
    enum Outcome: Equatable {
        case operationCompleted
        case timeoutFired
        case timeoutCancelled
    }

    /// Run an async offscreen operation with timeout and observable outcomes.
    ///
    /// - Parameters:
    ///   - timeout: Maximum seconds (must be > 0 and finite).
    ///   - observer: Called on EVERY resolution event.  Thread-safe.
    ///   - operation: The async work.  Returns NSImage? on completion.
    /// - Returns: NSImage? on success, nil on timeout or failure.
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

            // Hold the operation Task so we can cancel it on timeout.
            var operationTask: Task<Void, Never>?

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                lock.lock()
                let cancelled = Task.isCancelled
                lock.unlock()
                if cancelled {
                    observer?(.timeoutCancelled)
                    return
                }
                // Timeout wins — cancel the operation if still running.
                lock.lock()
                operationTask?.cancel()
                lock.unlock()
                observer?(.timeoutFired)
                safeResume(nil)
            }

            operationTask = Task {
                let result = await operation()
                timeoutTask.cancel()
                // Only report completion if WE were not cancelled.
                // If timeoutTask cancelled us, don't emit operationCompleted.
                if !Task.isCancelled {
                    observer?(.operationCompleted)
                }
                safeResume(result)
            }
        }
    }
}
