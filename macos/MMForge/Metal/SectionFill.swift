import simd

/// Compute section-fill geometry: closed polygon caps on the clip plane
/// for each connected closed contour of the mesh cross-section.
///
/// Algorithm (per mesh):
///   1. Collect intersection segments from each crossing triangle.
///   2. Chain segments into polylines by endpoint proximity.
///   3. **Only truly closed contours** (polyline[0] ≈ polyline[n-1]) are kept;
///      open polylines with 3+ segments are silently skipped.
///   4. Triangulate each closed contour via 2D ear-clipping after projecting
///      onto a coordinate plane (drops dominant normal axis).
///   5. Map triangle indices back to 3D and emit overlay vertex data.
///
/// Output: flat `[Float]`, 8 floats per vertex (position4 + color4).
func computeSectionFillVertices(
    meshes: [(positions: UnsafePointer<Float>, indices: UnsafePointer<UInt32>,
              vertexCount: Int, indexCount: Int)],
    clipPlane: simd_float4,
    capColor: simd_float4
) -> [Float] {
    guard clipPlane.w > -999990 else { return [] }

    let normal = normalize(simd_float3(clipPlane.x, clipPlane.y, clipPlane.z))
    let d = clipPlane.w
    let endpointEpsilon: Float = 1e-5
    var verts: [Float] = []

    for mesh in meshes {
        let idxCount = mesh.indexCount
        guard idxCount % 3 == 0, idxCount > 0 else { continue }
        let positions = mesh.positions
        let indices = mesh.indices
        let vc = mesh.vertexCount

        // Phase 1: collect crossing segments.
        struct Seg { var a: simd_float3; var b: simd_float3 }
        var segments: [Seg] = []

        for tri in stride(from: 0, to: idxCount, by: 3) {
            let i0 = Int(indices[tri])
            let i1 = Int(indices[tri + 1])
            let i2 = Int(indices[tri + 2])
            guard i0 < vc, i1 < vc, i2 < vc else { continue }

            let o0 = i0 * 3; let o1 = i1 * 3; let o2 = i2 * 3
            let v0 = simd_float3(positions[o0], positions[o0+1], positions[o0+2])
            let v1 = simd_float3(positions[o1], positions[o1+1], positions[o1+2])
            let v2 = simd_float3(positions[o2], positions[o2+1], positions[o2+2])

            let dist0 = dot(normal, v0) + d
            let dist1 = dot(normal, v1) + d
            let dist2 = dot(normal, v2) + d

            let above = (dist0 > 0 ? 1 : 0) + (dist1 > 0 ? 1 : 0) + (dist2 > 0 ? 1 : 0)
            guard above == 1 || above == 2 else { continue }

            var abovePts: [(simd_float3, Float)] = []
            var belowPts: [(simd_float3, Float)] = []
            for (v, dist) in [(v0, dist0), (v1, dist1), (v2, dist2)] {
                if dist > 0 { abovePts.append((v, dist)) }
                else { belowPts.append((v, dist)) }
            }

            let singleD: Float, pairAD: Float, pairBD: Float
            let single: simd_float3, pairA: simd_float3, pairB: simd_float3

            if abovePts.count == 1 {
                (single, singleD) = abovePts[0]
                (pairA, pairAD) = belowPts[0]
                (pairB, pairBD) = belowPts[1]
            } else {
                (single, singleD) = belowPts[0]
                (pairA, pairAD) = abovePts[0]
                (pairB, pairBD) = abovePts[1]
            }

            let tA = singleD / (singleD - pairAD)
            let tB = singleD / (singleD - pairBD)
            let pA = single + (pairA - single) * tA
            let pB = single + (pairB - single) * tB

            segments.append(Seg(a: pA, b: pB))
        }

        guard !segments.isEmpty else { continue }

        // Phase 2: chain into closed contours only.
        var used = [Bool](repeating: false, count: segments.count)
        var contours: [[simd_float3]] = []

        for startIdx in 0..<segments.count {
            guard !used[startIdx] else { continue }
            let seg = segments[startIdx]
            var polyline = [seg.a, seg.b]
            used[startIdx] = true

            var extended = true
            while extended {
                extended = false
                for i in 0..<segments.count where !used[i] {
                    let s = segments[i]
                    let last = polyline.last!
                    if distance(last, s.a) < endpointEpsilon {
                        polyline.append(s.b)
                        used[i] = true
                        extended = true
                    } else if distance(last, s.b) < endpointEpsilon {
                        polyline.append(s.a)
                        used[i] = true
                        extended = true
                    }
                }
            }

            // Only closed contours are accepted: first ≈ last.
            guard polyline.count >= 3,
                  distance(polyline.first!, polyline.last!) < endpointEpsilon
            else { continue }

            // Remove the duplicate closure vertex and canonicalize.
            polyline.removeLast()
            if polyline.count >= 3 {
                contours.append(polyline)
            }
        }

        // Phase 3: triangulate closed contours with ear clipping.
        for contour in contours {
            let triIndices = triangulateContour(contour, normal: normal)
            for tri in triIndices {
                let (v0, v1, v2) = (
                    contour[tri.0], contour[tri.1], contour[tri.2]
                )
                // Emit with consistent winding (both sides visible — cull=none).
                appendCapVertex(&verts, p: v0, c: capColor)
                appendCapVertex(&verts, p: v1, c: capColor)
                appendCapVertex(&verts, p: v2, c: capColor)
            }
        }
    }

    return verts
}

