import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - Supported file types

extension UTType {
    static let step = UTType("com.mmforge.step")!
}

// MARK: - App preferences (persisted via UserDefaults)

/// Global viewer preferences, persisted across sessions.
struct AppPreferences {
    @AppStorage("exportFormat") static var exportFormat: String = "png"
    @AppStorage("exportScale") static var exportScale: Double = 1.0
}

// MARK: - Measurement

/// A point-to-point measurement in world coordinates.
struct Measurement: Identifiable {
    let id = UUID()
    let start: simd_float3
    let end: simd_float3

    /// Euclidean distance between start and end.
    var distance: Float {
        let d = end - start
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    }

    /// Per-axis deltas.
    var deltaX: Float { end.x - start.x }
    var deltaY: Float { end.y - start.y }
    var deltaZ: Float { end.z - start.z }
}

/// The document type for MMForge model files.
struct MMForgeDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.step, .data]
    }

    /// Raw file data (passed to Rust bridge for parsing).
    var fileData: Data

    init(fileData: Data = Data()) {
        self.fileData = fileData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.fileData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: fileData)
    }
}

// MARK: - Document state

enum DocumentState: Equatable {
    case empty
    case loading
    case loaded(triangleCount: Int, meshCount: Int, nodeCount: Int)
    case error(String)
}

// MARK: - Document view model

/// Manages async parsing and Metal state for a document.
@MainActor
final class DocumentViewModel: ObservableObject {
    @Published var state: DocumentState = .empty
    @Published var nodeNames: [String] = []
    @Published var nodes: [RenderPacketDTO.NodeInfo] = []
    @Published var stats: RenderPacketDTO.ModelStats?
    @Published var selectedIndex: Int?
    @Published var hiddenNodeIndices: Set<Int> = []
    @Published var renderMode: RenderMode = .solid
    @Published var clipEnabled: Bool = false
    @Published var clipAxis: Int = 2  // 0=X, 1=Y, 2=Z
    @Published var clipDistance: Float = 0.0

    // Sidebar tree state
    @Published var expandedIndices: Set<Int> = []
    @Published var searchText: String = ""

    // Measurement state
    @Published var measurementMode: Bool = false
    @Published var measurements: [Measurement] = []
    @Published var pendingPoint: simd_float3?

    private var rustDoc: OpaquePointer?
    private var renderer: MetalRenderer?
    /// Stores DTO from async parse when renderer isn't ready yet.
    private var pendingDTO: RenderPacketDTO?
    /// Increments on each parseFile call; stale async results are discarded.
    private var parseGeneration: UInt64 = 0

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func setRenderer(_ renderer: MetalRenderer) {
        self.renderer = renderer
        // Sync current state to the new renderer.
        renderer.renderMode = renderMode
        updateClipPlane()
        // Upload any pending mesh data that arrived before the renderer.
        if let dto = pendingDTO {
            pendingDTO = nil
            uploadToRenderer(dto: dto)
        }
    }

