# Sidebar/Inspector Fixes

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix sidebar selection sync, search matching, isolate logic

---

## Fixes

### 1. Sidebar selection syncs to Metal renderer

`List(selection:)` now uses a custom `selectionBinding` that calls
`viewModel.selectNode(_:)` instead of directly setting `selectedIndex`.
This ensures the renderer's `selectedNodeIndex` is updated when the
user clicks a node in the sidebar.

```swift
private var selectionBinding: Binding<Int?> {
    Binding(
        get: { viewModel.selectedIndex },
        set: { viewModel.selectNode($0) }
    )
}
```

### 2. `matchesSearch` fixed — no invalid `??`

The `??` operator was used on `Bool` (not `Bool?`), which is invalid.
Replaced with explicit `if/else` checks:

```swift
func matchesSearch(_ index: Int) -> Bool {
    guard !searchText.isEmpty else { return true }
    let node = nodes[index]
    if node.name.localizedCaseInsensitiveContains(searchText) { return true }
    if let label = node.geometryLabel,
       label.localizedCaseInsensitiveContains(searchText) { return true }
    return false
}
```

### 3. `isolateSelectedNode` preserves descendants

Now works with assembly nodes (not just geometry nodes):

1. Collects the selected node and ALL its descendants via
   `collectDescendants(_:into:)` recursive helper
2. Hides all geometry nodes NOT in the keep-visible set
3. Assembly selection → all descendant geometry stays visible
4. Leaf selection → only that node stays visible

### 4. Menu enabled states

Existing states are correct:
- Select Root: disabled when not loaded
- Hide Selection: disabled when no selection
- Show All: disabled when nothing hidden

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
| `macos/MMForge/Views/StructureSidebar.swift` | `selectionBinding` custom binding |
| `macos/MMForge/Document/MMForgeDocument.swift` | Fixed `matchesSearch`, `isolateSelectedNode` with `collectDescendants` |
