import Foundation
import simd

/// Parsed document data ready for Metal upload.
struct RenderPacketDTO {
    struct Mesh {
        let positions: UnsafePointer<Float>
        let normals: UnsafePointer<Float>
        let vertexCount: Int
        let indices: UnsafePointer<UInt32>
        let indexCount: Int
    }
    let meshes: [Mesh]
    let sceneBoundsMin: simd_float3
    let sceneBoundsMax: simd_float3
    let triangleCount: Int
    let nodeNames: [String]
}

/// Bridge between Swift/UI and the Rust core library via C ABI.
final class RustBridge {
    static let shared = RustBridge()
    private init() {}

    /// Returns the Rust core library version string.
    func coreVersion() -> String {
        guard let ptr = mmf_version() else { return "unknown" }
        return String(cString: ptr)
    }

    /// Parse a STEP file and return render-ready data.
    ///
    /// Calls into Rust via C ABI: `mmf_parse_step` →
    /// `parse_step_with_tessellation` → `build_render_packet`.
    ///
    /// The returned DTO holds borrowed pointers into the Rust document.
    /// Call `freeDocument()` when done.
    func parseFile(at path: String) throws -> (OpaquePointer, RenderPacketDTO) {
        guard let doc = mmf_parse_step(path) else {
            let msg = mmf_last_error().map { String(cString: $0) } ?? "unknown error"
            throw NSError(domain: "MMForge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let meshCount = Int(mmf_mesh_count(doc))
        var meshes: [RenderPacketDTO.Mesh] = []
        meshes.reserveCapacity(meshCount)

        for i in 0..<meshCount {
            let vc = Int(mmf_mesh_vertex_count(doc, UInt32(i)))
            let ic = Int(mmf_mesh_index_count(doc, UInt32(i)))
            guard let pos = mmf_mesh_positions(doc, UInt32(i)),
                  let nrm = mmf_mesh_normals(doc, UInt32(i)),
                  let idx = mmf_mesh_indices(doc, UInt32(i)) else {
                continue
            }
            meshes.append(RenderPacketDTO.Mesh(
                positions: pos, normals: nrm, vertexCount: vc,
                indices: idx, indexCount: ic
            ))
        }

        var bmin: [Float] = [0, 0, 0]
        var bmax: [Float] = [0, 0, 0]
        bmin.withUnsafeMutableBufferPointer { minPtr in
            bmax.withUnsafeMutableBufferPointer { maxPtr in
                mmf_scene_bounds(doc, minPtr.baseAddress!, maxPtr.baseAddress!)
            }
        }

        let nodeCount = Int(mmf_node_count(doc))
        var names: [String] = []
        names.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            if let ptr = mmf_node_name(doc, UInt32(i)) {
                names.append(String(cString: ptr))
            } else {
                names.append("Node \(i)")
            }
        }

        let dto = RenderPacketDTO(
            meshes: meshes,
            sceneBoundsMin: simd_float3(bmin[0], bmin[1], bmin[2]),
            sceneBoundsMax: simd_float3(bmax[0], bmax[1], bmax[2]),
            triangleCount: Int(mmf_triangle_count(doc)),
            nodeNames: names
        )

        return (doc, dto)
    }

    /// Free a document returned by `parseFile`.
    func freeDocument(_ doc: OpaquePointer) {
        mmf_document_free(doc)
    }
}
