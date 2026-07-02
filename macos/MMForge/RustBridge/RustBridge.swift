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

    struct ChunkInfo {
        let index: Int
        let meshCount: Int
        let instanceCount: Int
        let batchCount: Int
        let boundsMin: simd_float3
        let boundsMax: simd_float3
        let memoryBytes: UInt64
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
        let dto = buildDTO(from: doc)
        return (doc, dto)
    }

    /// Build a RenderPacketDTO from an already-parsed document pointer.
    /// Used by both `parseFile` (synchronous) and the async job callback.
    func buildDTO(from doc: OpaquePointer) -> RenderPacketDTO {
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

        var bmin: [Float] = [0, 0, 0]
        var bmax: [Float] = [0, 0, 0]
        bmin.withUnsafeMutableBufferPointer { minPtr in
            bmax.withUnsafeMutableBufferPointer { maxPtr in
                mmf_scene_bounds(doc, minPtr.baseAddress!, maxPtr.baseAddress!)
            }
        }

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

        let stats = RenderPacketDTO.ModelStats(
            nodeCount: nodeCount,
            geometryCount: Int(mmf_geometry_count(doc)),
            materialCount: Int(mmf_material_count(doc)),
            triangleCount: Int(mmf_triangle_count(doc)),
            meshCount: meshCount
        )

        return RenderPacketDTO(
            meshes: meshes,
            sceneBoundsMin: simd_float3(bmin[0], bmin[1], bmin[2]),
            sceneBoundsMax: simd_float3(bmax[0], bmax[1], bmax[2]),
            triangleCount: Int(mmf_triangle_count(doc)),
            nodeNames: names,
            nodes: nodes,
            stats: stats
        )
    }

    /// Free a document returned by `parseFile`.
    func freeDocument(_ doc: OpaquePointer) {
        mmf_document_free(doc)
    }

    /// Render statistics for a parsed document.
    struct RenderStatsDTO {
        let meshCount: Int
        let vertexCount: Int
        let triangleCount: Int
        let memoryBytes: Int
        let buildDurationMs: Double
    }

    func renderStats(_ doc: OpaquePointer) -> RenderStatsDTO {
        var meshCount: UInt32 = 0
        var vertexCount: UInt32 = 0
        var triangleCount: UInt32 = 0
        var memoryBytes: UInt64 = 0
        var buildMs: Double = 0
        mmf_render_stats(doc, &meshCount, &vertexCount, &triangleCount, &memoryBytes, &buildMs)
        return RenderStatsDTO(
            meshCount: Int(meshCount),
            vertexCount: Int(vertexCount),
            triangleCount: Int(triangleCount),
            memoryBytes: Int(memoryBytes),
            buildDurationMs: buildMs
        )
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
            let colorIdx = Int(mmf_drawing_layer_color_index(doc, UInt32(i)))
            let lineType: String? = {
                if let ptr = mmf_drawing_layer_line_type(doc, UInt32(i)) {
                    return String(cString: ptr)
                }
                return nil
            }()
            layers.append(Drawing2DLayerInfo(
                name: name, visible: visible, colorIndex: colorIdx, lineType: lineType))
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
    let lineType: String?
}

/// A single 2D draw command for Swift rendering.
enum DrawCommandDTO {
    case line(x0: Double, y0: Double, x1: Double, y1: Double,
              layerIndex: Int, layerName: String, colorIndex: Int, visible: Bool,
              lineType: String?, lineWeight: Double, lineDash: [Double])
    case circle(cx: Double, cy: Double, r: Double,
                layerIndex: Int, layerName: String, colorIndex: Int, visible: Bool,
                lineType: String?, lineWeight: Double, lineDash: [Double])
    case arc(cx: Double, cy: Double, r: Double, startAngle: Double, endAngle: Double, ccw: Bool,
             layerIndex: Int, layerName: String, colorIndex: Int, visible: Bool,
             lineType: String?, lineWeight: Double, lineDash: [Double])
    case polyline(points: [(Double, Double)], closed: Bool,
                  layerIndex: Int, layerName: String, colorIndex: Int, visible: Bool,
                  lineType: String?, lineWeight: Double, lineDash: [Double])
    case text(x: Double, y: Double, content: String, height: Double, rotation: Double,
              layerIndex: Int, layerName: String, colorIndex: Int, visible: Bool)
}

