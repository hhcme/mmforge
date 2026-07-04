# macOS Productization Alpha — Review Fixes

**Date**: 2026-07-03
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Fix four issues identified in Codex review of `2026-07-03-macos-productization-alpha.md`.

---

## 1. Issues Fixed

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | Stale callbacks publish state after cancel | `cancelParse()` did not increment `parseGeneration`, so the old completion callback's generation check could still match | `cancelParse()` now calls `parseGeneration += 1` before signalling cancellation |
| 2 | LoadingStateView shows empty format name | `ViewportContainer` passed hardcoded `fileExtension: ""` | Added `loadingFileExtension` to `DocumentViewModel`, set in `parseFile()` after computing `ext`, cleared in `freeCurrentDocument()` |
| 3 | Tests use dangling `UnsafePointer` outside `withUnsafeBufferPointer` closure | `let ptr = arr.withUnsafeBufferPointer { $0.baseAddress! }` — pointer lifetime only valid inside closure | Replaced all direct `computeSectionFillVertices` calls with the new `computeSectionFill(positions:indices:)` helper that keeps arrays alive |
| 4 | SectionFill emitted 12 duplicate vertices per crossing (double-sided slab) with non-coplanar ribbon geometry | Redundant double-emission + random perpendicular extrusion | Single 6-vertex quad ribbon on the clip plane with in-plane perpendicular direction (`cross(normal, segDir)`); overlay pipeline cull=none handles both sides |

---

## 2. Modified Files

| File | Change |
|------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | `cancelParse()`: added `parseGeneration += 1` as first action. Added `@Published var loadingFileExtension`. Set it in `parseFile()` after `ext` is computed. Clear in `freeCurrentDocument()`. |
| `macos/MMForge/Views/ViewportContainer.swift` | Changed `fileExtension: ""` to `fileExtension: viewModel.loadingFileExtension` in `LoadingStateView` call. |
| `macos/MMForge/Metal/SectionFill.swift` | Removed `thickness` parameter. Emit single 6-vertex quad per crossing triangle with in-plane perpendicular ribbon (`normalize(cross(normal, segDir)) * ribbonHalf`). Added `computeSectionFill(positions:indices:)` helper for safe array-based testing. Removed `assertVertexOnPlane` (moved to test file). |
| `macos/MMForgeTests/ProductizationTests.swift` | All section-fill tests now use `computeSectionFill(positions:indices:)`. Updated expected float counts: 96 → 48 for single triangle, 96 for two. Added `testSectionFill_twoCrossingTriangles` with geometric coplanarity assertions. Added `assertVertexOnPlane` helper. Fixed cube test to clip at Z=0.5 (not Z=0, which coincides with cube face). |
| `macos/MMForge/Views/ContentView.swift` | Removed trailing blank line at EOF (`git diff --check` clean). |

---

## 3. Key Algorithm Change: Section Fill

### Before (double-sided slab, 12 verts/crossing)

```text
For each crossing triangle:
  pA, pB = intersection points on edges
  Emit 12 vertices: 6 "front" + 6 "back"
  Back face = pA + normal*thickness, pB + normal*thickness
  Issue: slab is perpendicular to clip plane, not coplanar
```

### After (single in-plane ribbon, 6 verts/crossing)

```text
For each crossing triangle:
  pA, pB = intersection points on edges (exactly on plane)
  segDir = pB - pA
  inPlanePerp = normalize(cross(clipPlaneNormal, segDir)) * ribbonHalf
  Emit 1 quad (6 verts): pA ± inPlanePerp, pB ± inPlanePerp
  All vertices coplanar with clip plane
```

The overlay pipeline uses Metal's default `cullMode = .none`, so the single-sided quad is visible from either camera direction.

---

## 4. Verified Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge build` | **BUILD SUCCEEDED** |
| `xcodebuild -scheme MMForge test` | **123 tests pass, 0 failures** (+1 new geometric test) |
| `git diff --check` | **Clean** (trailing blank line fixed) |
| `cargo test --workspace` | **336 tests pass** (unchanged) |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |

### Test Suite Breakdown

| Suite | Tests | Change |
|-------|-------|--------|
| ProductizationTests | 29 | **+1** (two-crossing-triangles) |
| AsyncParse | 12 | 0 |
| Annotation | 44 | 0 |
| Picking | 22 | 0 |
| Transform | 11 | 0 |
| MetalUniformLayout | 1 | 0 |
| BVHPicking (standalone) | 12 | 0 |
| Rust (all crates) | 336 | 0 |
| **Total** | **459** | **+1** |

### ProductizationTests Section-Fill Coverage

| Test | What It Verifies |
|------|-----------------|
| `testSectionFill_cubeClippedAtZHalf` | 4 crossing triangles on unit cube, all vertices on Z=0.5 plane (per-vertex assertion) |
| `testSectionFill_noIntersection` | Triangle entirely above plane → empty result |
| `testSectionFill_disabledClipPlane` | w=-999999 → empty result |
| `testSectionFill_singleTriangleCrossing` | 1 crossing = 48 floats, all 6 vertices on Z=0 (per-vertex assertion) |
| `testSectionFill_twoCrossingTriangles` | 2 crossings = 96 floats, all 12 vertices on Z=0 (per-vertex assertion) |

---

## 5. Known Issues (Unchanged)

1. Section fill uses a constant ribbon half-width (0.005 units) — may be too thin for very large or very small models.
2. Assembly node count badge shows direct children only, not total descendants.
3. Inspector DisclosureGroup state is not persisted across sessions.

---

## 6. Review Focus

| File | Area | Reason |
|------|------|--------|
| `MMForgeDocument.swift:616` | `cancelParse()` | `parseGeneration += 1` before `mmf_cancel_token_cancel` |
| `SectionFill.swift:80` | `inPlanePerp` computation | `cross(clipNormal, segDir)` ensures ribbon lies in clip plane |
| `ProductizationTests.swift:54` | `assertVertexOnPlane` | Per-vertex geometric coplanarity check |
| `ProductizationTests.swift:62` | `computeSectionFill(positions:indices:)` | Array-lifetime-safe helper, no dangling pointers |
