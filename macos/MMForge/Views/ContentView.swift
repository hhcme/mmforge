import SwiftUI
import UniformTypeIdentifiers

/// The main document window content: sidebar + viewport + inspector.
struct ContentView: View {
    @Binding var document: MMForgeDocument
    let fileURL: URL?
    @StateObject private var viewModel = DocumentViewModel()
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true

    var body: some View {
        HSplitView {
            if sidebarVisible {
                StructureSidebar(viewModel: viewModel)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }

            ViewportContainer(viewModel: viewModel)
                .frame(minWidth: 400, minHeight: 300)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                }

            if inspectorVisible {
                InspectorPanel(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            }
        }
        .toolbar {
            // Navigation toolbar items
            ToolbarItem(placement: .navigation) {
                Button(action: { sidebarVisible.toggle() }) {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help("Show or hide the structure sidebar")
                .keyboardShortcut("S", modifiers: .command)
                .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            }

            // Principal toolbar items (centered)
            ToolbarItemGroup(placement: .principal) {
                // Camera controls
                Button(action: { viewModel.fitToView() }) {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit the model to the viewport (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Fit model to viewport")

                Button(action: { viewModel.resetCamera() }) {
                    Label("Home", systemImage: "house")
                }
                .help("Reset camera to default view")
                .accessibilityLabel("Reset camera")

                // Named views
                Menu {
                    Button("Front") { viewModel.setNamedView(.front) }
                    Button("Back") { viewModel.setNamedView(.back) }
                    Button("Left") { viewModel.setNamedView(.left) }
                    Button("Right") { viewModel.setNamedView(.right) }
                    Button("Top") { viewModel.setNamedView(.top) }
                    Button("Bottom") { viewModel.setNamedView(.bottom) }
                    Divider()
                    Button("Isometric") { viewModel.setNamedView(.isometric) }
                    Divider()
                    Button("Perspective/Orthographic") {
                        viewModel.toggleProjection()
                    }
                    .keyboardShortcut("P", modifiers: [.command, .shift])
                } label: {
                    Label("View", systemImage: "cube")
                }
                .help("Standard view directions")
                .accessibilityLabel("Standard view directions")

                // Render mode picker with labels per macOS HIG
                Picker("Render Mode", selection: $viewModel.renderMode) {
                    Label("Solid", systemImage: "cube")
                        .tag(RenderMode.solid)
                    Label("Wireframe", systemImage: "square.dashed")
                        .tag(RenderMode.wireframe)
                    Label("Solid+Wire", systemImage: "cube.fill")
                        .tag(RenderMode.solidWireframe)
                    Label("X-Ray", systemImage: "cube.transparent")
                        .tag(RenderMode.transparent)
                }
                .pickerStyle(.segmented)
                .help("Render mode: Solid / Wireframe / Solid+Wire / Transparent")
                .accessibilityLabel("Render mode")
                .onChange(of: viewModel.renderMode) { _, newMode in
                    viewModel.setRenderMode(newMode)
                }

                // Measurement mode toggle
                Button(action: { viewModel.toggleMeasurementMode() }) {
                    Label("Measure", systemImage: viewModel.measurementMode ? "ruler.fill" : "ruler")
                }
                .help("Toggle point-to-point measurement mode (⌘M)")
                .keyboardShortcut("M", modifiers: .command)
                .accessibilityLabel(viewModel.measurementMode
                                    ? "Exit measurement mode" : "Enter measurement mode")
            }

            // Primary action toolbar items (right side)
            ToolbarItemGroup(placement: .primaryAction) {
                // Clipping toggle
                Button(action: { viewModel.toggleClipping() }) {
                    Label("Clip", systemImage: viewModel.clipEnabled ? "scissors.badge.ellipsis" : "scissors")
                }
                .help("Toggle clipping plane (⌘K)")
                .keyboardShortcut("K", modifiers: .command)
                .accessibilityLabel(viewModel.clipEnabled ? "Disable clipping" : "Enable clipping")

                // Export
                Button(action: { viewModel.exportImage() }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export current viewport as image (⌘E)")
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!viewModel.isLoaded)
                .accessibilityLabel("Export image")

                // Inspector toggle
                Button(action: { inspectorVisible.toggle() }) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector panel (⌘I)")
                .keyboardShortcut("I", modifiers: .command)
                .accessibilityLabel(inspectorVisible ? "Hide inspector" : "Show inspector")
            }
        }
        .focusedObject(viewModel)
        .alert("Export Error",
               isPresented: Binding(
                   get: { viewModel.exportError != nil },
                   set: { if !$0 { viewModel.exportError = nil } }
               )) {
            Button("OK") { viewModel.exportError = nil }
        } message: {
            Text(viewModel.exportError ?? "")
        }
        .onAppear {
            viewModel.parseSourceURL = fileURL
            viewModel.parseFile(data: document.fileData, fileExtension: document.fileExtension)
        }
        .onChange(of: document.fileData) { _, newData in
            viewModel.parseSourceURL = fileURL
            viewModel.parseFile(data: newData, fileExtension: document.fileExtension)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                if let fileData = try? Data(contentsOf: url) {
                    document.fileURL = url
                    document.fileData = fileData
                    let ext = url.pathExtension.lowercased()
                    if !ext.isEmpty {
                        document.fileExtension = ext
                    }
                }
            }
        }
        return true
    }
}
