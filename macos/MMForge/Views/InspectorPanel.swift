import SwiftUI
import simd

/// Right inspector panel for model properties and settings.
struct InspectorPanel: View {
    @ObservedObject var viewModel: DocumentViewModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Properties").tag(0)
                Text("Measure").tag(1)
                Text("Settings").tag(2)
                Text("Layers").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            Group {
                switch selectedTab {
                case 0:
                    propertiesView
                case 1:
                    measureView
                case 2:
                    settingsView
                default:
                    layersView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel("Inspector panel")
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesView: some View {
        switch viewModel.state {
        case .empty:
            inspectorEmptyState("No model loaded")
        case .loading:
            inspectorLoadingState
        case .error(let message):
            inspectorErrorState(message)
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelStatsSection
                    Divider()
                    if let index = viewModel.selectedIndex,
                       index < viewModel.nodes.count {
                        selectedNodeSection(node: viewModel.nodes[index], index: index)
                    } else {
                        noSelectionSection
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Model Stats

    private var modelStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let stats = viewModel.stats {
                LabeledContent("Nodes", value: "\(stats.nodeCount)")
                LabeledContent("Geometries", value: "\(stats.geometryCount)")
                LabeledContent("Meshes", value: "\(stats.meshCount)")
                LabeledContent("Triangles", value: formatNumber(stats.triangleCount))
                LabeledContent("Materials", value: "\(stats.materialCount)")
            }
        }
    }

    // MARK: - Selected Node

    private func selectedNodeSection(node: RenderPacketDTO.NodeInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selection")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            LabeledContent("Name", value: node.name)

            if node.parentIndex >= 0 && node.parentIndex < viewModel.nodes.count {
                LabeledContent("Parent", value: viewModel.nodes[node.parentIndex].name)
            } else if node.parentIndex < 0 {
                LabeledContent("Parent", value: "Root")
            }

            // Hierarchy info
            let children = viewModel.childrenOf(index)
            if !children.isEmpty {
                LabeledContent("Children", value: "\(children.count)")
            }

            // Depth
            let depth = nodeDepth(index)
            LabeledContent("Depth", value: "\(depth)")

            // Visibility (only meaningful for geometry nodes)
            if node.hasGeometry {
                let isHidden = viewModel.hiddenNodeIndices.contains(index)
                LabeledContent("Visible", value: isHidden ? "No" : "Yes")
            } else {
                // Assembly node: check if any descendant geometry is visible.
                let hasVisibleDescendants = nodeHasVisibleDescendants(index)
                LabeledContent("Descendants Visible", value: hasVisibleDescendants ? "Yes" : "No")
            }

            Divider()

            // Geometry info
            Text("Geometry")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            LabeledContent("Has Geometry", value: node.hasGeometry ? "Yes" : "No")

            if let geomLabel = node.geometryLabel {
                LabeledContent("Label", value: geomLabel)
            }

            if node.geometryId >= 0 {
                LabeledContent("Geometry ID", value: "\(node.geometryId)")
            }

            if node.meshIndex >= 0 {
                LabeledContent("Mesh Index", value: "\(node.meshIndex)")
            }

            // Bounding box
            if let bmin = node.boundsMin, let bmax = node.boundsMax {
                Divider()
                Text("Bounding Box")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                let size = bmax - bmin
                LabeledContent("Min", value: formatVec3(bmin))
                LabeledContent("Max", value: formatVec3(bmax))
                LabeledContent("Size", value: formatVec3(size))
                let diag = computeDiagonal(size)
                LabeledContent("Diagonal", value: String(format: "%.2f", diag))
            }

            // Color override (for geometry nodes)
            if node.hasGeometry {
                Divider()
                Text("Appearance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                ColorPicker("Color", selection: nodeColorBinding(index: index))
                    .accessibilityHint("Override the node color in the viewport")

                let hasOverride = viewModel.nodeColorOverrides[index] != nil
                if hasOverride {
                    Button("Reset Color") {
                        viewModel.setNodeColor(index, color: nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                    .accessibilityLabel("Reset color to default")
                }
            }
        }
    }

    private func nodeDepth(_ index: Int) -> Int {
        var depth = 0
        var current = index
        while current >= 0 && current < viewModel.nodes.count {
            let parent = viewModel.nodes[current].parentIndex
            if parent < 0 { break }
            depth += 1
            current = parent
            if depth > 50 { break }
        }
        return depth
    }

    /// Whether any descendant geometry of a node is visible (not hidden).
    private func nodeHasVisibleDescendants(_ index: Int) -> Bool {
        var descendants = Set<Int>()
        collectDescendants(index, into: &descendants)
        return descendants.contains {
            viewModel.nodes[$0].hasGeometry
                && !viewModel.hiddenNodeIndices.contains($0)
        }
    }

    private func collectDescendants(_ index: Int, into set: inout Set<Int>) {
        set.insert(index)
        for (i, node) in viewModel.nodes.enumerated() {
            if node.parentIndex == index {
                collectDescendants(i, into: &set)
            }
        }
    }

    // MARK: - Measure

    private var measureView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Measurement mode toggle
            HStack {
                Text("Point-to-Point")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.measurementMode },
                    set: { _ in viewModel.toggleMeasurementMode() }
                ))
                .labelsHidden()
                .accessibilityLabel("Measurement mode")
            }

            if viewModel.measurementMode {
                Text("Click two points in the viewport to measure distance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.pendingPoint != nil {
                    Text("First point set. Click second point.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            // Selected node bounding box
            if let index = viewModel.selectedIndex,
               index < viewModel.nodes.count {
                let node = viewModel.nodes[index]
                if let bmin = node.boundsMin, let bmax = node.boundsMax {
                    Text("Selection Bounds")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    let size = bmax - bmin
                    LabeledContent("Size X", value: String(format: "%.2f", size.x))
                    LabeledContent("Size Y", value: String(format: "%.2f", size.y))
                    LabeledContent("Size Z", value: String(format: "%.2f", size.z))
                    let diag = computeDiagonal(size)
                    LabeledContent("Diagonal", value: String(format: "%.2f", diag))
                }
            }

            Divider()

            // Measurement results
            HStack {
                Text("Measurements")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !viewModel.measurements.isEmpty {
                    Button("Clear All") { viewModel.clearMeasurements() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Clear all measurements")
                }
            }

            if viewModel.measurements.isEmpty {
                Text("No measurements yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(viewModel.measurements) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(String(format: "Δ %.2f", m.distance))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Button(action: { viewModel.removeMeasurement(m.id) }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove measurement")
                        }
                        HStack(spacing: 8) {
                            Text(String(format: "X: %.2f", m.deltaX))
                            Text(String(format: "Y: %.2f", m.deltaY))
                            Text(String(format: "Z: %.2f", m.deltaZ))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding(12)
    }

    private var noSelectionSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "cursorarrow.click.2")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Select a node")
                .foregroundStyle(.secondary)
            Text("Click a node in the sidebar to view its properties.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .accessibilityLabel("No node selected")
    }

    // MARK: - Settings

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Render Mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Render Mode")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    Picker("Mode", selection: $viewModel.renderMode) {
                        Text("Solid").tag(RenderMode.solid)
                        Text("Wireframe").tag(RenderMode.wireframe)
                        Text("Solid+Wire").tag(RenderMode.solidWireframe)
                        Text("Transparent").tag(RenderMode.transparent)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Render mode")
                    .onChange(of: viewModel.renderMode) { _, newMode in
                        viewModel.setRenderMode(newMode)
                    }
                }

                Divider()

                // Clipping Plane
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clipping Plane")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    Toggle("Enable Clipping", isOn: Binding(
                        get: { viewModel.clipEnabled },
                        set: { viewModel.setClipEnabled($0) }
                    ))
                    .accessibilityHint("Enable or disable the clipping plane")

                    if viewModel.clipEnabled {
                        Picker("Axis", selection: Binding(
                            get: { viewModel.clipAxis },
                            set: { viewModel.setClipAxis($0) }
                        )) {
                            Text("X").tag(0)
                            Text("Y").tag(1)
                            Text("Z").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Clipping axis")

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Distance: \(String(format: "%.1f", viewModel.clipDistance))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { viewModel.clipDistance },
                                    set: { viewModel.setClipDistance($0) }
                                ),
                                in: -100...100,
                                step: 0.5
                            )
                            .accessibilityLabel("Clipping distance")
                            .accessibilityValue("\(String(format: "%.1f", viewModel.clipDistance))")
                        }
                    }
                }

                Divider()

                Text("MMForge")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LabeledContent("Version", value: RustBridge.shared.coreVersion())
            }
            .padding(12)
        }
    }

    // MARK: - Layers

    private var layersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Layers")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                if viewModel.layerVisibility.isEmpty {
                    Text("No layers (3D model)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(viewModel.layerVisibility.keys.sorted()), id: \.self) { name in
                        HStack {
                            Circle()
                                .fill(aciSwiftUIColor(viewModel.layerColors[name] ?? 7))
                                .frame(width: 10, height: 10)
                            Text(name)
                                .font(.body)
                            Spacer()
                            Image(systemName: viewModel.layerVisibility[name] ?? true
                                  ? "eye" : "eye.slash")
                                .foregroundStyle(.secondary)
                                .onTapGesture {
                                    viewModel.toggleLayerVisibility(name)
                                }
                                .accessibilityLabel("\(name) layer \(viewModel.layerVisibility[name] ?? true ? "visible" : "hidden")")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
        }
    }

    private func aciSwiftUIColor(_ index: Int) -> Color {
        switch index {
        case 1: return .red
        case 2: return .yellow
        case 3: return .green
        case 4: return .cyan
        case 5: return .blue
        case 6: return .purple
        default: return .white
        }
    }

    // MARK: - State Helpers

    private func inspectorEmptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(message)
    }

    private var inspectorLoadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading properties")
    }

    private func inspectorErrorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Formatters

    private func formatVec3(_ v: simd_float3) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }

    /// Binding for ColorPicker that converts between SwiftUI Color and simd_float4.
    private func nodeColorBinding(index: Int) -> Binding<Color> {
        Binding(
            get: {
                if let c = self.viewModel.nodeColorOverrides[index] {
                    return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                }
                return Color(red: 0.7, green: 0.7, blue: 0.72) // default grey
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                let color = simd_float4(Float(r), Float(g), Float(b), Float(a))
                self.viewModel.setNodeColor(index, color: color)
            }
        )
    }

    private func computeDiagonal(_ size: simd_float3) -> Float {
        let sx = size.x * size.x
        let sy = size.y * size.y
        let sz = size.z * size.z
        return sqrt(sx + sy + sz)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
