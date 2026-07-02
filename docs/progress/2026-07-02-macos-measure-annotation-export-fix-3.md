# Measurement/Annotation/Export Validation Fixes (Round 3)

**Date**: 2026-07-02
**Scope**: Fix validation gaps from 752ec85.

## Issues Fixed

### 1. Annotation tools work without measurementMode

- **Root cause**: `mouseDown(with:)` was gated by `guard measurementMode` on
  line 159, so annotation tool clicks were never processed unless measurement
  mode was also enabled.
- **Fix**: Added `isInteracting` computed property (`measurementMode || activeAnnotationTool != nil`).
  `mouseDown` now checks `isInteracting` instead of just `measurementMode`.
  Annotation tools take priority over measurement when both are active.
- **Cancel logic**: `rightMouseDown` now checks `isInteracting` and cancels
  pending state for whichever mode is active (annotation tool or measurement).

### 2. 2D PDF coordinate transform rewritten

- **Old approach**: Created a temporary `Drawing2DView`, called
  `worldToScreenTransform`, then concatenated with a PDF offset.  This had a
  margin double-counting bug (worldToScreenTransform applies margins internally,
  but the view frame was already margin-reduced).
- **New approach**: `pdfPageTransform` computes the transform directly as a
  `CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: originX - s*wb.minX, ty: originY + s*wb.maxY)`.
  This maps:
  - `pageX = s * (worldX - wb.minX) + originX`
  - `pageY = -s * (worldY - wb.maxY) + originY`
- **Verified invariant**: World center → page center (tested).

### 3. PDF coordinate transform tests

- `testPDFFrame_worldCenterMapsToPageCenter` — world (50,25) → page (421, 297.5)
- `testPDFFrame_worldCornersInsidePage` — all 4 world corners map inside page rect
- `testPDFFrame_yDirectionCorrect` — world Y=0 (bottom) has larger page Y than Y=50 (top)
- `testPDFFrame_nonZeroOrigin` — drawing at (-200,-100)→(200,100) still centered correctly

### 4. Hidden layer filtering: testable `visibleCommands` function

- **Old test**: Checked `layerVisibilityOverrides["hidden"] == false` — doesn't
  prove filtering.
- **New approach**: Extracted `Drawing2DView.visibleCommands(_:layerVisibility:)`
  static function that filters commands by layer visibility.  Same logic used by
  `drawCommand` but testable independently.
- **New tests**:
  - `testVisibleCommands_filtersHiddenLayers` — hidden layer command excluded
  - `testVisibleCommands_defaultVisible` — `visible=false` with no override excluded
  - `testVisibleCommands_overrideShow` — override to visible includes command
  - `testVisibleCommands_emptyInput` — empty input returns empty

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 80 tests pass (22 Picking + 11 Transform + 47 Annotation),
  0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/DrawingView.swift` | `isInteracting`, `pdfPageTransform`, `visibleCommands`, annotation tool click without measurementMode |
| `macos/MMForgeTests/AnnotationTests.swift` | Rewrote PDF transform tests, hidden layer filtering tests |
