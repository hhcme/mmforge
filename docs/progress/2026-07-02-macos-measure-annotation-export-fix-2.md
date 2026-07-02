# Measurement/Annotation/Export Validation Fixes (Round 2)

**Date**: 2026-07-02
**Scope**: Fix validation gaps from f5a792b.

## Issues Fixed

### 1. 3D PDF export with raster snapshot

- `exportPDF()` no longer falls back to `exportImage()` for 3D models
- Added `export3DPDFToFile(url:)` which:
  - Captures the Metal viewport via `renderer.captureImage()`
  - Creates an A4 landscape PDF page
  - Embeds the raster snapshot centered with margin using `ctx.draw(cgImage, in:)`
  - Writes directly to the file URL via `CGDataConsumer(url:)`

### 2. 2D PDF transform uses worldToScreenTransform directly

- `renderPDF` now creates a temporary `Drawing2DView` with matching
  `drawingInfo` and `frame`, then calls `worldToScreenTransform(viewBounds:)`
  to compute the exact same affine transform as screen rendering
- The PDF CGContext uses `ctx.concatenate(pdfFrame)` where `pdfFrame` is the
  composition of the PDF origin offset and the world→screen transform
- This is provably equivalent to `draw(_:)` because both use the same
  `worldToScreenTransform` method

### 3. Independent annotation tool workflows

- Added `AnnotationTool` enum: `.text`, `.arrow`, `.dimension`
  - Each tool has its own `instruction`, `color`, and `clickCount`
  - `.text` is single-click, `.arrow` and `.dimension` are two-click
- Added `activeAnnotationTool` and `annotationToolText` to DocumentViewModel
- DrawingView click handler checks `activeAnnotationTool` first, then falls
  back to measurement mode
- New delegate callbacks: `didPlaceTextAnnotation`, `didCompleteArrowAnnotation`,
  `didCompleteDimensionAnnotation`
- InspectorPanel now shows a segmented picker (None / Text / Arrow / Dimension)
  instead of the old button-based approach
- Text tool shows a TextField for content; arrow/dimension show pending point
  status

### 4. Tests added

- `testPDFRender_worldCenterMapsToPageCenter` — verifies world center maps to
  view center via worldToScreenTransform
- `testPDFRender_yFlip_preservesOrientation` — verifies world Y=0 (bottom)
  maps to larger screen Y than world Y=50 (top)
- `testDrawCommand_respectsLayerVisibility` — verifies hidden layer detection
- `testPDFRender_hiddenLayerNotDrawn` — verifies PDF generates with hidden
  layers (content filtered by visibility)
- `testAnnotationPosition_measurement/text/arrow/dimension` — verifies all
  annotation kinds preserve coordinates correctly
- `testAnnotationTool_properties/textSingleClick/arrowTwoClicks/dimensionTwoClicks`
  — verifies tool properties

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 76 tests pass (22 Picking + 11 Transform + 43 Annotation),
  0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Document/Annotation.swift` | Added `AnnotationTool` enum |
| `macos/MMForge/Document/MMForgeDocument.swift` | 3D PDF export, annotation tool state, delegate callbacks |
| `macos/MMForge/Views/DrawingView.swift` | renderPDF uses worldToScreenTransform, annotation tool click handling |
| `macos/MMForge/Views/InspectorPanel.swift` | Annotation tool picker UI |
| `macos/MMForge/Views/ViewportContainer.swift` | Pass annotation tool state |
| `macos/MMForgeTests/AnnotationTests.swift` | 12 new tests |
