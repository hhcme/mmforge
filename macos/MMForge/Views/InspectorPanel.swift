import SwiftUI
import simd

/// Right inspector panel for model properties and settings.
struct InspectorPanel: View {
    @ObservedObject var viewModel: DocumentViewModel
    @State private var selectedTab = 0
    @State private var annotationText: String = ""

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
        DisclosureGroup(isExpanded: .constant(true)) {
            VStack(alignment: .leading, spacing: 6) {
                if let stats = viewModel.stats {
                    LabeledContent("Nodes", value: "\(stats.nodeCount)")
                    LabeledContent("Geometries", value: "\(stats.geometryCount)")
                    LabeledContent("Meshes", value: "\(stats.meshCount)")
                    LabeledContent("Triangles", value: formatNumber(stats.triangleCount))
                    LabeledContent("Materials", value: "\(stats.materialCount)")
                }
            }
            .font(.callout)
        } label: {
            Text("Model")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - Selected Node

    private func selectedNodeSection(node: RenderPacketDTO.NodeInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Name", value: node.name)

                    if node.parentIndex >= 0 && node.parentIndex < viewModel.nodes.count {
                        LabeledContent("Parent", value: viewModel.nodes[node.parentIndex].name)
                    } else if node.parentIndex < 0 {
                        LabeledContent("Parent", value: "Root")
                    }

                    let children = viewModel.childrenOf(index)
                    if !children.isEmpty {
                        LabeledContent("Children", value: "\(children.count)")
                    }

                    let depth = nodeDepth(index)
                    LabeledContent("Depth", value: "\(depth)")

                    if node.hasGeometry {
                        let isHidden = viewModel.hiddenNodeIndices.contains(index)
                        LabeledContent("Visible", value: isHidden ? "No" : "Yes")
                    } else {
                        let hasVisibleDescendants = nodeHasVisibleDescendants(index)
                        LabeledContent("Descendants Visible", value: hasVisibleDescendants ? "Yes" : "No")
                    }
                }
                .font(.callout)
            } label: {
                Text("Node")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }

            Divider()

            DisclosureGroup(isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: 6) {
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
                }
                .font(.callout)
            } label: {
                Text("Geometry")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }

            if let bmin = node.boundsMin, let bmax = node.boundsMax {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        let size = bmax - bmin
                        LabeledContent("Min", value: formatVec3(bmin))
                        LabeledContent("Max", value: formatVec3(bmax))
                        LabeledContent("Size", value: formatVec3(size))
                        let diag = computeDiagonal(size)
                        LabeledContent("Diagonal", value: String(format: "%.2f", diag))
                    }
                    .font(.callout)
                } label: {
                    Text("Bounding Box")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            if node.hasGeometry {
                Divider()
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 8) {
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
                } label: {
                    Text("Appearance")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    private func nodeDepth(_ index: Int) -> Int {
        viewModel.nodeDepth(index)
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
        for child in viewModel.childrenOf(index) {
            collectDescendants(child, into: &set)
        }
    }

    // MARK: - Measure

    private var measureView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Measurement mode toggle
                HStack {
                    Text("Measurement")
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
                    // Measurement type picker (2D only).
                    if viewModel.is2DDrawing {
                        Picker("Type", selection: $viewModel.measurementType) {
                            ForEach(MeasurementType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Measurement type")

                        Toggle("Snap to entity", isOn: $viewModel.snapEnabled)
                            .font(.caption)
                    }

                    Text(viewModel.measurementType.instruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.is2DDrawing {
                        if viewModel.pendingAnnotationPoint != nil {
                            Text("First point set. Click second point.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if viewModel.measurementType == .area && !viewModel.pendingPolygonPoints.isEmpty {
                            Text("\(viewModel.pendingPolygonPoints.count) vertices. Click near first to close.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if viewModel.pendingPoint != nil {
                        Text("First point set. Click second point.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Annotation tools (2D only)
                if viewModel.is2DDrawing {
                    Divider()

                    Text("Annotation Tools")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    Picker("Tool", selection: $viewModel.activeAnnotationTool) {
                        Text("None").tag(nil as AnnotationTool?)
                        ForEach(AnnotationTool.allCases, id: \.self) { tool in
                            Text(tool.rawValue).tag(tool as AnnotationTool?)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Annotation tool")

                    if let tool = viewModel.activeAnnotationTool {
                        Text(tool.instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if tool == .text {
                            TextField("Text content", text: $viewModel.annotationToolText)
                                .textFieldStyle(.roundedBorder)
                        }

                        if viewModel.pendingAnnotationPoint != nil && tool.clickCount > 1 {
                            Text("First point set. Click second point.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Divider()

                // Selected node bounding box (3D only)
                if !viewModel.is2DDrawing,
                   let index = viewModel.selectedIndex,
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

                // 3D Measurement results
                if !viewModel.is2DDrawing {
                    measurementResultsSection
                }

                // 2D Annotations
                if viewModel.is2DDrawing {
                    annotationResultsSection
                }
            }
            .padding(12)
        }
    }

    private var measurementResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    }

    private var annotationResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !viewModel.annotations.isEmpty {
                    Button("Clear All") { viewModel.clearAnnotations() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Clear all annotations")
                }
            }

            if viewModel.annotations.isEmpty {
                Text("No annotations yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(viewModel.annotations) { ann in
                    HStack {
                        Circle()
                            .fill(Color(ann.color))
                            .frame(width: 8, height: 8)
                        annotationLabel(ann)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(action: { viewModel.removeAnnotation(ann.id) }) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove annotation")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func annotationLabel(_ ann: Annotation) -> some View {
        switch ann.kind {
        case .measurement(let start, let end):
            let dist = Geometry2D.distance(start, end)
            Text(String(format: "↔ %.2f", dist))
                .foregroundStyle(.primary)
        case .angleMeasurement(let vertex, let p1, let p2):
            let angle = Geometry2D.angleDegrees(vertex: vertex, p1: p1, p2: p2)
            Text(String(format: "∠ %.1f°", angle))
                .foregroundStyle(.primary)
        case .areaMeasurement(let points):
            let area = Geometry2D.area(points)
            Text(String(format: "⌂ %.2f", area))
                .foregroundStyle(.primary)
        case .dimension(let start, let end, _):
            let dist = Geometry2D.distance(start, end)
            Text(String(format: "⊞ %.2f", dist))
                .foregroundStyle(.primary)
        case .textAnnotation(_, let text, _):
            Text("Aa \(text)")
                .foregroundStyle(.primary)
        case .arrowAnnotation(_, _, let text):
            Text("→ \(text ?? "")")
                .foregroundStyle(.primary)
        }
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
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 8) {
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
                } label: {
                    Text("Render Mode")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }

                Divider()

                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 8) {
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
                } label: {
                    Text("Clipping Plane")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }

                Divider()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Version", value: RustBridge.shared.coreVersion())
                        if let stats = viewModel.stats {
                            LabeledContent("Memory", value: formatBytes(estimatedMemory(stats)))
                        }
                    }
                    .font(.callout)
                } label: {
                    Text("About")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .padding(12)
        }
    }

    private func estimatedMemory(_ stats: RenderPacketDTO.ModelStats) -> Int {
        stats.triangleCount * 3 * (6 * 4 + 3 * 4) + stats.nodeCount * 256
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
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
                // Convert to sRGB so getRed always succeeds regardless of source color space.
                let nsColor = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
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
