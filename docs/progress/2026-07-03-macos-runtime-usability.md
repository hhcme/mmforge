# macOS Runtime Usability: Tree Performance, Vertex Upload, Frustum Cache, Depth Bias

**Date**: 2026-07-03
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Performance-profile the macOS layer and apply targeted fixes to
           structure tree O(n²) bottlenecks, vertex upload overhead, frustum
           culling redundancy, and wireframe z-fighting.

---

## 1. Performance Audit Summary

A systematic audit of the macOS codebase identified the following severity-ranked
bottlenecks:

| Severity | Area | Issue |
|----------|------|-------|
| **CRITICAL** | StructureSidebar | `hasChildren()` O(n) scan per row; 1000 nodes = 1M element comparisons/render pass |
| **CRITICAL** | DocumentViewModel | `visibleNodeIndices` recomputed as O(n×depth) every SwiftUI render pass |
| **CRITICAL** | DocumentViewModel | `isNodeVisibleInTree` / `indentLevel` walk parent chain O(depth) per visible row |
| **SERIOUS** | MetalRenderer.upload | Vertex interleave via Swift for-loop (6M assignments for 1M-vert model) |
| **SERIOUS** | MetalRenderer.upload | BVH build copies full mesh data into intermediate Swift Arrays (2× memory) |
| **SERIOUS** | MetalRenderer.draw | Frustum culling recomputed every frame even with static camera |
| **SERIOUS** | MetalRenderer.draw | Wireframe depth-fights with solid surface in solid+wire mode |
| **MODERATE** | DocumentViewModel | `collectDescendants` O(n²) from linear parent-index scan per recursion level |
| **MODERATE** | DocumentViewModel | `geomIdToNodeIdx` map built redundantly in multiple upload paths |
| **MINOR** | DocumentViewModel.cancelParse | Temp file leaks when job thread detached mid-parse |

The fixes below target the highest-impact items achievable without Rust FFI changes.

---

## 2. Fixes Delivered

### 2.1 Structure Tree O(1) Cache (`DocumentViewModel`)

**Before:**
- `hasChildren(i)` → `nodes.contains { $0.parentIndex == i }` — O(n)
- `childrenOf(i)` → `nodes.indices.filter { .. }` — O(n)
- `indentLevel(i)` → walks parent chain — O(depth)
- `collectDescendants` → linear scan per recursion level — O(n²)
- `visibleNodeIndices` → computed property, O(n×depth) every render pass

**After:**
- `_childrenMap: [Int: [Int]]` — built once from `nodes` via single O(n) pass; all queries O(1)
- `_nodeDepth: [Int: Int]` — built via BFS in same pass; `nodeDepth(i)` is O(1)
- `_cachedVisibleIndices: @Published [Int]` — precomputed BFS snapshot; `visibleNodeIndices` returns cached array
- `refreshVisibleIndices()` — called only when `expandedIndices`, `searchText`, or `nodes` change
- Lazy auto-rebuild: `_lastNodeCount` sentinel triggers cache rebuild if nodes count changes between queries (handles test code that sets `vm.nodes` directly)
- `InspectorPanel.nodeDepth()` and `StructureSidebar.indentLevel()` now delegate to O(1) `viewModel.nodeDepth()`

**Files:** `MacOS/MMForge/Document/MMForgeDocument.swift`, `InspectorPanel.swift`, `StructureSidebar.swift`

**Impact:** For 1000-node tree, sidebar render goes from ~500K element comparisons to ~1000 array reads. Visible-node computation goes from O(n²) worst-case to O(n) amortized.

### 2.2 Vertex Upload — For-loop → memcpy (`MetalRenderer.upload`)

**Before:**
```swift
for i in 0..<vertexCount {
    ptr[i*6+0] = positions[i*3+0]; ptr[i*6+1] = positions[i*3+1];
    ptr[i*6+2] = positions[i*3+2]; ptr[i*6+3] = normals[i*3+0]; ...
}
```

