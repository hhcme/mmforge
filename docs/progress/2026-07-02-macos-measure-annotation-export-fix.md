# Measurement/Annotation/Export Validation Fixes

**Date**: 2026-07-02
**Scope**: Fix validation gaps from a3a1521 (measurement/annotation/export).

## Issues Fixed

### 1. Export PDF wired to macOS menu (Apple HIG)

- Added "Export PDF…" menu item to `ExportCommandsView` in `MMForgeApp.swift`
- Keyboard shortcut: `Cmd+Shift+E` (complements `Cmd+E` for image export)
- Follows Apple HIG: uses `…` suffix for dialogs, disabled when no document loaded

### 2. Unified PDF export with screen rendering pipeline

- **Deleted** the duplicate `drawPDFCommand` and `drawPDFAnnotation` methods from
  `DocumentViewModel` (170+ lines of duplicated rendering code)
- **Added** `Drawing2DView.renderPDF(ctx:commands:annotations:layerVisibility:
  worldBounds:pageWidth:pageHeight:margin:)` — a static method that reuses the
  exact same `drawCommand` and `drawAnnotations` methods as screen rendering
- This ensures PDF output is pixel-identical to screen: same layer visibility,
  line types, line weights, dash patterns, and annotation overlay rendering
- `DocumentViewModel.exportPDFToFile` now delegates to this single method

### 3. Deleted dead Drawing2DView.exportPDF API

- Removed `Drawing2DView.exportPDF(annotations:)` which had a bug (wrote to
  `NSMutableData` via `CGDataConsumer` but tried to read from an unused `tmpURL`)
- The static `renderPDF` method replaces it, writing directly to the caller's
  `CGContext`

### 4. Text/arrow/dimension annotation creation UI

- Added to InspectorPanel Measure tab (2D mode only):
  - **Text annotation**: TextField + "Add Text" button — places text at the
    pending annotation point
  - **Dimension annotation**: "Add Dimension" button — uses last 2 pending points
    as extension line origins
  - **Arrow annotation**: "Add Arrow" button — uses last 2 pending points as
    tail → head
- All buttons are contextually disabled when no pending points exist

### 5. Unified 2D pending measurement state to DocumentViewModel

- **Removed** DrawingView's local `pendingAnnotationPoint` and
  `pendingPolygonPoints` mutation in click handlers
- **Added** new delegate callbacks: `didSetPendingPoint`, `didSetPendingAngleVertex`,
  `didSetPendingAngleRay`, `didAddPolygonPoint`, `didCancelPending`
- All pending state is now owned and mutated exclusively by `DocumentViewModel`
- DrawingView reads state from its properties (synced via NSViewRepresentable)
  and forwards all mutations through the delegate

### 6. Smoke tests

- `testPDFExport_doesNotCrash` — creates PDF with all 6 annotation kinds,
  verifies non-empty output
- `testPDFExport_withDrawCommands` — creates PDF with a line command + layer
  visibility, verifies non-empty output
- `testAllAnnotationKinds` — verifies all annotation kinds can be created
- `testFindSnapTarget_noCommands` — verifies snap returns nil for empty input

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 64 tests pass (22 Picking + 11 Transform + 31 Annotation),
  0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/App/MMForgeApp.swift` | Added "Export PDF…" menu item (Cmd+Shift+E) |
| `macos/MMForge/Views/DrawingView.swift` | Added static `renderPDF`, delegate protocol extended, deleted dead `exportPDF` |
| `macos/MMForge/Document/MMForgeDocument.swift` | Unified PDF export, extended delegate conformance, removed duplicate PDF renderers |
| `macos/MMForge/Views/InspectorPanel.swift` | Added text/arrow/dimension creation controls |
| `macos/MMForgeTests/AnnotationTests.swift` | Added 4 smoke tests |