extension RustBridge {
    /// Fetch all draw commands from a 2D document.
    func drawCommands(_ doc: OpaquePointer) -> [DrawCommandDTO] {
        let count = Int(mmf_draw_cmd_count(doc))
        var commands: [DrawCommandDTO] = []
        commands.reserveCapacity(count)

        for i in 0..<count {
            let idx = UInt32(i)
            let type = mmf_draw_cmd_type(doc, idx)
            let layerIdx = Int(mmf_draw_cmd_layer_index(doc, idx))
            let layerName: String = {
                if let ptr = mmf_draw_cmd_layer_name(doc, idx) {
                    return String(cString: ptr)
                }
                return "Layer \(layerIdx)"
            }()
            let colorIdx = Int(mmf_draw_cmd_color_index(doc, idx))
            let visible = mmf_draw_cmd_layer_visible(doc, idx) != 0
            let lineType: String? = {
                if let ptr = mmf_draw_cmd_line_type(doc, idx) {
                    return String(cString: ptr)
                }
                return nil
            }()
            let lineWeight = mmf_draw_cmd_line_weight(doc, idx)
            let lineDash: [Double] = {
                let count = Int(mmf_draw_cmd_line_dash_count(doc, idx))
                guard count > 0 else { return [] }
                var buffer = [Double](repeating: 0, count: count)
                let written = buffer.withUnsafeMutableBufferPointer { buf in
                    mmf_draw_cmd_line_dash(doc, idx, buf.baseAddress!, UInt32(count))
                }
                return Array(buffer.prefix(Int(written)))
            }()

            switch type {
            case 0: // Line
                var x0: Double = 0, y0: Double = 0, x1: Double = 0, y1: Double = 0
                if mmf_draw_cmd_line(doc, idx, &x0, &y0, &x1, &y1) != 0 {
                    commands.append(.line(x0: x0, y0: y0, x1: x1, y1: y1,
                                          layerIndex: layerIdx, layerName: layerName,
                                          colorIndex: colorIdx, visible: visible,
                                          lineType: lineType, lineWeight: lineWeight,
                                          lineDash: lineDash))
                }
            case 1: // Circle
                var cx: Double = 0, cy: Double = 0, r: Double = 0
                if mmf_draw_cmd_circle(doc, idx, &cx, &cy, &r) != 0 {
                    commands.append(.circle(cx: cx, cy: cy, r: r,
                                            layerIndex: layerIdx, layerName: layerName,
                                            colorIndex: colorIdx, visible: visible,
                                            lineType: lineType, lineWeight: lineWeight,
                                            lineDash: lineDash))
                }
            case 2: // Arc
                var cx: Double = 0, cy: Double = 0, r: Double = 0
                var startAngle: Double = 0, endAngle: Double = 0
                var ccw: Int32 = 0
                if mmf_draw_cmd_arc(doc, idx, &cx, &cy, &r, &startAngle, &endAngle, &ccw) != 0 {
                    commands.append(.arc(cx: cx, cy: cy, r: r,
                                         startAngle: startAngle, endAngle: endAngle,
                                         ccw: ccw != 0,
                                         layerIndex: layerIdx, layerName: layerName,
                                         colorIndex: colorIdx, visible: visible,
                                         lineType: lineType, lineWeight: lineWeight,
                                         lineDash: lineDash))
                }
            case 3: // Polyline
                let ptCount = Int(mmf_draw_cmd_polyline_count(doc, idx))
                var points: [(Double, Double)] = []
                for j in 0..<ptCount {
                    var x: Double = 0, y: Double = 0
                    if mmf_draw_cmd_polyline_point(doc, idx, UInt32(j), &x, &y) != 0 {
                        points.append((x, y))
                    }
                }
                let closed = mmf_draw_cmd_polyline_closed(doc, idx) != 0
                commands.append(.polyline(points: points, closed: closed,
                                          layerIndex: layerIdx, layerName: layerName,
                                          colorIndex: colorIdx, visible: visible,
                                          lineType: lineType, lineWeight: lineWeight,
                                          lineDash: lineDash))
            case 4: // Text
                var x: Double = 0, y: Double = 0, height: Double = 0, rotation: Double = 0
                let contentPtr = mmf_draw_cmd_text(doc, idx, &x, &y, &height, &rotation)
                let content = contentPtr.map { String(cString: $0) } ?? ""
                commands.append(.text(x: x, y: y, content: content, height: height,
                                      rotation: rotation,
                                      layerIndex: layerIdx, layerName: layerName,
                                      colorIndex: colorIdx, visible: visible))
            default:
                break
            }
        }

        return commands
    }

