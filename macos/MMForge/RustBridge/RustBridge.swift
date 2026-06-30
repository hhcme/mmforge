import Foundation
import simd

/// Parsed document data ready for Metal upload and UI display.
struct RenderPacketDTO {
    struct Mesh {
        let geometryId: Int
        let positions: UnsafePointer<Float>
        let normals: UnsafePointer<Float>
        let vertexCount: Int
        let indices: UnsafePointer<UInt32>
        let indexCount: Int
    }

    struct NodeInfo {
        let name: String
        let parentIndex: Int      // -1 for root
        let hasGeometry: Bool
        let meshIndex: Int        // index into RenderPacket meshes, -1 if none
        let geometryLabel: String?
        let boundsMin: simd_float3?
        let boundsMax: simd_float3?
    }

    struct ModelStats {
        let nodeCount: Int
        let geometryCount: Int
        let materialCount: Int
        let triangleCount: Int
        let meshCount: Int
    }

    let meshes: [Mesh]
    let sceneBoundsMin: simd_float3
    let sceneBoundsMax: simd_float3
    let triangleCount: Int
    let nodeNames: [String]
    let nodes: [NodeInfo]
    let stats: ModelStats
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
    func parseFile(at path: String) throws -> (OpaquePointer, RenderPacketDTO) {
        guard let doc = mmf_parse_step(path) else {
            let msg = mmf_last_error().map { String(cString: $0) } ?? "unknown error"
            throw NSError(domain: "MMForge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Meshes
        let meshCount = Int(mmf_mesh_count(doc))
        var meshes: [RenderPacketDTO.Mesh] = []
        meshes.reserveCapacity(meshCount)
        for i in 0..<meshCount {
            let vc = Int(mmf_mesh_vertex_count(doc, UInt32(i)))
            let ic = Int(mmf_mesh_index_count(doc, UInt32(i)))
            let gid = Int(mmf_mesh_geometry_id(doc, UInt32(i)))
            guard let pos = mmf_mesh_positions(doc, UInt32(i)),
                  let nrm = mmf_mesh_normals(doc, UInt32(i)),
                  let idx = mmf_mesh_indices(doc, UInt32(i)) else {
                continue
            }
            meshes.append(RenderPacketDTO.Mesh(
                geometryId: gid, positions: pos, normals: nrm,
                vertexCount: vc, indices: idx, indexCount: ic
            ))
        }

        // Scene bounds
        var bmin: [Float] = [0, 0, 0]
        var bmax: [Float] = [0, 0, 0]
        bmin.withUnsafeMutableBufferPointer { minPtr in
            bmax.withUnsafeMutableBufferPointer { maxPtr in
                mmf_scene_bounds(doc, minPtr.baseAddress!, maxPtr.baseAddress!)
            }
        }

        // Node info
        let nodeCount = Int(mmf_node_count(doc))
        var nodes: [RenderPacketDTO.NodeInfo] = []
        var names: [String] = []
        nodes.reserveCapacity(nodeCount)
        names.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            let name: String
            if let ptr = mmf_node_name(doc, UInt32(i)) {
                name = String(cString: ptr)
            } else {
                name = "Node \(i)"
            }
            names.append(name)

            let parentIdx = Int(mmf_node_parent(doc, UInt32(i)))
            let hasGeom = mmf_node_has_geometry(doc, UInt32(i)) != 0
            let meshIdx = Int(mmf_node_mesh_index(doc, UInt32(i)))

            let geomLabel: String?
            if let ptr = mmf_node_geometry_label(doc, UInt32(i)) {
                geomLabel = String(cString: ptr)
            } else {
                geomLabel = nil
            }

            var nmin: [Float] = [0, 0, 0]
            var nmax: [Float] = [0, 0, 0]
            var boundsMin: simd_float3?
            var boundsMax: simd_float3?
            let hasBounds = nmin.withUnsafeMutableBufferPointer { minPtr in
                nmax.withUnsafeMutableBufferPointer { maxPtr in
                    mmf_node_bounds(doc, UInt32(i), minPtr.baseAddress!, maxPtr.baseAddress!) != 0
                }
            }
            if hasBounds {
                boundsMin = simd_float3(nmin[0], nmin[1], nmin[2])
                boundsMax = simd_float3(nmax[0], nmax[1], nmax[2])
            }

            nodes.append(RenderPacketDTO.NodeInfo(
                name: name,
                parentIndex: parentIdx,
                hasGeometry: hasGeom,
                meshIndex: meshIdx,
                geometryLabel: geomLabel,
                boundsMin: boundsMin,
                boundsMax: boundsMax
            ))
        }

        // Stats
        let stats = RenderPacketDTO.ModelStats(
            nodeCount: nodeCount,
            geometryCount: Int(mmf_geometry_count(doc)),
            materialCount: Int(mmf_material_count(doc)),
            triangleCount: Int(mmf_triangle_count(doc)),
            meshCount: meshCount
        )

        let dto = RenderPacketDTO(
            meshes: meshes,
            sceneBoundsMin: simd_float3(bmin[0], bmin[1], bmin[2]),
            sceneBoundsMax: simd_float3(bmax[0], bmax[1], bmax[2]),
            triangleCount: Int(mmf_triangle_count(doc)),
            nodeNames: names,
            nodes: nodes,
            stats: stats
        )

        return (doc, dto)
    }

    /// Free a document returned by `parseFile`.
    func freeDocument(_ doc: OpaquePointer) {
        mmf_document_free(doc)
    }
}
