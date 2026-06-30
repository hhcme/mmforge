# macOS Sidebar & Inspector Enhancements

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Hierarchical tree expand/collapse, search/filter, bulk
        visibility, enhanced inspector stats

---

## Summary

The structure sidebar now supports hierarchical tree navigation with
expand/collapse, text search filtering, and bulk visibility operations.
The inspector shows detailed node properties including children count,
depth, geometry ID, mesh index, and bounding box diagonal.

---

## Sidebar Enhancements

### Tree Expand/Collapse

- `expandedIndices: Set<Int>` tracks which nodes are expanded
- Root expanded by default on file load
- Disclosure triangle (chevron) on nodes with children
- `visibleNodeIndices` computed property filters by expansion state
- `isNodeVisibleInTree(_:)` checks all ancestors are expanded
- Double-click on non-geometry node toggles expansion

### Search/Filter

- `searchText: String` published property
- Search bar with magnifying glass icon and clear button
- `matchesSearch(_:)` checks node name and geometry label
- Search mode shows matching nodes + all their ancestors
- Clear button resets search

### Bulk Visibility Actions

- **Show All** — `setAllNodesVisible()`
- **Hide All** — `hideAllNodes()` (hides all geometry nodes)
- **Isolate Selection** — `isolateSelectedNode()` (hides everything except selected)
- **Hide Selection** — `hideSelectedNode()`
- All accessible via eye icon dropdown menu

### Tree Helpers

- `childrenOf(_:)` — direct children indices
- `hasChildren(_:)` — whether node has any children
- `expandAll()` / `collapseAll()` — bulk expand/collapse

---

## Inspector Enhancements

### Selected Node Section

New fields added:
- **Children** count (from `childrenOf`)
- **Depth** in tree (computed by walking parent chain)
- **Visible** status (Yes/No)
- **Geometry ID** (authoritative GeometryId)
- **Mesh Index** (sorted rank in RenderPacket)
- **Bounding Box Diagonal** (computed from size vector)

### Existing Fields (unchanged)

- Name, Parent, Has Geometry, Geometry Label
- Bounding Box: Min, Max, Size

---

## State Consistency

All visibility state flows through `DocumentViewModel`:
- `hiddenNodeIndices` drives both sidebar eye icons and Metal renderer
- `selectedIndex` drives both sidebar selection highlight and inspector
- `expandedIndices` is sidebar-only (no renderer impact)
- `searchText` is sidebar-only (no renderer impact)

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `MMForgeDocument.swift` | `expandedIndices`, `searchText`, `visibleNodeIndices`, tree helpers, bulk visibility |
| `StructureSidebar.swift` | Full rewrite: search bar, bulk actions, disclosure triangles, filtered tree |
| `InspectorPanel.swift` | Enhanced selected node: children, depth, visibility, geometry ID, mesh index, diagonal |
