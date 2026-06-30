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
                    Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit the model to the viewport")
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Fit model to viewport")

                Picker("", selection: .constant(0)) {
                    Image(systemName: "cube").tag(0)
                    Image(systemName: "square.dashed").tag(1)
                    Image(systemName: "cube.transparent").tag(2)
                }
                .pickerStyle(.segmented)
                .help("Render mode: Solid / Wireframe / Transparent")
                .accessibilityLabel("Render mode")
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
        .onAppear {
            if !document.fileData.isEmpty {
                viewModel.parseFile(data: document.fileData)
            }
        }
        .onChange(of: document.fileData) { _, newData in
            if !newData.isEmpty {
                viewModel.parseFile(data: newData)
            }
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
