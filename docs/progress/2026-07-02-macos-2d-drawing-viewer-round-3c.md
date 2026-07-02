# 2D Drawing Viewer — Spatial Transform Fix (Round 3c)

**Date**: 2026-07-02
**Scope**: Fix spatial viewport inverse transform to use CGAffineTransform with correct concatenation order.

## Summary

Replaced hand-written spatial viewport inverse transform with a single
`worldToScreenTransform()` method that builds a `CGAffineTransform` from
the exact same chain as `draw(_:)`.  The inverse is computed via
`CGAffineTransform.inverted()`, guaranteeing perfect consistency between
rendering and spatial culling.

## Issue Fixed

### CGAffineTransform Concatenation Order

**Problem**: The previous hand-written inverse transform formula was derived
independently from the `draw(_:)` CGContext calls, leading to inconsistencies
when `panOffset`, `zoomLevel`, or non-zero `worldBounds.midY` were involved.

**Root cause**: `CGAffineTransform.concatenating` applies the receiver first
then the argument (i.e. `t1.concatenating(t2)` = "first t1, then t2"), but
`CGContext.concat` applies the argument first then the current transform.
To match the CGContext call order (T1 translate first, T6 Y-translate last),
the concatenation chain must be `t1.concatenating(t2)...concatenating(t6)`.

**Fix**:
1. Extracted `fitScale(screenBounds:worldRect:)` as a standalone method that
   takes both rects as parameters (avoids depending on `self.bounds` which
   may be resized by Auto Layout in the test host).
2. `worldToScreenTransform(viewBounds:)` builds a `CGAffineTransform` by
   concatenating the 6 transforms in the correct order:
   `t6.concatenating(t5).concatenating(t4).concatenating(t3).concatenating(t2).concatenating(t1)`
   (reversed from the CGContext call order because `CGAffineTransform.concatenating`
   composes differently from `CGContext.concat`).
3. `draw(_:)` now calls `ctx.concatenate(worldToScreenTransform(viewBounds: bounds))`
   instead of 6 separate `ctx.translateBy`/`ctx.scaleBy` calls, guaranteeing
   the rendering and spatial query use the identical transform.
4. `spatiallyCulledCommands` uses `w2s.inverted()` and maps screen corners
   through `CGPoint.applying(s2w)`.

## New Swift Tests (11)

`TransformTests.swift` — validates worldToScreenTransform() under various
pan/zoom/bounds configurations:

- `testNoPanNoZoomWorldCenterMapsToViewCenter` — worldCenter → screenCenter
- `testRoundTripNoPanNoZoom` — world → screen → world round-trip
- `testPanShiftsScreenMapping` — pan offset shifts screen position correctly
- `testZoomScalesMapping` — zoom scales around center, round-trip works
- `testNonZeroWorldMidY` — drawing not centered at origin
- `testTinyWorldBounds` — degenerate bounds (width ≈ 0)
- `testScreenCornersMapToWorldQuadrants` — screen corners → correct world quadrants
- `testYFlipDirection` — screen Y increases downward, world Y increases upward
- `testPanAndZoomRoundTrip` — combined pan + zoom round-trip
- `testMatrixElements` — matrix invariants (no shear, correct signs, worldCenter→screenCenter)
- `testEmptyViewportRoundTrip` — viewport outside drawing still round-trips

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 33 tests pass (22 Picking + 11 Transform), 0 failures

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/DrawingView.swift` | Extracted `fitScale`, `worldToScreenTransform`, `draw(_:)` uses `concatenate`, `spatiallyCulledCommands` uses `inverted()` |
| `macos/MMForgeTests/TransformTests.swift` | New: 11 transform tests |
| `macos/MMForge.xcodeproj/project.pbxproj` | Added TransformTests.swift to test target |
