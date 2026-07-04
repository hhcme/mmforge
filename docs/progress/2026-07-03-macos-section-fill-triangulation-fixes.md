# macOS Section Fill: Closure Validation + Ear Clipping Triangulation

**Date**: 2026-07-03
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Fix contour closure validation (reject open polylines) and upgrade
           centroid-fan triangulation to ear-clipping for concave polygon support.

---

## 1. Issues Fixed

| # | Issue | Fix |
|---|-------|-----|
| 1 | Open polylines with 3+ segments were erroneously added as contours | Closure check now requires `distance(first, last) < 1e-5` before contour acceptance; non-closed polylines skipped |
| 2 | Centroid-fan triangulation only works for star-shaped polygons | Replaced with 2D ear-clipping: project to coordinate plane, detect winding, reverse if CW, clip ears iteratively, map back to 3D |

---

## 2. Algorithm Changes

### 2.1 Contour Closure Validation (`computeSectionFillVertices` Phase 2)

Before:
```swift
if polyline.count >= 3,
   distance(polyline.first!, polyline.last!) < endpointEpsilon {
    polyline.removeLast()
}
if polyline.count >= 3 {
    contours.append(polyline)  // ← always added regardless of closure
}
```

After:
```swift
guard polyline.count >= 3,
      distance(polyline.first!, polyline.last!) < endpointEpsilon
else { continue }  // ← skip open polylines
polyline.removeLast()
if polyline.count >= 3 {
    contours.append(polyline)
}
```

### 2.2 Ear Clipping Triangulation (`triangulateContour`)

1. **Project to 2D**: Drop the dominant axis of the clip plane normal (produces `simd_float2` coordinates with no loss of topology for the in-plane polygon).

2. **Detect winding**: Compute total signed area via 2D shoelace. Positive = CCW, negative = CW.

3. **Normalize to CCW**: If CW, reverse a local copy of both 2D points and contour vertices. After triangulation, map indices back: `k → (n-1-k)`.

4. **Ear clipping loop**:
   - For each triple (i, i+1, i+2) in the current index list, check if it's convex (`signedArea > 0` for CCW).
   - Check if no other vertex lies inside the triangle using `pointInTriangle2D` (all barycentric signs must have the same sign).
   - If an ear is found, emit the triangle triple and remove the tip vertex from the index list.
   - Continue until 3 vertices remain (final triangle).

5. **Map back**: If the contour was reversed, map each index `k` in the result to the original contour via `n - 1 - k`.

### 2.3 Why Ear Clipping Instead of Centroid Fan

- Centroid fan requires the centroid to be inside the polygon (star-shaped condition), which fails for concave shapes.
- Ear clipping is O(n²) but guaranteed to find a valid triangulation for any simple polygon.
- The choice is appropriate for the expected polygon sizes in cross-section caps (typically < 100 vertices per contour).

---

## 3. Modified Files

| File | Change |
|------|--------|
| `macos/MMForge/Metal/SectionFill.swift` | Phase 2: replaced `if` with `guard` for closure check. Phase 3: replaced centroid-fan with `triangulateContour()` using 2D ear clipping. Added `projectTo2D`, `signedArea2D`, `pointInTriangle2D` helpers. Updated doc comment to reflect ear clipping. |
| `macos/MMForgeTests/ProductizationTests.swift` | Cube test: updated expected float count (192→144) and removed centroid-filter from dedup. Added `testSectionFill_concaveLShape` (6-vertex concave L, verifies 96 floats, 6 unique boundary verts, area=5.0). Added `testSectionFill_openPolyline_skipped` (4-vertex open chain → empty). |

---

## 4. Test Coverage

| Test | Status | Verifies |
|------|--------|---------|
| `testSectionFill_cubeZHalf_closedSquare` | Pass | 8-vertex octagon → ear clip 6 tris = 144 floats, coplanarity, 8 unique verts, area=1.0 |
| `testSectionFill_concaveLShape` | **New** | 6-vertex concave L → ear clip 4 tris = 96 floats, 6 unique verts, area=5.0 |
| `testSectionFill_openPolyline_skipped` | **New** | 4-vertex open chain (first≠last) → empty |
| `testSectionFill_singleTriangle_noClosedContour` | Pass | 1 segment → can't close → empty |
| `testSectionFill_twoCrossing_noClosedContour` | Pass | 2 disconnected segments → empty |
| `testSectionFill_noIntersection` | Pass | All above plane → empty |
| `testSectionFill_disabledClipPlane` | Pass | w=-999999 → empty |

---

## 5. Verified Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge build` | **BUILD SUCCEEDED** |
| `xcodebuild -scheme MMForge test` | **125 tests pass, 0 failures** (+2 new) |
| `cargo test --workspace` | **336 tests pass** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |
| `git diff --check` | **Clean** |

| Suite | Tests | Change |
|-------|-------|--------|
| ProductizationTests | 31 | **+2** (concave L, open polyline) |
| All other suites | 94 | 0 |
| **Total Xcode** | **125** | **+2** |

---

## 6. Known Issues

1. Ear clipping is O(n²) per contour — a monotone-polygon or Delaunay-based triangulation would scale better for very large cross-sections, but current usage (single-model cross-sections) is bounded to tens of vertices.
2. The `pointInTriangle2D` test uses barycentric sign agreement, which may produce false positives for degenerate near-collinear points. A more robust point-in-polygon test (e.g., winding number) could be substituted in the future.
3. Per-mesh contour chaining does not merge contours across mesh boundaries in multi-part assemblies.
