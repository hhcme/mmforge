import SwiftUI
import UniformTypeIdentifiers

/// The main document window content: sidebar + viewport + inspector.
struct ContentView: View {
    @Binding var document: MMForgeDocument
    @StateObject private var viewModel = DocumentViewModel()
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true

    var body: some View {
        HSplitView {
            if sidebarVisible {
                StructureSidebar(viewModel: viewModel)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
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
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { sidebarVisible.toggle() }) {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Show or hide the structure sidebar")
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            }

            ToolbarItemGroup(placement: .principal) {
                Button(action: { viewModel.fitToView() }) {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit the model to the viewport (F)")
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Fit model to viewport")

                Button(action: { viewModel.resetCamera() }) {
                    Label("Home", systemImage: "house")
                }
                .help("Reset camera to default view (H)")
                .accessibilityLabel("Reset camera")

                Menu {
                    Button("Front") { viewModel.setNamedView(.front) }
                    Button("Back") { viewModel.setNamedView(.back) }
                    Button("Left") { viewModel.setNamedView(.left) }
                    Button("Right") { viewModel.setNamedView(.right) }
                    Button("Top") { viewModel.setNamedView(.top) }
                    Button("Bottom") { viewModel.setNamedView(.bottom) }
                    Divider()
                    Button("Isometric") { viewModel.setNamedView(.isometric) }
                } label: {
                    Label("View", systemImage: "cube")
                }
                .help("Standard view directions")
                .accessibilityLabel("Standard view directions")

                Picker("", selection: $viewModel.renderMode) {
                    Image(systemName: "cube").tag(RenderMode.solid)
                    Image(systemName: "square.dashed").tag(RenderMode.wireframe)
                    Image(systemName: "cube.fill").tag(RenderMode.solidWireframe)
                    Image(systemName: "cube.transparent").tag(RenderMode.transparent)
                }
                .pickerStyle(.segmented)
                .help("Render mode: Solid / Wireframe / Solid+Wire / Transparent")
                .accessibilityLabel("Render mode")
                .onChange(of: viewModel.renderMode) { _, newMode in
                    viewModel.setRenderMode(newMode)
                }

                Button(action: { viewModel.toggleMeasurementMode() }) {
                    Image(systemName: viewModel.measurementMode ? "ruler.fill" : "ruler")
                }
                .help("Toggle point-to-point measurement mode")
                .accessibilityLabel(viewModel.measurementMode
                                    ? "Exit measurement mode" : "Enter measurement mode")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { inspectorVisible.toggle() }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector panel")
                .keyboardShortcut("i", modifiers: .command)
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
            viewModel.parseFile(data: document.fileData)
        }
        .onChange(of: document.fileData) { _, newData in
            viewModel.parseFile(data: newData)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                if let fileData = try? Data(contentsOf: url) {
                    document.fileData = fileData
                }
            }
        }
        return true
    }
}

// MARK: - Selection / Visibility menu commands

struct SelectionCommands: View {
    @ObservedObject var viewModel: DocumentViewModel

    var body: some View {
        Group {
            Button("Select Root") {
                viewModel.selectNode(0)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!viewModel.isLoaded)

            Divider()

            Button("Hide Selection") {
                viewModel.hideSelectedNode()
            }
            .keyboardShortcut("h", modifiers: .command)
            .disabled(viewModel.selectedIndex == nil)

            Button("Show All") {
                viewModel.setAllNodesVisible()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(viewModel.hiddenNodeIndices.isEmpty)
        }
    }
}
