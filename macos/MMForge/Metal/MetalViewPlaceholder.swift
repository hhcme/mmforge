import SwiftUI
import MetalKit

/// Placeholder for the Metal rendering view.
/// In Phase 1 this will be connected to the Rust bridge's RenderPacket.
struct MetalViewPlaceholder: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Update view state when model changes.
    }
}
