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
        let geometryId: Int       // authoritative GeometryId, -1 if none
        let meshIndex: Int        // sorted rank in RenderPacket, -1 if none
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

    /// Parse a file (auto-detect format: STEP, STL, glTF/GLB) and return render-ready data.
    func parseFile(at path: String) throws -> (OpaquePointer, RenderPacketDTO) {
        guard let doc = mmf_parse_file(path) else {
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
            let geomId = Int(mmf_node_geometry_id(doc, UInt32(i)))
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
                geometryId: geomId,
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

    /// Check if the document is a 2D drawing (DXF).
    func is2DDrawing(_ doc: OpaquePointer) -> Bool {
        mmf_is_2d_drawing(doc) != 0
    }

    /// Get 2D drawing metadata for the document.
    func drawing2DInfo(_ doc: OpaquePointer) -> Drawing2DInfo? {
        guard is2DDrawing(doc) else { return nil }

        let entityCount = Int(mmf_drawing_entity_count(doc))
        let layerCount = Int(mmf_drawing_layer_count(doc))

        // Bounds
        var minX: Double = 0, minY: Double = 0, maxX: Double = 0, maxY: Double = 0
        let hasBounds = withUnsafeMutablePointer(to: &minX) { minXPtr in
            withUnsafeMutablePointer(to: &minY) { minYPtr in
                withUnsafeMutablePointer(to: &maxX) { maxXPtr in
                    withUnsafeMutablePointer(to: &maxY) { maxYPtr in
                        mmf_drawing_bounds(doc, minXPtr, minYPtr, maxXPtr, maxYPtr) != 0
                    }
                }
            }
        }

        // Layers
        var layers: [Drawing2DLayerInfo] = []
        for i in 0..<layerCount {
            let name: String
            if let ptr = mmf_drawing_layer_name(doc, UInt32(i)) {
                name = String(cString: ptr)
            } else {
                name = "Layer \(i)"
            }
            let visible = mmf_drawing_layer_visible(doc, UInt32(i)) != 0
            layers.append(Drawing2DLayerInfo(name: name, visible: visible, colorIndex: 7))
        }

        return Drawing2DInfo(
            entityCount: entityCount,
            layerCount: layerCount,
            boundsMinX: hasBounds ? minX : 0,
            boundsMinY: hasBounds ? minY : 0,
            boundsMaxX: hasBounds ? maxX : 0,
            boundsMaxY: hasBounds ? maxY : 0,
            layers: layers
        )
    }
}

/// 2D drawing metadata.
struct Drawing2DInfo {
    let entityCount: Int
    let layerCount: Int
    let boundsMinX: Double
    let boundsMinY: Double
    let boundsMaxX: Double
    let boundsMaxY: Double
    let layers: [Drawing2DLayerInfo]
}

struct Drawing2DLayerInfo {
    let name: String
    let visible: Bool
    let colorIndex: Int
}
