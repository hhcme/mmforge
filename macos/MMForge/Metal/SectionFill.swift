import simd

/// Compute section-fill geometry: intersection quads where the clip
/// plane crosses mesh triangles.
///
/// For each triangle that straddles the clip plane, we compute the
/// two intersection points and emit a thin quad (2 triangles) along
/// the intersection line, extended slightly along the plane normal
/// for visual thickness.
///
/// Returns flat overlay vertex data (position + color, stride 28 bytes).
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
        for i in 0..<(mesh.vertexCount * 3) {
            let v = mesh.positions[i]
            sceneExtent = max(sceneExtent, abs(v))
        }
    }
    let capThickness = sceneExtent * thickness

    // Perpendicular direction for quad thickness.
    // Use a vector perpendicular to the plane normal.
    let perp: simd_float3
    if abs(normal.x) < 0.9 {
        perp = normalize(cross(normal, simd_float3(1, 0, 0)))
    } else {
        perp = normalize(cross(normal, simd_float3(0, 1, 0)))
    }

    var vertices: [Float] = []

    for mesh in meshes {
        let idxCount = mesh.indexCount
        let positions = mesh.positions
        let indices = mesh.indices

        for tri in stride(from: 0, to: idxCount, by: 3) {
            let i0 = Int(indices[tri])
            let i1 = Int(indices[tri + 1])
            let i2 = Int(indices[tri + 2])

            let vc = mesh.vertexCount
            guard i0 < vc, i1 < vc, i2 < vc else { continue }

            let o0 = i0 * 3, o1 = i1 * 3, o2 = i2 * 3
            let v0 = simd_float3(positions[o0], positions[o0+1], positions[o0+2])
            let v1 = simd_float3(positions[o1], positions[o1+1], positions[o1+2])
            let v2 = simd_float3(positions[o2], positions[o2+1], positions[o2+2])

            // Signed distances to clip plane.
            let d0 = dot(normal, v0) + d
            let d1 = dot(normal, v1) + d
            let d2 = dot(normal, v2) + d

            // Check if triangle crosses the plane.
            let signs = (d0 > 0 ? 1 : 0) + (d1 > 0 ? 1 : 0) + (d2 > 0 ? 1 : 0)
            guard signs == 1 || signs == 2 else {
                // All on same side — no intersection.
                continue
            }

            // Collect vertices by side: above (>0) and below (<=0).
            var above: [(simd_float3, Float)] = []
            var below: [(simd_float3, Float)] = []
            let verts = [(v0, d0), (v1, d1), (v2, d2)]
            for (v, dist) in verts {
                if dist > 0 { above.append((v, dist)) }
                else { below.append((v, dist)) }
            }

            // We need exactly 1 on one side and 2 on the other.
            let single: simd_float3
            let singleD: Float
            let pairA: simd_float3
            let pairAD: Float
            let pairB: simd_float3
            let pairBD: Float

            if above.count == 1 {
                single = above[0].0; singleD = above[0].1
                pairA = below[0].0; pairAD = below[0].1
                pairB = below[1].0; pairBD = below[1].1
            } else {
                single = below[0].0; singleD = below[0].1
                pairA = above[0].0; pairAD = above[0].1
                pairB = above[1].0; pairBD = above[1].1
            }

            // Compute intersection points.
            let tA = singleD / (singleD - pairAD)
            let tB = singleD / (singleD - pairBD)
            let pA = single + (pairA - single) * tA
            let pB = single + (pairB - single) * tB

            // Create a quad (2 triangles) from the intersection line,
            // extended slightly along the plane normal for visibility.
            let offset = normal * capThickness * 0.5
            let eA = pA + perp * capThickness
            let eB = pB + perp * capThickness

            // Triangle 1: pA, pB, eA
            appendOverlayVertex(&vertices, position: pA - offset, color: capColor)
            appendOverlayVertex(&vertices, position: pB - offset, color: capColor)
            appendOverlayVertex(&vertices, position: eA - offset, color: capColor)

            // Triangle 2: eA, pB, eB
            appendOverlayVertex(&vertices, position: eA - offset, color: capColor)
            appendOverlayVertex(&vertices, position: pB - offset, color: capColor)
            appendOverlayVertex(&vertices, position: eB - offset, color: capColor)
        }
    }

    return vertices
}

/// Append an overlay vertex (position xyz + color rgba = 7 floats).
private func appendOverlayVertex(_ arr: inout [Float],
                                  position: simd_float3,
                                  color: simd_float4) {
    arr.append(position.x)
    arr.append(position.y)
    arr.append(position.z)
    arr.append(color.x)
    arr.append(color.y)
    arr.append(color.z)
    arr.append(color.w)
}
