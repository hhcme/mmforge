import SwiftUI

/// Left sidebar showing the model's scene tree / product structure.
struct StructureSidebar: View {
    @ObservedObject var viewModel: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Structure")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.nodes.count) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch viewModel.state {
            case .empty:
                sidebarEmptyState
            case .loading:
                sidebarLoadingState
            case .error(let message):
                sidebarErrorState(message)
            case .loaded:
                if viewModel.nodes.isEmpty {
                    sidebarEmptyState
                } else {
                    nodeList
                }
            }
        }
        .accessibilityLabel("Structure sidebar")
    }

    // MARK: - States

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No structure")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No structure data available")
    }

    private var sidebarLoadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading structure")
    }

    private func sidebarErrorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Error")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Node list

    private var nodeList: some View {
        List(selection: $viewModel.selectedIndex) {
            Section("Product Structure") {
                ForEach(Array(viewModel.nodes.enumerated()), id: \.offset) { index, node in
                    nodeRow(node: node, index: index)
                        .tag(index)
                        .accessibilityLabel(nodeAccessibilityLabel(node: node, index: index))
                        .accessibilityHint("Select to view properties in inspector")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func nodeRow(node: RenderPacketDTO.NodeInfo, index: Int) -> some View {
        HStack(spacing: 4) {
            // Indentation based on parent relationship
            if node.parentIndex >= 0 {
                Spacer()
                    .frame(width: CGFloat(indentLevel(for: index)) * 12)
            }

            // Icon
            Image(systemName: nodeIcon(node: node))
                .foregroundStyle(node.hasGeometry ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            // Name
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Geometry indicator
            if node.hasGeometry {
                Image(systemName: "cube")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func nodeIcon(node: RenderPacketDTO.NodeInfo) -> String {
        if node.parentIndex < 0 {
            return "folder.fill"  // Root assembly
        } else if node.hasGeometry {
            return "cube"  // Part with geometry
        } else {
            return "folder"  // Sub-assembly
        }
    }

    private func indentLevel(for index: Int) -> Int {
        var level = 0
        var current = index
        while current >= 0 && current < viewModel.nodes.count {
            let parent = viewModel.nodes[current].parentIndex
            if parent < 0 { break }
            level += 1
            current = parent
            if level > 10 { break }  // Safety limit
        }
        return level
    }

    private func nodeAccessibilityLabel(node: RenderPacketDTO.NodeInfo, index: Int) -> String {
        var label = node.name
        if node.hasGeometry {
            label += ", has geometry"
        }
        if let geomLabel = node.geometryLabel {
            label += ", \(geomLabel)"
        }
        if node.parentIndex < 0 {
            label += ", root node"
        }
        return label
    }
}
