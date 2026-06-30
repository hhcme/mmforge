import SwiftUI
import MetalKit

/// Container for the 3D viewport.  Shows Metal view when loaded,
/// loading spinner when parsing, error view on failure, and
/// empty state when no file is open.
struct ViewportContainer: View {
    @ObservedObject var viewModel: DocumentViewModel

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            switch viewModel.state {
            case .empty:
                EmptyStateView()
            case .loading:
                LoadingStateView()
            case .loaded:
                MetalViewWrapper(viewModel: viewModel)
            case .error(let message):
                ErrorStateView(message: message)
            }
        }
    }
}

// MARK: - States

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Model Loaded")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open a STEP file to begin.")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Parsing STEP file…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Error")
                .font(.title2)
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Metal View

struct MetalViewWrapper: NSViewRepresentable {
    @ObservedObject var viewModel: DocumentViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        mtkView.preferredFramesPerSecond = 60

        if let renderer = MetalRenderer(mtkView: mtkView) {
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
            viewModel.setRenderer(renderer)
        }

        // Gesture recognizers for orbit/pan/zoom/pick.
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        mtkView.addGestureRecognizer(click)

        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        mtkView.addGestureRecognizer(pan)

        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleMagnify(_:)))
        mtkView.addGestureRecognizer(magnify)

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.viewModel = viewModel
        c.setupMonitors()
        return c
    }

    class Coordinator {
        var renderer: MetalRenderer?
        var viewModel: DocumentViewModel?
        private var lastPanPoint: CGPoint = .zero
        private var scrollMonitor: Any?

        deinit {
            if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let renderer, let viewModel, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let viewSize = view.bounds.size
            let picked = renderer.pickNode(at: viewSize, point: point)
            DispatchQueue.main.async {
                viewModel.selectNode(picked)
            }
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let renderer else { return }
            let view = gesture.view!
            let point = gesture.location(in: view)

            switch gesture.state {
            case .began:
                lastPanPoint = point
            case .changed:
                let dx = Float(point.x - lastPanPoint.x)
                let dy = Float(point.y - lastPanPoint.y)
                lastPanPoint = point

                if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                    // Alt+drag = pan
                    renderer.pan(dx: dx, dy: dy)
                } else {
                    // Drag = orbit
                    renderer.rotate(dx: dx, dy: dy)
                }
            default:
                break
            }
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            guard let renderer else { return }
            if gesture.state == .changed {
                renderer.zoom(delta: Float(gesture.magnification) * 10)
                gesture.magnification = 0
            }
        }

        func setupMonitors() {
            // Scroll wheel zoom (only when pointer is over the MTKView).
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self, let renderer = self.renderer,
                      let view = event.window?.contentView?.hitTest(event.locationInWindow),
                      view is MTKView || view.superview is MTKView else {
                    return event
                }
                let delta = Float(event.scrollingDeltaY)
                if abs(delta) > 0.1 {
                    renderer.zoom(delta: delta * 0.3)
                }
                return event
            }
        }
    }
}
