# Empty Document Cleanup — State Consistency Fix

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Ensure empty data path cleans up all state; ContentView
        onChange doesn't skip empty Data

---

## Fixes

### 1. `parseFile(data:)` always cleans up first

Moved `freeCurrentDocument()` before the `data.isEmpty` guard.
Previously, calling `parseFile(data: Data())` would set `state = .empty`
without cleaning up previous meshes, selection, measurements, etc.

```swift
func parseFile(data: Data) {
    freeCurrentDocument()  // always clean up first
    guard !data.isEmpty else {
        state = .empty
        return
    }
    // ... parse
}
```

### 2. ContentView onChange doesn't skip empty Data

Removed `!newData.isEmpty` guard from `onChange`.  Empty data now
triggers `parseFile(data:)` which cleans up and sets `.empty` state.

```swift
.onChange(of: document.fileData) { _, newData in
    viewModel.parseFile(data: newData)  // no isEmpty guard
}
```

Same fix applied to `onAppear`.

---

## What Gets Cleaned Up

`freeCurrentDocument()` clears:
- Rust document handle (`rustDoc`)
- Pending DTO
- Renderer meshes + overlay
- `nodeNames`, `nodes`, `stats`
- `selectedIndex`
- `hiddenNodeIndices`
- `expandedIndices`
- `searchText`
- `measurementMode`
- `measurements`
- `pendingPoint`

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
| `MMForgeDocument.swift` | `freeCurrentDocument()` before isEmpty guard |
| `ContentView.swift` | Remove isEmpty guard from onChange and onAppear |
