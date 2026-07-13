import AppKit
import Foundation

/// Coordinates async offscreen rendering with timeout and single-resume protection.
///
/// Used by MetalRenderer (real GPU path) and MockOffscreenRenderer (test path)
/// to share the same timeout/single-resume logic.
struct OffscreenCoordinator {
    /// Run an async offscreen operation with timeout.
    ///
    /// - Parameters:
    ///   - timeout: Maximum seconds to wait (must be > 0 and finite).
    ///   - operation: The async rendering work. Returns NSImage? on completion.
    /// - Returns: NSImage? on success, nil on timeout or operation failure.
    static func run(
        timeout: TimeInterval,
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

            // Start the operation.
            Task {
                let result = await operation()
                safeResume(result)
            }

            // Timeout path.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                safeResume(nil)
            }
        }
    }
}
