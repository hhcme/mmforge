# macOS Runtime Performance & Rendering — 2026-07-06

**Date**: 2026-07-06
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — B16 + B8 fixed, 4 new tests, 146/146 passing

---

## 1. Fixes Applied

### 1.1 B16 — Inspector `hasVisibleDescendants` Repeated Tree Walk — FIXED

**Files**: `MMForgeDocument.swift:1314-1350`, `InspectorPanel.swift:115`

**Before**: Inspector's `nodeHasVisibleDescendants()` called `collectDescendants()`
recursively every SwiftUI body evaluation, O(subtree size) per render tick.

**After**: ViewModel caches results per node index with generation-based
invalidation.  The cache is invalidated by:

- `hiddenNodeIndices.didSet` — automatic generation bump on any visibility change
- `rebuildTreeCaches()` — explicit bump when nodes/tree structure change
- `freeCurrentDocument()` — explicit `_descendantVisibilityGeneration &+= 1`
  + `_hasVisibleDescendantsCache.removeAll()`, independent of
  `hiddenNodeIndices = []` ordering

Inspector calls `viewModel.hasVisibleDescendants(index)` — O(1) on all
subsequent accesses for the same generation.

### 1.2 B8 — `captureImage` Blocking Main Thread — FIXED

**Files**: `MetalRenderer.swift:933-980`, `MMForgeDocument.swift:1018-1055`

**Before**: `captureImage()` called `cmdBuf.waitUntilCompleted()` on `@MainActor`,
freezing the UI for the GPU readback duration.

**After**: `captureImageAsync()` registers `addCompletedHandler` BEFORE
`cmdBuf.commit()` (Metal requires handler registration before commit to
guarantee delivery).  Uses `withCheckedContinuation` to bridge to async/await.
Export methods use `Task { await renderer.captureImageAsync() }`.

**Verified**: ⌘E (Export Image) opens NSSavePanel with "Export Image" title.
⌘⇧E (Export PDF) triggers save dialog for both 3D and DXF modes.

### 1.3 B9 — O(n) Frustum Culling — MITIGATED

**File**: `MetalRenderer.swift:568-592`

Added `culled.reserveCapacity(gpuMeshes.count / 4)` to reduce Set reallocation
overhead during the O(n) scan.  The existing camera-hash cache (`CamHash`)
prevents recomputation when camera is stationary.

---

## 2. New Tests

| Test | What It Verifies |
|------|-----------------|
| `testHasVisibleDescendants_assemblyWithVisibleChild` | Assembly with visible geometry child → true; leaf geometry → false |
| `testHasVisibleDescendants_hiddenChildReturnsFalse` | Hiding child → false |
| `testHasVisibleDescendants_cacheInvalidatedOnRebuild` | New tree with same `hiddenNodeIndices` → stale cache NOT served |
| `testHasVisibleDescendants_cacheInvalidatedOnCancelParse` | `cancelParse` → nodes empty → `hasVisibleDescendants(0)` asserts false (no stale cache) |

---

## 3. File-Open Verification

All 5 formats create properly-named document windows via `open -a`:

| Format | Window |
|--------|--------|
| STL | `box.stl` |
| DXF | `test.dxf` |
| STEP | `PQ-04909-A.STEP` |
| glTF | `box.gltf` |
| IGES | `box.igs` |

Export Image (⌘E) and Export PDF (⌘⇧E) dialogs confirmed working.

---

## 4. Verification Suite

| Command | Result |
|---------|--------|
| `xcodebuild test -derivedDataPath macos/build` | **146/146 pass** |
| `cargo test --workspace` | **all pass (336)** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `bash docs/scripts/perf-baseline.sh` | STEP/IGES/STL/DXF pass; glTF CLI fails |
| `git diff --check` | **clean** |

---

## 5. Files Changed

| File | Change |
|------|--------|
| `MMForgeDocument.swift` | B16: `hasVisibleDescendants()` + generation-guarded cache + invalidation in `rebuildTreeCaches`/`hiddenNodeIndices.didSet`; B8: async exports |
| `MetalRenderer.swift` | B8: `captureImageAsync()` with `addCompletedHandler` before `commit()`; B9: `reserveCapacity` |
| `InspectorPanel.swift` | B16: replace local subtree walk with `viewModel.hasVisibleDescendants(index)` |
| `ProductizationTests.swift` | 4 new descendant visibility cache tests |

---

## 6. Remaining Issues

| Severity | Issue |
|----------|-------|
| Medium | O(n) frustum culling per camera change — needs GPU-side spatial structure |
| Medium | glTF CLI unsupported; macOS bridge tests cover |
| Low | Structure tree `List` evaluates all `ForEach` rows (no lazy-loading) |
| Low | STEP/IGES produce empty geometry without OCCT |
