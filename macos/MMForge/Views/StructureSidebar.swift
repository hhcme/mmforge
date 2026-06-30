import SwiftUI

/// Left sidebar showing the model's scene tree / product structure.
struct StructureSidebar: View {
    let nodeNames: [String]
    @State private var selectedNode: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Structure")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if nodeNames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No structure")
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedNode) {
                    Section("Product Structure") {
                        ForEach(Array(nodeNames.enumerated()), id: \.offset) { i, name in
                            Label(name, systemImage: i == 0 ? "folder" : "cube")
                                .tag(name)
                                .padding(.leading, i == 0 ? 0 : 12)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
