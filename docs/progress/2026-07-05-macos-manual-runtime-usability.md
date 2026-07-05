# macOS Manual Runtime Usability — Round 2: Use-After-Free + SectionFill Hardening

**Date**: 2026-07-05
**Agent**: Opencode (deepseek-v4-pro)
**Build**: Debug (Xcode DerivedData)
**Summary**: Fixed DXF Drawing2DView use-after-free (B19), hardened SectionFill
            ear-clipping fallback, added 7 new tests, full suite at 142/142.

---

## 1. Fixes Applied

### 1.1 B19 — Drawing2DView Use-After-Free (CRITICAL) — FIXED

**Files**: `DrawingView.swift`, `ViewportContainer.swift`, `MMForgeDocument.swift`

`Drawing2DView` held a raw `OpaquePointer?` (`documentPointer`) borrowed from
`DocumentViewModel.rustDoc`.  When `freeCurrentDocument()` called
`mmf_document_free(doc)`, the NSView still held the dangling pointer.  Any
subsequent `draw(_:)` triggers (`needsDisplay`) would call
`spatiallyCulledCommands` → `mmf_draw_spatial_query(doc, ...)` on freed memory.

**Fix**: Replaced `OpaquePointer?` with generation-guarded closure:

```
Before:
  var documentPointer: OpaquePointer?    // raw — no safety

After:
  var spatialQueryFunc: ((Double,Double,Double,Double)->[Int]?)?  // safe
```

`DocumentViewModel.spatialQueryFunc` creates a closure that captures:
- `rustDoc` — the current document pointer
- `parseGeneration` — counter bumped BEFORE any `freeCurrentDocument()` call

Before each spatial query, the closure checks `self.parseGeneration == capturedGen`.
If `parseGeneration` changed (doc was freed), it returns `nil` — same as "spatial
index unavailable", triggering the safe full-draw fallback.

### 1.2 SectionFill Ear-Clipping Fallback — HARDENED

**File**: `SectionFill.swift`

**Before**: On ear-clipping stall, immediately fell back to fan triangulation
from vertex 0.  For self-intersecting or degenerate contours, fan triangulation
produces overlapping/extraneous triangles.

**After**: Three-stage strategy:
1. Ear clipping on the raw contour
2. On stall → `cleanIndices()`: dedup consecutive near-identical vertices,
   remove collinear midpoints, check wrap-around
3. Retry ear clipping on cleaned indices
4. If still stalled → return `[]` (skip contour — no triangles emitted)

The `cleanIndices()` helper is private to `SectionFill.swift`, running
O(n) without allocation beyond the result array.

### 1.3 testSectionFill_hopelesslyDegenerate — Semantic Assertion FIXED

Original test used vacuous `XCTAssertTrue(result.isEmpty || result.count > 0)`.
Replaced with an all-colinear contour (4 points on X-axis at Z=0):
- Ear clipping finds no ear (all signed areas = 0)
- `cleanIndices` removes all midpoints → <3 points remain → returns `[]`
- **Assert**: `XCTAssertTrue(result.isEmpty, ...)`

Validated: produces empty result, proving the "skip degenerate contour" path
works end-to-end.

Added companion test `testSectionFill_bowtie_earClipsAsSimplePolygon`:
- Bow-tie (0,0)→(1,1)→(1,0)→(0,1) at Z=0
- Ear clipping succeeds (2 triangles = 48 floats)
- **Asserts**: vertex count, stride (8 floats), coplanarity (Z=0), bounds
  (all x∈[-1,2], y∈[-1,2]), finiteness

---

## 2. Verification Suite

### 2.1 Automated Tests

| Suite | Count | Result |
|-------|-------|--------|
| XCTest (xcodebuild test) | 142 | **all pass** |
| cargo test --workspace | 336 | **all pass** |
| cargo clippy --workspace -- -D warnings | — | **0 warnings** |
| cargo fmt --all --check | — | **clean** |
| git diff --check | — | **clean** |

### 2.2 CLI Perf Baseline (`bash docs/scripts/perf-baseline.sh`)

| Format | Status | Details |
|--------|--------|---------|
| STEP   | **PASS** | PQ-04909-A.STEP (36K): 0.2ms avg, 1 node, format=STEP |
| IGES   | **PASS** | box.igs (16K): 0.2ms avg, 1 node, format=IGES |
| STL    | **PASS** | box.stl (4.0K): 0.3ms avg, 2 nodes, 12 triangles |
| glTF   | **FAILED** | box.gltf (4.0K): benchmark fails ("needs OCCT"), info returns `error: not a valid STL file` — glTF is NOT supported in CLI; macOS bridge tests cover glTF parsing (`crates/mmforge-bridge/src/gltf_parser.rs`: `parse_minimal_gltf_with_data_uri`, `gltf_multi_root_gets_synthetic_assembly`, `gltf_single_root_no_assembly`, `parse_gltf_cancellation_returns_error`) |
| DXF    | **PASS** | test.dxf (4.0K): 0.1ms avg, 1 node, format=DXF |

