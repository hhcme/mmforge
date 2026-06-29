import SwiftUI

/// Left sidebar showing the model's scene tree / product structure.
struct StructureSidebar: View {
    @State private var selectedNode: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Structure")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Placeholder tree
            List(selection: $selectedNode) {
                Section("Product Structure") {
                    Label("Assembly", systemImage: "folder")
                        .tag("assembly")
                    Label("Part 1", systemImage: "cube")
                        .tag("part1")
                        .padding(.leading, 12)
                    Label("Part 2", systemImage: "cube")
                        .tag("part2")
                        .padding(.leading, 12)
                }
            }
            .listStyle(.sidebar)
        }
    }
}
