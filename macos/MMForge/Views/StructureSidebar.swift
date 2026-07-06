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
                    .onChange(of: viewModel.searchText) { _, _ in
                        debouncedRefresh()
                    }
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
                        if viewModel.selectedHasHideableGeometry {
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

    /// Selection binding that syncs sidebar selection to the Metal renderer.
    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { viewModel.selectedIndex },
            set: { viewModel.selectNode($0) }
        )
    }

    /// SwiftUI List on macOS uses NSTableView under the hood, which is rendered
    /// lazily (cell reuse).  The prior ScrollView+LazyVStack was actually a
    /// regression: it lost keyboard navigation, type-to-select, and VoiceOver
    /// row navigation that List provides for free.
    private var nodeList: some View {
        List(selection: selectionBinding) {
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
        .accessibilityLabel("Product structure tree")
    }

    private func nodeRow(index: Int) -> some View {
        let node = viewModel.nodes[index]
        let hasKids = viewModel.hasChildren(index)
        let isExpanded = viewModel.expandedIndices.contains(index)

        return HStack(spacing: 4) {
            // Indentation
            Spacer()
                .frame(width: CGFloat(indentLevel(for: index)) * 16)

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
            let isAssembly = !node.hasGeometry && hasKids && node.parentIndex >= 0
            Image(systemName: nodeIcon(node: node))
                .foregroundStyle(
                    node.hasGeometry ? Color.accentColor :
                    isAssembly ? Color.orange : Color.secondary
                )
                .frame(width: 16)

            // Name
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(node.hasGeometry ? .regular :
                            isAssembly ? .semibold : .regular)

            // Assembly badge
            if isAssembly {
                Text("\(viewModel.childrenOf(index).count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12)))
            }

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
        .contextMenu { nodeContextMenu(index: index) }
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
        } else if isAssemblyNode(node) {
            return "rectangle.3.group"
        } else {
            return "folder"
        }
    }

    private func isAssemblyNode(_ node: RenderPacketDTO.NodeInfo) -> Bool {
        !node.hasGeometry
    }

    /// Context menu for a node row.
    @ViewBuilder
    private func nodeContextMenu(index: Int) -> some View {
        let node = viewModel.nodes[index]
        let hasKids = viewModel.hasChildren(index)

        Group {
            if node.hasGeometry {
                Button(viewModel.hiddenNodeIndices.contains(index)
                       ? "Show Part" : "Hide Part") {
                    viewModel.toggleNodeVisibility(index)
                }

                Divider()
                Button("Show Only This Part") {
                    viewModel.isolateNode(index)
                }
                Button("Hide Other Parts") {
                    viewModel.hideAllExcept(index)
                }
            }

            if hasKids {
                Divider()
                Button("Expand All Children") {
                    viewModel.expandDescendants(index)
                }
                Button("Collapse All Children") {
                    viewModel.collapseDescendants(index)
                }
            }

            Divider()

            if node.hasGeometry {
                Button("Select in Viewport") {
                    viewModel.selectNode(index)
                }
                .disabled(viewModel.selectedIndex == index)

                if let _ = viewModel.nodeColorOverrides[index] {
                    Button("Reset Color") {
                        viewModel.setNodeColor(index, color: nil)
                    }
                }
            }
        }
    }

    private func indentLevel(for index: Int) -> Int {
        viewModel.nodeDepth(index)
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

    // MARK: - Search debounce

    @State private var debounceTask: Task<Void, Never>?

    private func debouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            viewModel.refreshVisibleIndices()
        }
    }
}
