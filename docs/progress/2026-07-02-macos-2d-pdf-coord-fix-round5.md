# 2D PDF Coordinate Transform Fix (Round 5)

**Date**: 2026-07-02
**Scope**: Fix PDF coordinate transform so world top renders above world bottom.

## Issue Fixed

### pdfPageTransform d value

**Problem**: The `pdfPageTransform` used `d: -s` which, combined with the
page-level Y-flip in `renderPDF`, produced a composite transform where world
top appeared at the bottom of the page.

**Root cause**: Swift's `CGAffineTransform.concatenating` applies the receiver
first, then the argument.  So `yFlip.concatenating(w2d)` = "apply yFlip, then
w2d" = `w2d * yFlip` in matrix math.  The CGContext chain
`translate(0,pageH); scale(1,-1); concatenate(w2d)` produces
`translate * scale * w2d` = `yFlip * w2d` in matrix multiplication.

The composite `yFlip * w2d` where `w2d.d = -s` gave `composite.d = +s`,
which maps world top (large Y) to large composite Y (bottom of image).

**Fix**: Changed `pdfPageTransform` to use `d: +s` (positive).  The composite
`yFlip * w2d` now has `composite.d = -s`, mapping world top to small composite
Y (top of image).  The formula `ty = originY + s * wb.maxY` positions the
drawing centered on the page.

## Verified via CGContext chain

Tested the actual CGContext transform chain (translate, scale, concatenate)
with makeImage() pixel inspection:
- Red rect at world y=80-100 → appears at image rows 98-106 (near top) ✓
- Blue rect at world y=0-20 → appears at image row 390 (near bottom) ✓
- Red is above blue = world top visually above world bottom ✓

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 77 tests pass, 0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/DrawingView.swift` | pdfPageTransform d: +s, updated comment |
| `macos/MMForgeTests/AnnotationTests.swift` | Corrected composite formula, fixed test assertions |
