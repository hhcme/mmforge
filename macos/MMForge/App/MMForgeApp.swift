import SwiftUI

@main
struct MMForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MMForgeDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(after: .textEditing) {
                SelectionCommandsView()
            }
        }

        #if DEBUG
        Window("Debug Console", id: "debug-console") {
            Text("Debug Console Placeholder")
                .frame(minWidth: 400, minHeight: 300)
        }
        #endif
    }
}

/// Menu commands for selection and visibility.
/// Uses @FocusedObject to access the current document's view model.
struct SelectionCommandsView: View {
    @FocusedObject private var viewModel: DocumentViewModel?

    var body: some View {
        Group {
            Button("Select Root") {
                viewModel?.selectNode(0)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(viewModel == nil || !(viewModel?.isLoaded ?? false))

            Divider()

            Button("Hide Selection") {
                viewModel?.hideSelectedNode()
            }
            .disabled(viewModel?.selectedIndex == nil)

            Button("Show All") {
                viewModel?.setAllNodesVisible()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(viewModel?.hiddenNodeIndices.isEmpty ?? true)

            Divider()

            Button("Toggle Clipping Plane") {
                viewModel?.toggleClipping()
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}