**After:**
```swift
let dst = vb.contents()
dst.copyMemory(from: positions, byteCount: posBytes)
dst.advanced(by: posBytes).copyMemory(from: normals, byteCount: posBytes)
```

**Impact:** For 1M vertices, ~6M Swift assignments replaced by two memcpy calls.

### 2.3 BVH Build — Pointer Direct (`Picking.buildMeshBVH2`)

**Before:** Copied positions+indices into intermediate `[Float]` and `[UInt32]` arrays, then `buildMeshBVH` copied them AGAIN into `MeshBVH`.

**After:** New `buildMeshBVH2(positions:vertexCount:indices:indexCount:)` accepts `UnsafePointer` directly. A single copy populates the stored `MeshBVH` arrays. The original `buildMeshBVH` is kept for test compatibility.

**Impact:** Removes 2× intermediate allocation (from 3 copies to 1).

### 2.4 Frustum Culling Cache (`MetalRenderer`)

**Before:** `updateFrustumCulling()` recomputed the 6-plane frustum and tested all mesh AABBs every frame, even when the camera was stationary.

**After:** `CamHash` struct captures (aspect, yaw, pitch, distance, target). If equal to previous frame, the entire frustum update is skipped. Resets on any camera movement.

**Impact:** For static-camera viewing (common when inspecting a part), saves O(n) AABB-plane tests (6000 plane tests/frame for 1000 meshes at 60fps = 360K/sec).

### 2.5 Wireframe Depth Bias (`MetalRenderer.draw`)

**Before:** Solid+wire mode rendered solid then wireframe with identical depth compare. Coincident wireframe edges z-fought with the underlying surface.

**After:** Wireframe pass in solid+wire mode now calls `encoder.setDepthBias(0.001, slopeScale: 1.0, clamp: 0.001)` before the wireframe draw and resets after.

**Impact:** Wireframe edges are now consistently visible on top of solid surfaces.

### 2.6 Temp File Tracking (`DocumentViewModel`)

**Before:** `cancelParse()` detached the parse thread but the temp file from `write(to:)` leaked until OS /tmp cleanup.

**After:** `_parseTmpURL` tracks the temp file. `freeCurrentDocument()` (called by `cancelParse` and `parseFile`) removes it via `try? FileManager.default.removeItem`.

---

## 3. Modified Files

| File | Change |
|------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | Added `_childrenMap`, `_nodeDepth`, `_cachedVisibleIndices`, `_lastNodeCount`, `_parseTmpURL`. Added `rebuildTreeCaches()`, `refreshVisibleIndices()`, `_rebuildIfNodesChanged()`. Replaced O(n) `hasChildren`/`childrenOf`/`nodeDepth`/`collectDescendants` with O(1) cached versions. `visibleNodeIndices` now returns precomputed snapshot with dirty-check. |
| `macos/MMForge/Views/InspectorPanel.swift` | `nodeDepth()` delegates to `viewModel.nodeDepth()` (O(1)). |
| `macos/MMForge/Views/StructureSidebar.swift` | `indentLevel()` delegates to `viewModel.nodeDepth()` (O(1)). |
| `macos/MMForge/Metal/MetalRenderer.swift` | `upload()`: for-loop → double memcpy. `CamHash` struct for frustum caching. `setDepthBias` in solid+wire mode. |
| `macos/MMForge/Metal/Picking.swift` | Added `buildMeshBVH2(positions:vertexCount:indices:indexCount:)` — pointer-based BVH build. |

---

## 4. Verified Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge test` | **125 tests pass, 0 failures** |
| `cargo test --workspace` | **336 tests pass** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |
| `git diff --check` | **Clean** |

---

## 5. Known Issues (Unchanged)

1. Temp file write in `parseFile` remains a synchronous I/O on MainActor — fix requires Rust FFI changes (in-memory parse API).
2. `buildDTO` runs O(N+M) FFI calls on MainActor — fix requires a binary serialization layer in the Rust side.
3. Streaming progress uses chunk index, not byte count; uneven chunk sizes produce non-linear progress bar movement.
4. `backToFrontIndices` transparent-mode sort is still O(n log n) per frame.
