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

            // Search bar
            if case .loaded = viewModel.state {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search nodes…", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .accessibilityLabel("Search nodes")
                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

                // Bulk actions
                HStack(spacing: 8) {
                    Button(action: { viewModel.expandAll() }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption)
                    }
                    .help("Expand all")
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand all nodes")

                    Button(action: { viewModel.collapseAll() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    .help("Collapse all")
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse all nodes")

                    Spacer()

                    Menu {
                        Button("Show All") { viewModel.setAllNodesVisible() }
                        Button("Hide All") { viewModel.hideAllNodes() }
                        if viewModel.selectedIndex != nil {
                            Divider()
                            Button("Isolate Selection") { viewModel.isolateSelectedNode() }
                            Button("Hide Selection") { viewModel.hideSelectedNode() }
                        }
                    } label: {
                        Image(systemName: "eye")
                            .font(.caption)
                    }
                    .help("Visibility actions")
                    .accessibilityLabel("Visibility actions")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

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
                ForEach(viewModel.visibleNodeIndices, id: \.self) { index in
                    nodeRow(index: index)
                        .tag(index)
                        .listRowBackground(
                            viewModel.selectedIndex == index
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .accessibilityLabel(nodeAccessibilityLabel(index: index))
                        .accessibilityValue(
                            viewModel.hiddenNodeIndices.contains(index) ? "hidden" : "visible"
                        )
                        .accessibilityHint("Select to view properties in inspector")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func nodeRow(index: Int) -> some View {
        let node = viewModel.nodes[index]
        let hasKids = viewModel.hasChildren(index)
        let isExpanded = viewModel.expandedIndices.contains(index)

        return HStack(spacing: 4) {
            // Indentation
            Spacer()
                .frame(width: CGFloat(indentLevel(for: index)) * 12)

            // Disclosure triangle (if has children)
            if hasKids {
                Button(action: { viewModel.toggleExpanded(index) }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 12)
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            } else {
                Spacer().frame(width: 12)
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

            // Visibility toggle (for geometry nodes)
            if node.hasGeometry {
                Button(action: { viewModel.toggleNodeVisibility(index) }) {
                    Image(systemName: viewModel.hiddenNodeIndices.contains(index)
                          ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(viewModel.hiddenNodeIndices.contains(index)
                                         ? .secondary : .tertiary)
                }
                .buttonStyle(.plain)
                .help(viewModel.hiddenNodeIndices.contains(index)
                      ? "Show this part" : "Hide this part")
                .accessibilityLabel(viewModel.hiddenNodeIndices.contains(index)
                                    ? "Show \(node.name)" : "Hide \(node.name)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.hasGeometry {
                viewModel.toggleNodeVisibility(index)
            } else if hasKids {
                viewModel.toggleExpanded(index)
            }
        }
    }

    private func nodeIcon(node: RenderPacketDTO.NodeInfo) -> String {
        if node.parentIndex < 0 {
            return "folder.fill"
        } else if node.hasGeometry {
            return "cube"
        } else {
            return "folder"
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
            if level > 10 { break }
        }
        return level
    }

    private func nodeAccessibilityLabel(index: Int) -> String {
        let node = viewModel.nodes[index]
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
        if viewModel.hasChildren(index) {
            let expanded = viewModel.expandedIndices.contains(index)
            label += expanded ? ", expanded" : ", collapsed"
        }
        return label
    }
}
