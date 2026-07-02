# Measurement/Annotation/Export Validation Fixes (Round 4)

**Date**: 2026-07-02
**Scope**: Fix 2D PDF coordinate system issues from cfce475.

## Issue Fixed

### PDF coordinate transform — single combined affine

**Problem**: The previous approach applied a separate CGContext Y-flip
(`translate(0, pageH); scale(1, -1)`) followed by `pdfPageTransform(d: -s)`.
The Y-flip around y=0 offset the result, causing world center to not map to
page center (got (421, 366.5) instead of (421, 297.5)).

**Fix**: `pdfPageTransform` now returns a single combined affine transform
with `d = -s` that embeds the Y-flip.  `renderPDF` applies it via a single
`ctx.concatenate(pdfFrame)` — no separate CGContext transforms.

**Coordinate contract** (documented in source):
- `pageX = s * (worldX - wb.minX) + originX`
- `pageY = -s * worldY + s * wb.maxY + originY`
- World center → page center (verified: (50,25) → (421, 297.5))
- All four world corners inside page rect
- Text renders right-side up (d=-s mirrors screen-like Y-down)
- Non-zero world origin works correctly

**Test correction**: `testPDFFrame_yDirection_worldTopMapsToSmallerPageY`
correctly asserts that with d=-s, world top (y=50) maps to smaller page Y
than world bottom (y=0) — this is the expected Y-flip behavior.  The PDF
viewer renders the page with the drawing's top at the visual top.

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 80 tests pass (22 Picking + 11 Transform + 47 Annotation),
  0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/DrawingView.swift` | Single combined pdfPageTransform, removed separate Y-flip |
| `macos/MMForgeTests/AnnotationTests.swift` | Simplified tests, corrected Y-direction assertion |
