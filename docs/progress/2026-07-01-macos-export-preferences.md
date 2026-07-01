# macOS Export & Preferences — Screenshot + AppStorage

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Screenshot/image export via Metal texture readback +
        persistent viewer preferences via @AppStorage

---

## Summary

The macOS viewer can now export the current viewport as PNG or JPEG
via a Metal texture readback pipeline.  Viewer preferences (grid,
axes, anti-aliasing) are persisted across sessions via `@AppStorage`.

---

## Image Export

### MetalRenderer.captureImage()

Reads the current drawable texture via a blit command encoder:

1. Creates a `.storageModeShared` buffer
2. Blits the drawable texture to the buffer
3. Creates `CGImage` from the pixel data (BGRA format)
4. Returns `NSImage`

The capture is synchronous and blocks until the blit completes.

### DocumentViewModel.exportImage()

1. Calls `renderer.captureImage()` → `NSImage`
2. Presents `NSSavePanel` with PNG/JPEG content types
3. Default filename: `mmforge_view.{format}`
4. Saves via `NSBitmapImageRep`

### Menu Command

- **Export → Export Image…** (Cmd+E)
- Disabled when no model is loaded

### MTKView Reference

`MetalRenderer` now stores a `weak var mtkView: MTKView?` reference,
set by `ViewportContainer.makeNSView`.  Required for texture readback.

---

## Preferences

### AppPreferences (AppStorage)

```swift
struct AppPreferences {
    @AppStorage("showGrid") static var showGrid: Bool = true
    @AppStorage("showAxes") static var showAxes: Bool = true
    @AppStorage("antiAliasing") static var antiAliasing: Bool = true
    @AppStorage("exportFormat") static var exportFormat: String = "png"
    @AppStorage("exportScale") static var exportScale: Double = 1.0
}
```

Persisted in `UserDefaults.standard` across app launches.

### DocumentViewModel Bridge

Computed properties bridge to `AppPreferences`:

```swift
var showGrid: Bool {
    get { AppPreferences.showGrid }
    set { AppPreferences.showGrid = newValue }
}
```

### InspectorPanel Settings Tab

Display toggles now use `$viewModel.showGrid` / `showAxes` /
`antiAliasing` instead of `.constant(true)`.

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
| `MetalRenderer.swift` | `weak var mtkView`, `captureImage()` via blit readback |
| `MMForgeDocument.swift` | `AppPreferences` struct, `exportImage()`, display computed props |
| `InspectorPanel.swift` | Display toggles bound to `AppPreferences` |
| `MMForgeApp.swift` | `ExportCommandsView` with Cmd+E |
| `ViewportContainer.swift` | Store `renderer.mtkView` reference |
