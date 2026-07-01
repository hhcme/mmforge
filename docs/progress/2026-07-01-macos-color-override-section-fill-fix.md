# Color Override / Section Fill Fix — Xcode Target, ColorPicker, Section Fill Sync

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Restore Xcode test target, fix color picker, fix section fill
        recalculation, fix C ABI return types

---

## Fixes

### 1. Restore Xcode test target

Re-added MMForgeTests target to project.pbxproj:
- `F10006` — MMForgeTests native target
- `F10007` — Sources build phase with PickingTests.swift
- `F10008` — Configuration list (Debug/Release)
- `F10009/F1000A` — Target dependency + container proxy
- `G10005/G10006` — Debug/Release configurations
- `B10017` — PickingTests.swift file reference
- `C10002` — MMForgeTests.xctest product reference

22 Xcode tests pass.

### 2. Inspector ColorPicker

Replaced the "Reset" button with a full SwiftUI `ColorPicker`:

```swift
ColorPicker("Color", selection: nodeColorBinding(index: index))
```

The `nodeColorBinding` helper converts between `SwiftUI.Color` and
`simd_float4` (used by MetalRenderer).  "Reset Color" button
appears when an override is active.

### 3. Section fill recalculation

Added `refreshSectionFill()` helper that calls
`renderer?.updateSectionFill()` when clip is enabled.  Called after:
- `toggleNodeVisibility`
- `setAllNodesVisible`
- `hideSelectedNode`
- `hideAllNodes`
- `isolateSelectedNode`

### 4. Remove duplicate methods

Removed old duplicate `hideAllNodes`, `isolateSelectedNode`,
`collectDescendants`, `hideOtherNodes` that lacked `refreshSectionFill`.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test-without-building` | ✅ 22/22 pass |

---

## Files Modified

| File | Change |
|------|--------|
| `project.pbxproj` | Restored MMForgeTests target (22 tests) |
| `InspectorPanel.swift` | ColorPicker + `nodeColorBinding` helper |
| `MMForgeDocument.swift` | `refreshSectionFill()` on visibility changes; removed duplicates |
