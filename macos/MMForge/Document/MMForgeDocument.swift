import SwiftUI
import UniformTypeIdentifiers

// MARK: - Supported file types

// TODO(Phase 1): Replace `.data` with explicit UTTypes for each supported format:
//   - UTType("com.mmforge.step")  or UTType("public.step")  for STEP (.stp, .step)
//   - UTType("com.mmforge.gltf")  or UTType("public.glTF")  for glTF (.gltf, .glb)
//   - UTType("com.mmforge.stl")   or UTType("public.stl")   for STL (.stl)
//   - UTType("com.mmforge.dxf")   or UTType("public.dxf")   for DXF (.dxf)
// Each custom UTType should be declared in Info.plist under UTImportedTypeDeclarations.
// Using `.data` in Phase 0 only because format detection is not yet implemented.

/// The document type for MMForge model files.
struct MMForgeDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data] // Phase 0 placeholder — see TODO above
    }

    /// Placeholder data model.  Will be replaced by Rust bridge output.
    var modelData: Data

    init(modelData: Data = Data()) {
        self.modelData = modelData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.modelData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: modelData)
    }
}
