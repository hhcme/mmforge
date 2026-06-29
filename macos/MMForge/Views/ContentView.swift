import SwiftUI

/// The main document window content: sidebar + viewport + inspector.
struct ContentView: View {
    @State private var document: MMForgeDocument
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true

    init(document: MMForgeDocument) {
        _document = State(initialValue: document)
    }

    var body: some View {
        HSplitView {
            if sidebarVisible {
                StructureSidebar()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            }

            ViewportContainer()
                .frame(minWidth: 400, minHeight: 300)

            if inspectorVisible {
                InspectorPanel()
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
            }

            ToolbarItemGroup(placement: .principal) {
                Button(action: {}) {
                    Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit the model to the viewport")
                .keyboardShortcut("f", modifiers: .command)

                Picker("", selection: .constant(0)) {
                    Image(systemName: "cube").tag(0)
                    Image(systemName: "square.dashed").tag(1)
                    Image(systemName: "cube.transparent").tag(2)
                }
                .pickerStyle(.segmented)
                .help("Render mode: Solid / Wireframe / Transparent")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { inspectorVisible.toggle() }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector panel")
                .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}