### 2.3 New XCTest Tests Added

| Test | What It Verifies |
|------|-----------------|
| `testDXF_spatialQueryReturnsNilAfterCancel` | Gen-guarded closure → nil after `cancelParse` |
| `testDXF_reopen_invalidatesOldLease` | Old lease stale after reopen; new lease works |
| `testDXF_closeThenSpawnView_noCrash` | Drawing2DView creation with nil doc → no crash |
| `testSectionFill_dupVertex_cleanedAndTriangulated` | 5-vert with dup → ear-clip 72 floats |
| `testSectionFill_collinearVertex_cleanedAndTriangulated` | 5-vert with collinear → ear-clip 72 floats |
| `testSectionFill_bowtie_earClipsAsSimplePolygon` | Bow-tie → 48 floats, coplanar, in-bounds |
| `testSectionFill_hopelesslyDegenerate_skipped` | All-colinear → empty (cleanup→skip path) |

---

## 3. macOS App Manual Verification — BLOCKED/PENDING

Attempted to automate GUI testing via:
- `open -a /path/to/MMForge.app /path/to/file` — app launched but no document window
- `osascript` → `tell application "MMForge" to open POSIX file …` — no effect
  (SwiftUI DocumentGroup app, no AppleScript dictionary)
- `NSWorkspace.open([fileURL], withApplicationAt: appURL)` — returned success
  but the app does not create a visible document window from command-line
  invocation (custom UTType identifiers not registered with Launch Services
  for Debug build)

The app launches and runs (PID confirmed via `pgrep`).  A "Debug Console"
`Window` scene renders alongside the `DocumentGroup`, but no document window
appeared when opening files via command-line tools.  No real MMForge
document-viewport screenshots were captured.

**Manual testing of the following is BLOCKED until a developer interactively
opens the app with ⌘O and verifies each item visually:**

| Format | Fixture | What Needs Manual Check |
|--------|---------|------------------------|
| STEP   | `crates/mmforge-geometry/testdata/PQ-04909-A.STEP` | Load, structure tree, render modes, camera, selection, measurement, clip plane, section fill, export |
| STL    | `testdata/stl/box.stl` | Load, 12 triangles, 2 nodes, viewport rendering |
| DXF    | `crates/mmforge-format-dxf/testdata/test.dxf` | 2D canvas, layer visibility toggle, measurement annotation, PDF export |
| glTF   | `testdata/gltf/box.gltf` | Load, 3D viewport (bridge tests `parse_minimal_gltf_with_data_uri` etc. cover parse pipeline) |
| IGES   | `crates/mmforge-geometry/testdata/box.igs` | Load, structure tree |
| User model | (any real-world STEP/DXF) | Full workflow: open, navigate tree, view modes, camera, select, measure, properties, layers, export, clip+section fill, reopen another file, cancel load |

---

## 4. Files Changed

| File | Description |
|------|-------------|
| `DrawingView.swift` | Replace `documentPointer` with `spatialQueryFunc`; update representable |
| `ViewportContainer.swift` | Pass `viewModel.spatialQueryFunc` |
| `MMForgeDocument.swift` | Change `parseGeneration` to `internal`; add `spatialQueryFunc` property |
| `SectionFill.swift` | Replace fan fallback with `cleanIndices()` + retry + skip |
| `AsyncParseTests.swift` | 3 DXF UAF safety tests |
| `ProductizationTests.swift` | 4 section fill tests (dup, collinear, bow-tie, degenerate) |

---

## 5. Remaining Known Issues

| Severity | Issue | Status |
|----------|-------|--------|
| ~~High~~ | ~~B19: Use-after-free in Drawing2DView~~ | **FIXED** |
| High | B16: Inspector `nodeHasVisibleDescendants` tree walk per render | Not yet memoized |
| High | macOS GUI manual verification | **BLOCKED** — app won't open files via CLI; needs interactive ⌘O |
| Medium | B7: Silent MTLBuffer allocation failure in overlay/section fill | Needs error propagation |
| Medium | B8: `captureImage` blocks main thread via `waitUntilCompleted()` | Needs async callback |
| Medium | B9: O(n) frustum culling per frame, no spatial index | GPU-side BVH needed |
| Low | B13: Drop handler discards file-read errors silently | No UI feedback built |
| Low | GUI testing: app lacks AppleScript dictionary for automation | Needs `NSApplicationDelegate.application(_:openFiles:)` |
| Info | glTF CLI unsupported | `mmforge info box.gltf` → "not a valid STL file"; macOS bridge tests cover |
