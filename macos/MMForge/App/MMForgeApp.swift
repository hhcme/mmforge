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
            CommandMenu("Camera") {
                CameraCommandsView()
            }
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

/// Camera and view menu commands.
struct CameraCommandsView: View {
    @FocusedObject private var viewModel: DocumentViewModel?

    var body: some View {
        Group {
            Button("Fit to View") {
                viewModel?.fitToView()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Home (Reset Camera)") {
                viewModel?.resetCamera()
            }
            .keyboardShortcut("h", modifiers: .command)

            Divider()

            Button("Front View") { viewModel?.setNamedView(.front) }
            Button("Back View") { viewModel?.setNamedView(.back) }
            Button("Left View") { viewModel?.setNamedView(.left) }
            Button("Right View") { viewModel?.setNamedView(.right) }
            Button("Top View") { viewModel?.setNamedView(.top) }
            Button("Bottom View") { viewModel?.setNamedView(.bottom) }
            Button("Isometric View") { viewModel?.setNamedView(.isometric) }

            Divider()

            Button("Toggle Perspective/Orthographic") {
                viewModel?.toggleProjection()
            }
            .keyboardShortcut("p", modifiers: .command)
        }
    }
}