    /// Free the current MmfDocument and clear associated state.
    private func freeCurrentDocument() {
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
            rustDoc = nil
        }
        pendingDTO = nil
        renderer?.clearMeshes()
        renderer?.clearOverlay()
        nodeNames = []
        nodes = []
        stats = nil
        selectedIndex = nil
        hiddenNodeIndices = []
        expandedIndices = []
        searchText = ""
        measurementMode = false
        measurements = []
        pendingPoint = nil
    }

    func parseFile(data: Data) {
        // Increment generation FIRST — any in-flight async parse from a
        // previous call will see a mismatch and discard its result.
        parseGeneration += 1
        let generation = parseGeneration

        // Clean up previous state (Rust doc, meshes, overlay, etc.).
        freeCurrentDocument()

        guard !data.isEmpty else {
            state = .empty
            return
        }

        state = .loading

        // Write to temp file (Rust bridge needs a file path).
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmforge_\(UUID().uuidString).step")
        do {
            try data.write(to: tmpURL)
        } catch {
            state = .error("Failed to write temp file: \(error.localizedDescription)")
            return
        }

        // Parse on background thread.
        let path = tmpURL.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try RustBridge.shared.parseFile(at: path) }

            // Clean up temp file.
            try? FileManager.default.removeItem(at: tmpURL)

            DispatchQueue.main.async {
                guard let self else { return }
                // Discard stale result if a newer parse was started.
                guard generation == self.parseGeneration else {
                    // Free the document we just parsed — it's been superseded.
                    if case .success(let (doc, _)) = result {
                        RustBridge.shared.freeDocument(doc)
                    }
                    return
                }
                switch result {
                case .success(let (doc, dto)):
                    // Free any previous document (should already be nil,
                    // but guard against edge cases).
                    if let oldDoc = self.rustDoc {
                        RustBridge.shared.freeDocument(oldDoc)
                    }
                    self.rustDoc = doc
                    self.uploadToRenderer(dto: dto)
                    self.nodeNames = dto.nodeNames
                    self.nodes = dto.nodes
                    self.stats = dto.stats
                    // Expand root by default.
                    self.expandedIndices = [0]
                    self.state = .loaded(
                        triangleCount: dto.triangleCount,
                        meshCount: dto.meshes.count,
                        nodeCount: dto.nodeNames.count
                    )
                case .failure(let error):
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func uploadToRenderer(dto: RenderPacketDTO) {
        guard let renderer else {
            pendingDTO = dto
            return
        }
        renderer.clearMeshes()

        // Build geometryId → nodeIndex mapping from NodeInfo.
        // This is the authoritative key — geometryId in NodeInfo matches
        // geometryId in Mesh because both come from the same Rust model.
        var geomIdToNodeIdx = [Int: Int]()
        for (nodeIdx, node) in dto.nodes.enumerated() {
            if node.geometryId >= 0 {
                geomIdToNodeIdx[node.geometryId] = nodeIdx
            }
        }

        // Upload each mesh, using mesh.geometryId to find the owning node.
        for mesh in dto.meshes {
            let nodeIdx = geomIdToNodeIdx[mesh.geometryId] ?? -1
            let node = nodeIdx >= 0 && nodeIdx < dto.nodes.count ? dto.nodes[nodeIdx] : nil
            renderer.upload(
                positions: mesh.positions,
                normals: mesh.normals,
                vertexCount: mesh.vertexCount,
                indices: mesh.indices,
                indexCount: mesh.indexCount,
                nodeIndex: nodeIdx,
                boundsMin: node?.boundsMin ?? .zero,
                boundsMax: node?.boundsMax ?? .zero
            )
        }
        renderer.setSceneBounds(min: dto.sceneBoundsMin, max: dto.sceneBoundsMax)
    }

    func fitToView() {
        renderer?.fitToView()
    }

    // MARK: - Camera / View

    func setNamedView(_ view: MetalRenderer.NamedView) {
        renderer?.setNamedView(view)
    }

    func toggleProjection() {
        renderer?.toggleProjection()
    }

    func resetCamera() {
        renderer?.resetCamera()
    }

    // MARK: - Selection

    func selectNode(_ index: Int?) {
        selectedIndex = index
        renderer?.setSelectedNode(index)
    }

    // MARK: - Visibility

    func toggleNodeVisibility(_ index: Int) {
        if hiddenNodeIndices.contains(index) {
            hiddenNodeIndices.remove(index)
            renderer?.setNodeVisible(index, visible: true)
        } else {
            hiddenNodeIndices.insert(index)
            renderer?.setNodeVisible(index, visible: false)
        }
    }

    func setAllNodesVisible() {
        hiddenNodeIndices.removeAll()
        renderer?.setHiddenNodes([])
    }

    /// Hide the selected node and all its descendant geometry.
    /// Works for both leaf geometry nodes and assembly nodes.
    func hideSelectedNode() {
        guard let sel = selectedIndex else { return }
        var descendants = Set<Int>()
        collectDescendants(sel, into: &descendants)
        // Hide all geometry nodes in the subtree.
        for idx in descendants where nodes[idx].hasGeometry {
            hiddenNodeIndices.insert(idx)
        }
        renderer?.setHiddenNodes(hiddenNodeIndices)
    }

    /// Whether the selected node (or its descendants) has any geometry
    /// that can be hidden.
    var selectedHasHideableGeometry: Bool {
        guard let sel = selectedIndex else { return false }
        var descendants = Set<Int>()
        collectDescendants(sel, into: &descendants)
        return descendants.contains { nodes[$0].hasGeometry }
    }

    /// Hide all geometry nodes.
    func hideAllNodes() {
        let geomIndices = nodes.enumerated()
            .filter { $0.element.hasGeometry }
            .map { $0.offset }
        hiddenNodeIndices = Set(geomIndices)
        renderer?.setHiddenNodes(hiddenNodeIndices)
    }

    /// Isolate the selected node: show it and all its descendants,
    /// hide all other geometry nodes.
    ///
    /// Works with both assembly nodes (shows all descendant geometry)
    /// and leaf geometry nodes (shows just that node).
    /// No-op if the selected node has no geometry descendants.
    func isolateSelectedNode() {
        guard let sel = selectedIndex, selectedHasHideableGeometry else { return }

        // Collect the selected node and all its descendant indices.
        var keepVisible = Set<Int>()
        collectDescendants(sel, into: &keepVisible)

        // Hide all geometry nodes NOT in the keep-visible set.
        var hidden = Set<Int>()
        for (i, node) in nodes.enumerated() {
            if node.hasGeometry && !keepVisible.contains(i) {
                hidden.insert(i)
            }
        }
        hiddenNodeIndices = hidden
        renderer?.setHiddenNodes(hiddenNodeIndices)
    }

    /// Recursively collect a node and all its descendants.
    private func collectDescendants(_ index: Int, into set: inout Set<Int>) {
        set.insert(index)
        for (i, node) in nodes.enumerated() {
            if node.parentIndex == index {
                collectDescendants(i, into: &set)
            }
        }
    }

    /// Hide all nodes except the selected one (alias for toolbar).
    func hideOtherNodes() {
        isolateSelectedNode()
    }

    // MARK: - Measurement

    /// Toggle measurement mode.  When active, viewport clicks pick
    /// world-space points instead of nodes.
    func toggleMeasurementMode() {
        measurementMode.toggle()
        if !measurementMode { pendingPoint = nil }
        syncOverlay()
    }

    /// Record a measurement point.  First click stores pending point,
    /// second click creates a Measurement.
    func addMeasurementPoint(_ point: simd_float3) {
        if let start = pendingPoint {
            measurements.append(Measurement(start: start, end: point))
            pendingPoint = nil
        } else {
            pendingPoint = point
        }
        syncOverlay()
    }

    /// Cancel the current pending measurement.
    func cancelMeasurement() {
        pendingPoint = nil
        syncOverlay()
    }

    /// Clear all measurements.
    func clearMeasurements() {
        measurements.removeAll()
        pendingPoint = nil
        syncOverlay()
    }

    /// Remove a single measurement by ID.
    func removeMeasurement(_ id: UUID) {
        measurements.removeAll { $0.id == id }
        syncOverlay()
    }

    /// Sync measurement data to the Metal renderer overlay.
    private func syncOverlay() {
        guard let renderer else { return }
        if measurements.isEmpty && pendingPoint == nil {
            renderer.clearOverlay()
        } else {
            let overlayData = measurements.map { (start: $0.start, end: $0.end) }
            renderer.updateOverlay(measurements: overlayData, pendingPoint: pendingPoint)
        }
    }

    // MARK: - Image export

    /// Error message for failed export (shown as alert in UI).
    @Published var exportError: String?

    /// Capture the current viewport and present NSSavePanel for export.
    func exportImage() {
        guard let renderer else {
            exportError = "No renderer available."
            return
        }
        guard let image = renderer.captureImage() else {
            exportError = "Failed to capture viewport — no drawable available."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "mmforge_view.\(AppPreferences.exportFormat)"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.saveImage(image, to: url)
        }
    }

    private func saveImage(_ image: NSImage, to url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            exportError = "Failed to encode image data."
            return
        }

        let isPNG = url.pathExtension.lowercased() == "png"
        guard let imageData = isPNG
            ? bitmapRep.representation(using: .png, properties: [:])
            : bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else {
            exportError = "Failed to encode image as \(isPNG ? "PNG" : "JPEG")."
            return
        }

        do {
            try imageData.write(to: url)
        } catch {
            exportError = "Failed to write image: \(error.localizedDescription)"
        }
    }

    // MARK: - Tree expand/collapse

    /// Toggle expand/collapse for a node.
    func toggleExpanded(_ index: Int) {
        if expandedIndices.contains(index) {
            expandedIndices.remove(index)
        } else {
            expandedIndices.insert(index)
        }
    }

    /// Expand all nodes.
    func expandAll() {
        expandedIndices = Set(nodes.indices)
    }

    /// Collapse all nodes.
    func collapseAll() {
        expandedIndices = []
    }

    /// Whether a node's children should be visible in the tree.
    func isNodeVisibleInTree(_ index: Int) -> Bool {
        // Root is always visible.
        let node = nodes[index]
        guard node.parentIndex >= 0 else { return true }
        // Check if all ancestors are expanded.
        var current = node.parentIndex
        while current >= 0 && current < nodes.count {
            if !expandedIndices.contains(current) { return false }
            current = nodes[current].parentIndex
        }
        return true
    }

    /// Whether a node passes the search filter.
    func matchesSearch(_ index: Int) -> Bool {
        guard !searchText.isEmpty else { return true }
        let node = nodes[index]
        if node.name.localizedCaseInsensitiveContains(searchText) {
            return true
        }
        if let label = node.geometryLabel,
           label.localizedCaseInsensitiveContains(searchText) {
            return true
        }
        return false
    }

    /// Indices of visible (expanded + matching search) nodes for the sidebar.
    var visibleNodeIndices: [Int] {
        guard !nodes.isEmpty else { return [] }
        if searchText.isEmpty {
            // No search filter — show expanded/collapsed tree.
            return nodes.indices.filter { isNodeVisibleInTree($0) }
        } else {
            // Search mode — show matching nodes and their ancestors.
            var visible = Set<Int>()
            for i in nodes.indices where matchesSearch(i) {
                visible.insert(i)
                // Also show all ancestors.
                var parent = nodes[i].parentIndex
                while parent >= 0 && parent < nodes.count {
                    visible.insert(parent)
                    parent = nodes[parent].parentIndex
                }
            }
            return nodes.indices.filter { visible.contains($0) }
        }
    }

    /// Children indices of a given node.
    func childrenOf(_ index: Int) -> [Int] {
        nodes.indices.filter { nodes[$0].parentIndex == index }
    }

    /// Whether a node has any children.
    func hasChildren(_ index: Int) -> Bool {
        nodes.contains { $0.parentIndex == index }
    }

    // MARK: - Render Mode

    func setRenderMode(_ mode: RenderMode) {
        renderMode = mode
        renderer?.renderMode = mode
    }

    // MARK: - Clipping Plane

    func setClipEnabled(_ enabled: Bool) {
        clipEnabled = enabled
        updateClipPlane()
    }

    func setClipAxis(_ axis: Int) {
        clipAxis = axis
        updateClipPlane()
    }

    func setClipDistance(_ distance: Float) {
        clipDistance = distance
        updateClipPlane()
    }

    func toggleClipping() {
        clipEnabled.toggle()
        updateClipPlane()
    }

    private func updateClipPlane() {
        guard let renderer else { return }
        if clipEnabled {
            var normal: simd_float3
            switch clipAxis {
            case 0: normal = simd_float3(1, 0, 0)
            case 1: normal = simd_float3(0, 1, 0)
            default: normal = simd_float3(0, 0, 1)
            }
            renderer.clipPlane = simd_float4(normal.x, normal.y, normal.z, clipDistance)
        } else {
            renderer.clipPlane = simd_float4(0, 0, 0, -999999)
        }
    }

    deinit {
        // Nonisolated cleanup — safe because deinit runs on the owning thread.
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
        }
    }
}
