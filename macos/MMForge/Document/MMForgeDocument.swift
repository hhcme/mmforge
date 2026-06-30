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

    private var rustDoc: OpaquePointer?
    private var renderer: MetalRenderer?

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func setRenderer(_ renderer: MetalRenderer) {
        self.renderer = renderer
    }

    func parseFile(data: Data) {
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
                switch result {
                case .success(let (doc, dto)):
                    self.rustDoc = doc
                    self.uploadToRenderer(dto: dto)
                    self.nodeNames = dto.nodeNames
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
        guard let renderer else { return }
        renderer.clearMeshes()
        for mesh in dto.meshes {
            renderer.upload(
                positions: mesh.positions,
                normals: mesh.normals,
                vertexCount: mesh.vertexCount,
                indices: mesh.indices,
                indexCount: mesh.indexCount
            )
        }
        renderer.setSceneBounds(min: dto.sceneBoundsMin, max: dto.sceneBoundsMax)
    }

    func fitToView() {
        renderer?.fitToView()
    }

    deinit {
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
        }
    }
}