// MARK: - 2D Ear Clipping Triangulation

/// Project a 3D point on a plane to 2D coordinates by dropping the
/// dominant axis of the plane normal.
private func projectTo2D(_ p: simd_float3, normal: simd_float3) -> simd_float2 {
    let ax = abs(normal.x), ay = abs(normal.y), az = abs(normal.z)
    if ax >= ay && ax >= az { return simd_float2(p.y, p.z) }
    else if ay >= az { return simd_float2(p.x, p.z) }
    else { return simd_float2(p.x, p.y) }
}

/// Compute the signed area of a triangle in 2D (positive = CCW).
private func signedArea2D(_ a: simd_float2, _ b: simd_float2, _ c: simd_float2) -> Float {
    (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
}

/// Check whether point `p` lies inside triangle (a, b, c) in 2D.
/// Assumes CCW winding.
private func pointInTriangle2D(_ p: simd_float2, _ a: simd_float2,
                                _ b: simd_float2, _ c: simd_float2) -> Bool {
    let d1 = signedArea2D(p, a, b)
    let d2 = signedArea2D(p, b, c)
    let d3 = signedArea2D(p, c, a)
    let hasNeg = (d1 < -1e-10) || (d2 < -1e-10) || (d3 < -1e-10)
    let hasPos = (d1 > +1e-10) || (d2 > +1e-10) || (d3 > +1e-10)
    return !(hasNeg && hasPos)
}

/// Triangulate a closed planar 3D contour using 2D ear clipping.
///
/// 1. Project vertices to 2D (drop dominant normal axis).
/// 2. Detect winding from signed area; reverse if clockwise.
/// 3. Run ear clipping on the CCW 2D polygon.
/// 4. Emit (i, j, k) index triples into the original contour.
private func triangulateContour(
    _ contour: [simd_float3], normal: simd_float3
) -> [(Int, Int, Int)] {
    let n = contour.count
    guard n >= 3 else { return [] }
    if n == 3 { return [(0, 1, 2)] }

    var pts2D = contour.map { projectTo2D($0, normal: normal) }

    // Detect winding.
    var total2DArea: Float = 0
    for i in 0..<n {
        let j = (i + 1) % n
        total2DArea += pts2D[i].x * pts2D[j].y - pts2D[j].x * pts2D[i].y
    }
    let isCW = total2DArea < 0

    // If CW, reverse the 2D points so ear clipping processes a CCW polygon.
    // After triangulation, map each returned index k → (n-1-k) to refer back
    // to the original (unreversed) contour vertices.
    if isCW {
        pts2D.reverse()
    }

    var indices = Array(0..<n)
    var triples: [(Int, Int, Int)] = []
    triples.reserveCapacity(n - 2)

    var cleanupUsed = false

    while indices.count > 3 {
        let m = indices.count
        var earFound = false
        for i in 0..<m {
            let i0 = indices[i]
            let i1 = indices[(i + 1) % m]
            let i2 = indices[(i + 2) % m]

            if signedArea2D(pts2D[i0], pts2D[i1], pts2D[i2]) < -1e-10 {
                continue
            }

            var isEar = true
            for j in 0..<m {
                let idx = indices[j]
                if idx == i0 || idx == i1 || idx == i2 { continue }
                if pointInTriangle2D(pts2D[idx], pts2D[i0], pts2D[i1], pts2D[i2]) {
                    isEar = false
                    break
                }
            }

            if isEar {
                triples.append((i0, i1, i2))
                indices.remove(at: (i + 1) % m)
                earFound = true
                break
            }
        }
        if !earFound {
            if !cleanupUsed {
                indices = cleanIndices(indices, pts2D: pts2D)
                if indices.count < 3 { return [] }
                cleanupUsed = true
                continue
            }
            return []
        }
    }

    if indices.count == 3 {
        triples.append((indices[0], indices[1], indices[2]))
    }

    if isCW {
        // Map back: local index k → original index (n-1-k).
        return triples.map { (n - 1 - $0.0, n - 1 - $0.1, n - 1 - $0.2) }
    }

    return triples
}

/// Remove consecutive near-duplicate and colinear points from a working
/// index list that indexes into `pts2D`.  Produces a clean polygon for
/// ear clipping, or an empty array when too few points remain.
private func cleanIndices(_ indices: [Int], pts2D: [simd_float2]) -> [Int] {
    guard indices.count >= 3 else { return indices }

    var deduped: [Int] = [indices[0]]
    for i in 1..<indices.count {
        let prev = deduped.last!
        let curr = indices[i]
        let dx = pts2D[curr].x - pts2D[prev].x
        let dy = pts2D[curr].y - pts2D[prev].y
        if abs(dx) > 1e-10 || abs(dy) > 1e-10 {
            deduped.append(curr)
        }
    }
    if deduped.count >= 2 {
        let first = deduped[0]
        let last = deduped.last!
        let dx = pts2D[last].x - pts2D[first].x
        let dy = pts2D[last].y - pts2D[first].y
        if abs(dx) < 1e-10 && abs(dy) < 1e-10 {
            deduped.removeLast()
        }
    }
    guard deduped.count >= 3 else { return [] }

    let m = deduped.count
    var result: [Int] = [deduped[0]]
    for i in 1..<(m - 1) {
        let prev = result.last!
        let curr = deduped[i]
        let next = deduped[i + 1]
        let area = signedArea2D(pts2D[prev], pts2D[curr], pts2D[next])
        if abs(area) > 1e-10 {
            result.append(curr)
        }
    }
    result.append(deduped.last!)

    while result.count >= 3 {
        let n2 = result.count
        let area = signedArea2D(pts2D[result[n2 - 2]], pts2D[result[n2 - 1]], pts2D[result[0]])
        if abs(area) > 1e-10 { break }
        result.removeLast()
    }
    while result.count >= 3 {
        let n2 = result.count
        let area = signedArea2D(pts2D[result[n2 - 1]], pts2D[result[0]], pts2D[result[1]])
        if abs(area) > 1e-10 { break }
        result.remove(at: 0)
    }

    return result.count >= 3 ? result : []
}

// MARK: - Public helpers

func computeSectionFill(
    positions: [Float], indices: [UInt32],
    clipPlane: simd_float4, capColor: simd_float4
) -> [Float] {
    positions.withUnsafeBufferPointer { posBuf in
        indices.withUnsafeBufferPointer { idxBuf in
            computeSectionFillVertices(
                meshes: [(posBuf.baseAddress!, idxBuf.baseAddress!,
                          positions.count / 3, indices.count)],
                clipPlane: clipPlane, capColor: capColor
            )
        }
    }
}

func extractSectionVertices(_ verts: [Float]) -> [simd_float3] {
    var out: [simd_float3] = []
    for i in stride(from: 0, to: verts.count, by: 8) {
        out.append(simd_float3(verts[i], verts[i+1], verts[i+2]))
    }
    return out
}

func polygonArea(_ points: [simd_float3], normal: simd_float3) -> Float {
    guard points.count >= 3 else { return 0 }
    let ax = abs(normal.x), ay = abs(normal.y), az = abs(normal.z)
    var projected: [(Float, Float)] = points.map { p in
        if ax >= ay && ax >= az { return (p.y, p.z) }
        else if ay >= az { return (p.x, p.z) }
        else { return (p.x, p.y) }
    }
    projected.append(projected[0])
    var area: Float = 0
    for i in 0..<(projected.count - 1) {
        area += projected[i].0 * projected[i+1].1 - projected[i+1].0 * projected[i].1
    }
    return abs(area) / 2
}

// MARK: - Private

private func appendCapVertex(_ arr: inout [Float],
                              p: simd_float3, c: simd_float4) {
    arr.append(p.x)
    arr.append(p.y)
    arr.append(p.z)
    arr.append(1.0)
    arr.append(c.x)
    arr.append(c.y)
    arr.append(c.z)
    arr.append(c.w)
}
