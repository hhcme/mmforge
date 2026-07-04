# macOS Runtime Usability — Review Fixes

**Date**: 2026-07-03 (updated 2026-07-05)
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Fix regression and correctness issues from the runtime usability
           optimization round: vertex buffer layout, frustum cache invalidation,
           O(n²) descendant scan, @Published render-cycle mutation,
           BFS→DFS tree ordering, and removeFirst() O(n) shifts.

---

## 1. Issues Fixed

| # | Issue | Fix |
|---|-------|-----|
| 1 | `upload()` wrote positions+normals as two contiguous slabs but vertexDescriptor expects interleaved stride=24/offset=12 | Restored interleaved layout with 12-byte chunk memcpy per vertex (pos chunk@offset 0, normal chunk@offset 12). Verified by reading back GPU buffer contents in test. |
| 2 | Frustum culling `CamHash` cache not invalidated on `clearMeshes`/`upload`/`setSceneBounds` | Added `invalidateFrustumCache()` called from all three; `frustumSkipCount` counter proves cache hit/skip behavior in test. |
| 3 | `InspectorPanel.collectDescendants` used O(n) nodes.enumerated() scan | Replaced with `viewModel.childrenOf(index)` (O(1) via `_childrenMap`). |
| 4 | `visibleNodeIndices` getter mutated @Published during SwiftUI body evaluation | Split: getter returns cached `_cachedVisibleIndices` only; `.onChange(of: searchText)` triggers explicit `refreshVisibleIndices()`. |
| 5 | `DocumentViewModel.collectDescendants` still used O(n²) parent-scan (line 794) | Replaced with `childrenOf(index)` recurse via `_childrenMap`. |
| 6 | `refreshVisibleIndices` used BFS, producing wrong tree order | Changed to DFS preorder (stack-based, push children reversed). Root→A→A1→B (not BFS: Root→A→B→A1). |
| 7 | `rebuildTreeCaches` and `refreshVisibleIndices` used `removeFirst()` (O(n) shift per element) | Cursor-index pattern: `var head = 0; while head < queue.count { let cur = queue[head]; head += 1 }` |
| 8 | Vertex-layout and frustum-cache tests were no-crash only, not verifying behavior | Vertex test reads back MTLBuffer contents and asserts 18 specific float values. Frustum test uses `frustumSkipCount` to assert cache-hit progression and clearMeshes reset. |
| 9 | DFS order not tested for sibling+grandchild scenario | Added `testVisibleNodeIndices_dfsPreorder` (Root→A→A1→B) and `testVisibleNodeIndices_collapseHidesGrandchild`. Existing tests now assert order (not `.sorted()`). |

---

## 2. Modified Files

| File | Change |
|------|--------|
| `macos/MMForge/Metal/MetalRenderer.swift` | `upload()`: stride-based interleaved memcpy. `invalidateFrustumCache()` added; called from `clearMeshes`, `upload`, `setSceneBounds`. `frustumSkipCount` counter. `getGPUMeshes()` accessor for testing. |
| `macos/MMForge/Document/MMForgeDocument.swift` | `refreshVisibleIndices`: BFS→DFS preorder with cursor-based stack traversal. `rebuildTreeCaches`: `removeFirst()`→cursor index. `collectDescendants`: `nodes.enumerated()`→`childrenOf()`. `visibleNodeIndices` getter: pure read, no mutation. Removed `_lastSearchText`/`_lastExpanded`. |
| `macos/MMForge/Views/StructureSidebar.swift` | `.onChange(of: viewModel.searchText)`→`refreshVisibleIndices()`. |
| `macos/MMForge/Views/InspectorPanel.swift` | `collectDescendants`: `viewModel.childrenOf()` O(1). |
| `macos/MMForgeTests/ProductizationTests.swift` | Vertex test: reads MTLBuffer, asserts 18 floats. Frustum test: uses `frustumSkipCount`, asserts 3-value progression. DFS test: asserts `[0,1,3,2]` order. Collapse test: asserts `[0,1,2]`. Existing visible-node tests: removed `.sorted()`. |

---

## 3. Verified Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge test` | **129 tests pass, 0 failures** (+4: vertex readback, frustum count, DFS order, collapse) |
| `cargo test --workspace` | **336 tests pass** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |
| `git diff --check` | **Clean** |

| Suite | Tests | Change |
|-------|-------|--------|
| ProductizationTests | 35 | **+4** (vertex layout, frustum cache, DFS order, collapse) |
| All other suites | 94 | 0 |
| **Total Xcode** | **129** | **+4** |

---

## 4. Review Focus

| File | Area | Reason |
|------|------|--------|
| `DocumentViewModel.swift:1205-1232` | `refreshVisibleIndices` | DFS preorder (stack, children reversed) + cursor-based traversal |
| `DocumentViewModel.swift:794-801` | `collectDescendants` | `childrenOf(index)` O(1) instead of `nodes.enumerated()` O(n) |
| `DocumentViewModel.swift:1188-1198` | `rebuildTreeCaches` | Cursor `head` index instead of `removeFirst()` |
| `MetalRenderer.swift:398-407` | `upload()` interleave loop | 12-byte pos+normal chunks at stride=24 |
| `MetalRenderer.swift:560-566` | `updateFrustumCulling` | `frustumSkipCount += 1` on cache hit |
| `ProductizationTests.swift:627-675` | Vertex layout test | Reads MTLBuffer.contents() and asserts 18 floats |
| `ProductizationTests.swift:677-710` | Frustum cache test | Asserts `frustumSkipCount` progression 0→1→2→0 |
| `ProductizationTests.swift:712-753` | DFS order + collapse tests | Asserts exact preorder [0,1,3,2] and collapsed [0,1,2] |
