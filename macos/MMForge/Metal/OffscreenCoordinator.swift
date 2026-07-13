import AppKit
import Foundation

/// Coordinates async offscreen rendering with timeout and single-resume protection.
///
/// ## Contract
/// - Exactly ONE terminal outcome is reported to `observer` per call.
/// - The path that wins the continuation owns cancellation of the other path.
/// - All resolution (cancellation, observer, resume) happens inside a single
///   lock-protected function — no two paths can interleave their side effects.
/// - Observer receives exactly TWO events: the winner, then the loser.
struct OffscreenCoordinator {
    /// Terminal outcome (winner).  Exactly one is reported per call.
    enum Outcome: Equatable {
        case operationCompleted   // operation finished first
        case timeoutFired         // timeout elapsed first
    }

    /// Loser outcome — what happened to the path that didn't win.
    enum LoserOutcome: Equatable {
        case operationCancelled   // operation was cancelled by timeout
        case timeoutCancelled     // timeout was cancelled by operation
    }

    /// Run an async offscreen operation with timeout and observable outcomes.
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
                         loser: LoserOutcome,
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
                    loser: .operationCancelled,
                    image: nil,
                    cancelOther: { operationTask?.cancel() }
                )
            }

            operationTask = Task {
                let result = await operation()
                resolve(
                    winner: .operationCompleted,
                    loser: .timeoutCancelled,
                    image: result,
                    cancelOther: { timeoutTask?.cancel() }
                )
            }
        }
    }
}
