import SwiftUI

/// Container for the 3D/2D viewport.  Wraps the Metal view in Phase 1.
struct ViewportContainer: View {
    var body: some View {
        ZStack {
            // Background
            Color(nsColor: .controlBackgroundColor)

            // Empty state (shown when no document is loaded)
            EmptyStateView()
        }
    }
}

/// The empty state shown when no model is loaded.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Model Loaded")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Open a STEP, glTF, STL, or DXF file to begin.")
                .font(.body)
                .foregroundStyle(.tertiary)

            Button("Open File…") {
                openFilePanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Phase 1: pass to Rust bridge for parsing.
                print("Open: \(url.path)")
            }
        }
    }
}
