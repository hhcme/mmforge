# Sidebar Hide Selection Fix — Assembly Node Support

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix Hide Selection for assembly nodes, menu enabled state,
        inspector visibility display

---

## Fixes

### 1. `hideSelectedNode` supports assembly nodes

Now collects all descendants via `collectDescendants` and hides all
geometry nodes in the subtree.  Works for both leaf geometry nodes
and assembly nodes.

```swift
func hideSelectedNode() {
    guard let sel = selectedIndex else { return }
    var descendants = Set<Int>()
    collectDescendants(sel, into: &descendants)
    for idx in descendants where nodes[idx].hasGeometry {
        hiddenNodeIndices.insert(idx)
    }
    renderer?.setHiddenNodes(hiddenNodeIndices)
}
```

### 2. Menu enabled state uses `selectedHasHideableGeometry`

New computed property checks if the selected node (or its descendants)
has any geometry that can be hidden.  Hide Selection menu item is
disabled when no hideable geometry exists.

### 3. Inspector Visible status for assembly nodes

- **Geometry nodes**: shows "Visible" / "Hidden" based on
  `hiddenNodeIndices`
- **Assembly nodes**: shows "Descendants Visible" / "Descendants
  Hidden" based on whether any descendant geometry is visible

Added `nodeHasVisibleDescendants` helper that checks if any
descendant geometry is not in `hiddenNodeIndices`.

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
| `MMForgeDocument.swift` | `hideSelectedNode` with descendants; `selectedHasHideableGeometry` |
| `InspectorPanel.swift` | Assembly visibility: `nodeHasVisibleDescendants` |
| `MMForgeApp.swift` | Menu disabled via `selectedHasHideableGeometry` |
