# Sidebar Visibility Menu Fix

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix sidebar visibility menu to use selectedHasHideableGeometry;
        guard isolate against no-geometry nodes

---

## Fixes

### 1. Sidebar menu uses `selectedHasHideableGeometry`

The visibility dropdown menu now only shows "Isolate Selection" and
"Hide Selection" when `viewModel.selectedHasHideableGeometry` is true.
Previously it checked `selectedIndex != nil`, which allowed these
actions on nodes with no geometry descendants.

### 2. `isolateSelectedNode` guards against no-geometry nodes

Added `selectedHasHideableGeometry` guard to `isolateSelectedNode()`.
If the selected node has no geometry descendants, the function returns
early — preventing the accidental hiding of the entire model.

```swift
func isolateSelectedNode() {
    guard let sel = selectedIndex, selectedHasHideableGeometry else { return }
    // ...
}
```

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
| `macos/MMForge/Views/StructureSidebar.swift` | Menu condition: `selectedHasHideableGeometry` |
| `macos/MMForge/Document/MMForgeDocument.swift` | `isolateSelectedNode` guard |
