import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - Supported file types

extension UTType {
    static let step = UTType("com.mmforge.step")!
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
        nodeNames = []
        nodes = []
        stats = nil
        selectedIndex = nil
        hiddenNodeIndices = []
        expandedIndices = []
        searchText = ""
    }

    func parseFile(data: Data) {
        guard !data.isEmpty else {
            state = .empty
            return
        }

        // Free previous document (MmfDocument + meshes + CStrings).
        freeCurrentDocument()

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
        parseGeneration += 1
        let generation = parseGeneration

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

    func hideSelectedNode() {
        if let idx = selectedIndex {
            toggleNodeVisibility(idx)
        }
    }

    /// Hide all geometry nodes.
    func hideAllNodes() {
        let geomIndices = nodes.enumerated()
            .filter { $0.element.hasGeometry }
            .map { $0.offset }
        hiddenNodeIndices = Set(geomIndices)
        renderer?.setHiddenNodes(hiddenNodeIndices)
    }

    /// Hide all nodes except the selected one.
    func isolateSelectedNode() {
        guard let sel = selectedIndex, nodes[sel].hasGeometry else { return }
        let geomIndices = nodes.enumerated()
            .filter { $0.element.hasGeometry && $0.offset != sel }
            .map { $0.offset }
        hiddenNodeIndices = Set(geomIndices)
        renderer?.setHiddenNodes(hiddenNodeIndices)
    }

    /// Hide all nodes except the selected one (alias for toolbar).
    func hideOtherNodes() {
        isolateSelectedNode()
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
        return node.name.localizedCaseInsensitiveContains(searchText)
            ?? (node.geometryLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
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
