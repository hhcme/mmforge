# 2D PDF Coordinate Transform Fix (Round 6 — Final)

**Date**: 2026-07-02
**Scope**: Fix PDF coordinate transform with bitmap-pixel verified test.

## Issue Fixed

### pdfPageTransform d value corrected to -s

**Problem**: `pdfPageTransform` used `d: +s` which, combined with the page-level
Y-flip (`translate(0,pageH); scale(1,-1)`), produced output where world top
appeared at the bottom (or outside) the page.

**Root cause**: The CGContext chain `translate(0,pageH) + scale(1,-1) + concatenate(w2d)`
with `w2d.d = +s` maps world y=80-100 to image rows far outside the visible area.

**Fix**: Changed `pdfPageTransform` to use `d: -s`. Verified via CGBitmapContext
pixel inspection:
- Red (world y=80-100) → image rows 10-85 (near top) ✓
- Blue (world y=0-20) → image rows 315-385 (near bottom) ✓
- Red row < Blue row → world top visually above world bottom ✓

### Comments cleaned

Removed all contradictory derivation comments from `pdfPageTransform`. The
method now has a clean doc comment stating the coordinate contract and the
formula, with reference to the bitmap-pixel verified test.

### Test

`testPDFRender_worldTopAboveWorldBottom` now uses CGBitmapContext + makeImage()
pixel inspection:
1. Creates a 400×400 bitmap context
2. Applies the exact same transform chain as `renderPDF`
3. Fills red rect at world top, blue rect at world bottom
4. Scans column x=200 for first red and first blue pixel
5. Asserts red found, blue found, red row < blue row, both inside page

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 77 tests pass, 0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/DrawingView.swift` | pdfPageTransform d=-s, cleaned comments |
| `macos/MMForgeTests/AnnotationTests.swift` | Bitmap-pixel verified test |
