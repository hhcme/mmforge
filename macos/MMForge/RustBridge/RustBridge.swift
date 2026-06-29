import Foundation

/// Bridge between Swift/UI and the Rust core library.
///
/// Phase 0: placeholder.  Phase 1 will add FFI calls via a C ABI
/// to invoke the Rust parser, tessellator, and RenderPacket builder.
final class RustBridge {
    static let shared = RustBridge()

    private init() {}

    /// Returns the Rust core library version string.
    func coreVersion() -> String {
        // Phase 1: call into Rust via C ABI.
        // For now return a placeholder.
        return "0.1.0 (Phase 0 placeholder)"
    }

    /// Parse a file and return the model data.
    /// Phase 1: will invoke Rust parser via FFI.
    func parseFile(at path: String) throws -> Data {
        throw NSError(
            domain: "MMForge",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Rust bridge not yet connected (Phase 0)"]
        )
    }
}
