import SwiftUI
import UniformTypeIdentifiers

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
        // Each mesh in dto.meshes corresponds to a node with geometry.
        // Map mesh index → node index by matching geometry nodes in order.
        var meshNodeIndices: [Int] = []
        for (i, node) in dto.nodes.enumerated() {
            if node.hasGeometry {
                meshNodeIndices.append(i)
            }
        }
        for (i, mesh) in dto.meshes.enumerated() {
            let nodeIdx = i < meshNodeIndices.count ? meshNodeIndices[i] : i
            let node = nodeIdx < dto.nodes.count ? dto.nodes[nodeIdx] : nil
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

    deinit {
        // Nonisolated cleanup — safe because deinit runs on the owning thread.
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
        }
    }
}
