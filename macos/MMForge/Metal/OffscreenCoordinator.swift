import AppKit
import Foundation

/// Coordinates async offscreen rendering with timeout and single-resume protection.
///
/// ## Contract
/// - Exactly ONE terminal outcome is reported to `observer` per call:
///   either `.operationCompleted` or `.timeoutFired` — never both.
/// - The path that wins the continuation owns cancellation of the other path.
/// - All resolution (cancellation, observer, resume) happens inside a single
///   lock-protected function — no two paths can interleave their side effects.
struct OffscreenCoordinator {
    /// Terminal outcome.  Exactly one is reported per `run()` call.
    enum Outcome: Equatable {
        case operationCompleted   // operation finished first
        case timeoutFired         // timeout elapsed first
    }

    /// Run an async offscreen operation with timeout and observable outcome.
    static func run(
        timeout: TimeInterval,
        observer: ((Outcome) -> Void)? = nil,
        operation: @escaping () async -> NSImage?
    ) async -> NSImage? {
        guard timeout.isFinite && timeout > 0 else { return nil }

        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var resolved = false

            /// The single terminal resolution function.
            func resolve(winner: Outcome,
                         image: NSImage?,
                         cancelOther: @escaping () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true

                cancelOther()
                observer?(winner)

                cont.resume(returning: image)
            }

            var operationTask: Task<Void, Never>?
            var timeoutTask: Task<Void, Never>?

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resolve(
                    winner: .timeoutFired,
                    image: nil,
                    cancelOther: { operationTask?.cancel() }
                )
            }

            operationTask = Task {
                let result = await operation()
                resolve(
                    winner: .operationCompleted,
                    image: result,
                    cancelOther: { timeoutTask?.cancel() }
                )
            }
        }
    }
}
