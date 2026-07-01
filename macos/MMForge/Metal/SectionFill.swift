import simd

/// Compute section-fill geometry: intersection quads where the clip
/// plane crosses mesh triangles.
///
/// Output layout matches `OverlayVertex` (MetalRenderer.swift):
///   position: float4 (xyz used, w=1) at offset 0   — 16 bytes
///   color:    float4 (rgba)          at offset 16  — 16 bytes
///   stride:   32 bytes per vertex
///
/// Each crossing triangle emits a quad (2 triangles = 6 vertices).
func computeSectionFillVertices(
    meshes: [(positions: UnsafePointer<Float>, indices: UnsafePointer<UInt32>,
              vertexCount: Int, indexCount: Int)],
    clipPlane: simd_float4,
    capColor: simd_float4,
    thickness: Float = 0.002
) -> [Float] {
    guard clipPlane.w > -999990 else { return [] }

    let normal = simd_float3(clipPlane.x, clipPlane.y, clipPlane.z)
    let d = clipPlane.w

    // Compute scene extent for thickness scaling.
    var sceneExtent: Float = 1.0
    for mesh in meshes {
        guard mesh.indexCount % 3 == 0 else { continue }
        for i in 0..<(mesh.vertexCount * 3) {
            sceneExtent = max(sceneExtent, abs(mesh.positions[i]))
        }
    }
    let capThickness = sceneExtent * thickness

    // Perpendicular direction for quad thickness.
    let perp: simd_float3
    if abs(normal.x) < 0.9 {
        perp = normalize(cross(normal, simd_float3(1, 0, 0)))
    } else {
        perp = normalize(cross(normal, simd_float3(0, 1, 0)))
    }

    // 8 floats per vertex (float4 position + float4 color).
    var verts: [Float] = []

    for mesh in meshes {
        let idxCount = mesh.indexCount
        // Guard: index count must be a multiple of 3.
        guard idxCount % 3 == 0, idxCount > 0 else { continue }
        let positions = mesh.positions
        let indices = mesh.indices
        let vc = mesh.vertexCount

        for tri in stride(from: 0, to: idxCount, by: 3) {
            let i0 = Int(indices[tri])
            let i1 = Int(indices[tri + 1])
            let i2 = Int(indices[tri + 2])

            guard i0 < vc, i1 < vc, i2 < vc else { continue }

            let o0 = i0 * 3, o1 = i1 * 3, o2 = i2 * 3
            let v0 = simd_float3(positions[o0], positions[o0+1], positions[o0+2])
            let v1 = simd_float3(positions[o1], positions[o1+1], positions[o1+2])
            let v2 = simd_float3(positions[o2], positions[o2+1], positions[o2+2])

            let dist0 = dot(normal, v0) + d
            let dist1 = dot(normal, v1) + d
            let dist2 = dot(normal, v2) + d

            let aboveCount = (dist0 > 0 ? 1 : 0) + (dist1 > 0 ? 1 : 0) + (dist2 > 0 ? 1 : 0)
            guard aboveCount == 1 || aboveCount == 2 else { continue }

            var above: [(simd_float3, Float)] = []
            var below: [(simd_float3, Float)] = []
            for (v, dist) in [(v0, dist0), (v1, dist1), (v2, dist2)] {
                if dist > 0 { above.append((v, dist)) }
                else { below.append((v, dist)) }
            }

            let single: simd_float3, singleD: Float
            let pairA: simd_float3, pairAD: Float
            let pairB: simd_float3, pairBD: Float

            if above.count == 1 {
                (single, singleD) = above[0]
                (pairA, pairAD) = below[0]
                (pairB, pairBD) = below[1]
            } else {
                (single, singleD) = below[0]
                (pairA, pairAD) = above[0]
                (pairB, pairBD) = above[1]
            }

            let tA = singleD / (singleD - pairAD)
            let tB = singleD / (singleD - pairBD)
            let pA = single + (pairA - single) * tA
            let pB = single + (pairB - single) * tB

            let offset = normal * capThickness * 0.5
            let eA = pA + perp * capThickness
            let eB = pB + perp * capThickness

            // Quad: 2 triangles = 6 vertices.
            // Layout: float4 position (w=1) + float4 color = 32 bytes each.
            appendCapVertex(&verts, p: pA - offset, c: capColor)
            appendCapVertex(&verts, p: pB - offset, c: capColor)
            appendCapVertex(&verts, p: eA - offset, c: capColor)
            appendCapVertex(&verts, p: eA - offset, c: capColor)
            appendCapVertex(&verts, p: pB - offset, c: capColor)
            appendCapVertex(&verts, p: eB - offset, c: capColor)
        }
    }

    return verts
}

/// Append one overlay-compatible vertex: float4 position (w=1) + float4 color.
private func appendCapVertex(_ arr: inout [Float],
                              p: simd_float3, c: simd_float4) {
    arr.append(p.x)
    arr.append(p.y)
    arr.append(p.z)
    arr.append(1.0)   // w = 1
    arr.append(c.x)
    arr.append(c.y)
    arr.append(c.z)
    arr.append(c.w)
}