    /// Query spatial index for visible commands in viewport.
    ///
    /// Returns:
    /// - `nil` if spatial index is unavailable (caller should fall back to full draw).
    /// - Empty array if no commands are visible (legitimate empty viewport).
    /// - Array of command indices to render.
    func spatialQuery(_ doc: OpaquePointer, minX: Double, minY: Double,
                      maxX: Double, maxY: Double) -> [Int]? {
        var capacity = 16384
        let buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let total = Int(mmf_draw_spatial_query(
            doc, minX, minY, maxX, maxY, buffer, UInt32(capacity)))

        if total < 0 {
            // Spatial index unavailable or error — caller falls back to full draw.
            return nil
        }

        if total == 0 {
            // Legitimate empty viewport — nothing visible.
            return []
        }

        if total > capacity {
            // Overflow — reallocate with exact total and re-query.
            capacity = total
            let bigBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
            defer { bigBuffer.deallocate() }
            let total2 = Int(mmf_draw_spatial_query(
                doc, minX, minY, maxX, maxY, bigBuffer, UInt32(capacity)))
            if total2 <= 0 { return nil }
            let count = min(total2, capacity)
            return (0..<count).map { Int(bigBuffer[$0]) }
        }

        // All results fit in buffer.
        return (0..<total).map { Int(buffer[$0]) }
    }

    // MARK: - Streaming / chunk-based progressive loading

    /// Build streaming chunks for a document with the given budget.
    /// Returns the number of chunks (0 if empty).
    func buildChunks(for docPtr: OpaquePointer, budgetBytes: UInt32) -> UInt32 {
        mmf_build_streaming_packet(docPtr, budgetBytes)
    }

    /// Get chunk info. Returns nil if chunks not built or index out of range.
    func chunkInfo(for docPtr: OpaquePointer, index: UInt32) -> RenderPacketDTO.ChunkInfo? {
        let meshCount = Int(mmf_chunk_mesh_count(docPtr, index))
        let instanceCount = Int(mmf_chunk_instance_count(docPtr, index))
        let batchCount = Int(mmf_chunk_batch_count(docPtr, index))
        let memoryBytes = mmf_chunk_memory_bytes(docPtr, index)
        var mins = [Float](repeating: 0, count: 3)
        var maxs = [Float](repeating: 0, count: 3)
        let boundsOk = mins.withUnsafeMutableBufferPointer { minBuf in
            maxs.withUnsafeMutableBufferPointer { maxBuf in
                mmf_chunk_bounds(docPtr, index, minBuf.baseAddress, maxBuf.baseAddress)
            }
        }
        guard boundsOk == 1 else { return nil }
        return RenderPacketDTO.ChunkInfo(
            index: Int(index),
            meshCount: meshCount,
            instanceCount: instanceCount,
            batchCount: batchCount,
            boundsMin: simd_float3(mins[0], mins[1], mins[2]),
            boundsMax: simd_float3(maxs[0], maxs[1], maxs[2]),
            memoryBytes: memoryBytes
        )
    }

    /// Total GPU memory across all chunks.
    func chunkTotalMemory(_ docPtr: OpaquePointer) -> UInt64 {
        mmf_chunk_total_memory(docPtr)
    }

    /// Upload all meshes of a single chunk into the Metal renderer.
    /// Returns the number of meshes actually uploaded (0 if chunk invalid).
    func uploadChunk(
        from docPtr: OpaquePointer,
        chunkIndex: UInt32,
        nodeMap: [Int: Int],
        nodeInfos: [RenderPacketDTO.NodeInfo],
        into renderer: MetalRenderer
    ) -> Int {
        let meshCount = Int(mmf_chunk_mesh_count(docPtr, chunkIndex))
        guard meshCount > 0 else { return 0 }

        var uploaded = 0
        for mi in 0..<UInt32(meshCount) {
            let geomId = Int(mmf_chunk_mesh_geometry_id(docPtr, chunkIndex, mi))
            let vc = Int(mmf_chunk_mesh_vertex_count(docPtr, chunkIndex, mi))
            let ic = Int(mmf_chunk_mesh_index_count(docPtr, chunkIndex, mi))
            guard let pos = mmf_chunk_mesh_positions(docPtr, chunkIndex, mi),
                  let nor = mmf_chunk_mesh_normals(docPtr, chunkIndex, mi),
                  let idx = mmf_chunk_mesh_indices(docPtr, chunkIndex, mi),
                  vc > 0, ic > 0 else { continue }

            let nodeIdx = nodeMap[geomId] ?? -1
            let node = nodeIdx >= 0 && nodeIdx < nodeInfos.count ? nodeInfos[nodeIdx] : nil

            renderer.upload(
                positions: pos, normals: nor, vertexCount: vc,
                indices: idx, indexCount: ic,
                nodeIndex: nodeIdx,
                boundsMin: node?.boundsMin ?? .zero,
                boundsMax: node?.boundsMax ?? .zero
            )
            uploaded += 1
        }
        return uploaded
    }

    /// Rebuild streaming packet with a different budget (clears then rebuilds).
    func rebuildChunks(for docPtr: OpaquePointer, budgetBytes: UInt32) -> UInt32 {
        mmf_reset_streaming_packet(docPtr)
        return mmf_build_streaming_packet(docPtr, budgetBytes)
    }
}
