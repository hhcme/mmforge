import SwiftUI

@main
struct MMForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MMForgeDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            // Hide the standard New menu item — DocumentGroup already provides
            // new-document creation via its own mechanism.
            CommandGroup(replacing: .newItem) {}

            // Clear Recent Documents sits in the File menu area.
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Clear Recent Documents") {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                    RecentDocumentStore.shared.clear()
                }
            }

            SidebarCommands()
            InspectorCommands()
            CommandMenu("Camera") {
                CameraCommandsView()
            }
            CommandMenu("Render") {
                RenderCommandsView()
            }
            CommandMenu("Export") {
                ExportCommandsView()
            }
            CommandGroup(after: .textEditing) {
                SelectionCommandsView()
            }
        }
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
            .disabled(!(viewModel?.selectedHasHideableGeometry ?? false))

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

            Divider()

            Button("Toggle Measurement") {
                viewModel?.toggleMeasurementMode()
            }
            .keyboardShortcut("m", modifiers: .command)

            Button("Clear Measurements") {
                viewModel?.clearMeasurements()
            }
            .disabled(viewModel?.measurements.isEmpty ?? true)

            Divider()

            Button("Reset All Colors") {
                viewModel?.resetAllColors()
            }
            .disabled(viewModel?.nodeColorOverrides.isEmpty ?? true)
        }
    }
}

/// Export menu commands.
struct ExportCommandsView: View {
    @FocusedObject private var viewModel: DocumentViewModel?

    var body: some View {
        Group {
            Button("Export Image…") {
                viewModel?.exportImage()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(viewModel?.isLoaded ?? false))

            Button("Export PDF…") {
                viewModel?.exportPDF()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!(viewModel?.isLoaded ?? false))
        }
    }
}

/// Camera and view menu commands.
///
/// Shortcut policy (Apple HIG):
/// - Cmd+F = Fit to View (consistent with toolbar)
/// - Home/Reset has no shortcut to avoid conflicts
/// - Individual view presets have no shortcuts (accessible via menu)
/// - Cmd+Shift+P = Toggle projection (Cmd+P is Print)
struct CameraCommandsView: View {
    @FocusedObject private var viewModel: DocumentViewModel?

    var body: some View {
        Group {
            Button("Fit to View") {
                viewModel?.fitToView()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Reset Camera") {
                viewModel?.resetCamera()
            }
            // No shortcut — avoids Cmd+H conflict with Hide Application.

            Divider()

            Button("Front View") { viewModel?.setNamedView(.front) }
            Button("Back View") { viewModel?.setNamedView(.back) }
            Button("Left View") { viewModel?.setNamedView(.left) }
            Button("Right View") { viewModel?.setNamedView(.right) }
            Button("Top View") { viewModel?.setNamedView(.top) }
            Button("Bottom View") { viewModel?.setNamedView(.bottom) }
            Divider()
            Button("Isometric View") { viewModel?.setNamedView(.isometric) }

            Divider()

            Button("Toggle Perspective/Orthographic") {
                viewModel?.toggleProjection()
            }
            .keyboardShortcut("P", modifiers: [.command, .shift])
        }
    }
}

/// Render mode menu commands.
struct RenderCommandsView: View {
    @FocusedObject private var viewModel: DocumentViewModel?

    var body: some View {
        Group {
            Button("Solid") {
                viewModel?.setRenderMode(.solid)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Wireframe") {
                viewModel?.setRenderMode(.wireframe)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Solid+Wireframe") {
                viewModel?.setRenderMode(.solidWireframe)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("X-Ray (Transparent)") {
                viewModel?.setRenderMode(.transparent)
            }
            .keyboardShortcut("4", modifiers: .command)
        }
    }
}
