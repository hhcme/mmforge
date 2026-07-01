# Export & Preferences Polish — Remove Dead Toggles, Fix Nil Guard

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Remove non-functional preference toggles, fix silent nil
        in saveImage

---

## Fixes

### 1. Remove `showGrid` / `showAxes` toggles

These toggles were persisted via `@AppStorage` but never wired to
the Metal renderer — they had no visible effect.  Removed from:

- `InspectorPanel.swift` Settings tab — Display section removed
- `AppPreferences` — `showGrid` and `showAxes` properties removed
- `DocumentViewModel` — `showGrid` and `showAxes` computed properties removed

### 2. Fix `saveImage` nil imageData guard

**Before**: `imageData?.write(to: url)` silently did nothing when
`imageData` was nil (PNG/JPEG encoding failed).

**After**: Explicit `guard let imageData = ...` with `exportError`
set on failure:

```swift
guard let imageData = isPNG
    ? bitmapRep.representation(using: .png, properties: [:])
    : bitmapRep.representation(using: .jpeg, properties: [...])
else {
    exportError = "Failed to encode image as \(isPNG ? "PNG" : "JPEG")."
    return
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
| `xcodebuild test-without-building` | ✅ 22/22 pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `MMForgeDocument.swift` | Removed `showGrid`/`showAxes` from `AppPreferences` + ViewModel; fixed `saveImage` nil guard |
| `InspectorPanel.swift` | Removed Display section with dead toggles |
