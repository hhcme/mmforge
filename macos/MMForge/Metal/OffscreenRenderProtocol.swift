import AppKit
import Foundation

/// Protocol for offscreen rendering, enabling deterministic XCTests
/// without requiring a real GPU.
///
/// Conformers (MetalRenderer or test mocks) must validate their inputs
/// and return nil on timeout, GPU error, or invalid parameters.
protocol OffscreenRenderProtocol: AnyObject {
    /// Render the current scene to an offscreen image.
    /// - Parameter size: output image dimensions in pixels (must be > 0 in both axes)
    /// - Parameter timeout: seconds before giving up (must be > 0 and finite)
    /// - Returns: NSImage on success, nil on timeout, GPU error, or invalid input
    func renderOffscreenImage(size: CGSize, timeout: TimeInterval) async -> NSImage?
}
