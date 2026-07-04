import SwiftUI
import MetalKit

/// Container for the 3D/2D viewport.  Shows Metal view for 3D models,
/// Core Graphics drawing view for 2D drawings (DXF), loading spinner
/// when parsing, error view on failure, and empty state when no file
/// is open.
struct ViewportContainer: View {
    @ObservedObject var viewModel: DocumentViewModel

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            switch viewModel.state {
            case .empty:
                EmptyStateView()
            case .loading:
                LoadingStateView(
                    stage: viewModel.parseStage,
                    progress: viewModel.parseProgress,
                    onCancel: { viewModel.cancelParse() },
                    fileExtension: viewModel.loadingFileExtension
                )
            case .loaded:
                if viewModel.is2DDrawing {
                    Drawing2DViewRepresentable(
                        drawCommands: viewModel.drawCommands,
                        drawingInfo: viewModel.drawing2DInfo,
                        layerVisibilityOverrides: viewModel.layerVisibility,
                        documentPointer: viewModel.rustDoc,
                        annotations: viewModel.annotations,
                        measurementMode: viewModel.measurementMode,
                        measurementType: viewModel.measurementType,
                        snapEnabled: viewModel.snapEnabled,
                        activeAnnotationTool: viewModel.activeAnnotationTool,
                        annotationToolText: viewModel.annotationToolText,
                        pendingAnnotationPoint: viewModel.pendingAnnotationPoint,
                        pendingPolygonPoints: viewModel.pendingPolygonPoints,
                        annotationDelegate: viewModel
                    )
                } else {
                    MetalViewWrapper(viewModel: viewModel)
                }
            case .error(let message):
                ErrorStateView(message: message)
            }
        }
    }
}

// MARK: - States

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Model Loaded")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Drag and drop or use ⌘O to open a file.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                Text("Supported: STEP, STL, glTF/GLB, IGES, DXF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No model loaded. Supported formats: STEP, STL, glTF, IGES, DXF")
    }
}

struct LoadingStateView: View {
    let stage: String
    let progress: Double
    let onCancel: (() -> Void)?
    let fileExtension: String

    init(stage: String = "", progress: Double = 0,
         onCancel: (() -> Void)? = nil, fileExtension: String = "step") {
        self.stage = stage
        self.progress = progress
        self.onCancel = onCancel
        self.fileExtension = fileExtension
    }

    private var formatName: String {
        switch fileExtension.lowercased() {
        case "step", "stp": return "STEP"
        case "iges", "igs": return "IGES"
        case "stl": return "STL"
        case "gltf", "glb": return "glTF"
        case "dxf": return "DXF"
        default: return fileExtension.uppercased()
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 4) {
                Text("Opening \(formatName) File")
                    .font(.title3)
                    .foregroundStyle(.primary)

                if !stage.isEmpty {
                    Text(stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if progress > 0 {
                VStack(spacing: 6) {
                    ProgressView(value: progress, total: 1.0)
                        .frame(maxWidth: 280)
                        .controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .accessibilityLabel("\(Int(progress * 100)) percent complete")
            } else {
                ProgressView()
                    .scaleEffect(1.0)
                    .controlSize(.small)
            }

            if let onCancel {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(progress >= 1.0 && !stage.isEmpty)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading \(formatName) file")
    }
}

struct ErrorStateView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Unable to Open File")
                .font(.title2)
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Text("Try opening a different file or check the file format.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Error: \(message)")
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
        // Allow reading the drawable texture for screenshot capture.
        mtkView.framebufferOnly = false

        if let renderer = MetalRenderer(mtkView: mtkView) {
            mtkView.delegate = renderer
            renderer.mtkView = mtkView  // store reference for screenshot capture
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

            // Check measurement mode and pick on main thread to avoid
            // actor-isolation issues.
            DispatchQueue.main.async {
                if viewModel.measurementMode {
                    if let worldPoint = renderer.pickWorldPoint(at: viewSize, point: point) {
                        viewModel.addMeasurementPoint(worldPoint)
                    }
                } else {
                    let picked = renderer.pickNode(at: viewSize, point: point)
                    viewModel.selectNode(picked)
                }
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
