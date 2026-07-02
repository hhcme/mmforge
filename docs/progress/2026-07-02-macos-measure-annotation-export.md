# macOS Measurement, Annotation & Export

**Date**: 2026-07-02
**Scope**: Phase 5 — unified measurement, annotation model, PDF export.

## Summary

Implemented a unified annotation system covering 2D/3D measurement, text/arrow/
dimension annotations, and PDF export. The architecture uses a single
`Annotation` data model in Swift, dual rendering (Core Graphics for 2D, Metal
overlay for 3D), and a `CGAffineTransform`-based coordinate pipeline for
screen↔world conversion.

## New Files

### `macos/MMForge/Document/Annotation.swift`

- **`AnnotationKind`** enum: `.measurement`, `.angleMeasurement`,
  `.areaMeasurement`, `.dimension`, `.textAnnotation`, `.arrowAnnotation`
- **`Annotation`** struct: `Identifiable`, `Equatable`, with `kind` + `color`
- **`MeasurementType`** enum: `.distance`, `.angle`, `.area` with instructions
- **`Geometry2D`** enum: pure geometry utilities:
  - `closestPointOnSegment` — project + clamp to segment
  - `closestPointOnCircle` — normalize direction from center
  - `closestPointOnArc` — project to arc with endpoint fallback
  - `closestPointOnPolyline` — min over all segments
  - `distance` — Euclidean distance
  - `signedArea` / `area` — shoelace formula
  - `centroid` — arithmetic mean of vertices
  - `angleDegrees` — angle between two vectors via atan2
  - `findSnapTarget` — snap-to-entity from draw commands

### `macos/MMForgeTests/AnnotationTests.swift` (27 tests)

- closestPointOnSegment (midpoint, clamp start/end, degenerate)
- closestPointOnCircle (inside, on, far away)
- closestPointOnArc (on arc, outside → endpoint)
- closestPointOnPolyline (single, multi, empty)
- distance (simple, same point)
- area (unit square, triangle, empty, CW vs CCW)
- centroid (unit square, empty)
- angle (right angle, straight, 45°)
- Annotation model (creation, equality, inequality)
- MeasurementType instructions

## Modified Files

### `DrawingView.swift`

- **Coordinate conversion**: `screenToWorld(_:)` and `worldToScreen(_:)` using
  the existing `worldToScreenTransform().inverted()`.
- **Click handling**: `mouseDown(with:)` with measurement mode, snap-to-entity,
  and three protocols:
  - Distance: two-click (start → end)
  - Angle: three-click (vertex → ray1 → ray2)
  - Area: multi-click polygon, close by clicking near first point
- **Annotation overlay rendering** (`drawAnnotations`):
  - Measurement lines with dashed stroke, cross markers, distance labels
  - Angle rays with arc and degree label
  - Area polygon with semi-transparent fill and area label at centroid
  - Dimension lines with extension lines, arrowheads, and text
  - Text annotations with background rect
  - Arrow annotations with filled arrowhead and optional label
  - Pending annotation preview (cyan markers, dashed polygon/ray preview)
- **PDF export**: `exportPDF(annotations:)` renders all commands and annotations
  into a `CGPDFContext` on A4 landscape.
- **NSViewRepresentable** updated with all annotation/measurement state.

### `MMForgeDocument.swift` (DocumentViewModel)

- **New state**: `annotations`, `pendingAnnotationPoint`, `pendingPolygonPoints`,
  `measurementType`, `snapEnabled`
- **Annotation actions**: `add2DMeasurement`, `add2DAngleMeasurement`,
  `add2DAreaMeasurement`, `addTextAnnotation`, `addArrowAnnotation`,
  `addDimensionAnnotation`, `removeAnnotation`, `clearAnnotations`
- **Drawing2DAnnotationDelegate** conformance: bridges DrawingView click events
  to DocumentViewModel
- **PDF export**: `exportPDF()` presents NSSavePanel, writes 2D drawing with
  annotations via `CGPDFContext`. Includes `drawPDFCommand` and
  `drawPDFAnnotation` for PDF-specific rendering.

### `InspectorPanel.swift`

- Expanded Measure tab with:
  - Measurement type picker (Distance / Angle / Area) for 2D
  - Snap-to-entity toggle
  - Context-sensitive instructions per measurement type
  - Separate sections for 3D measurements and 2D annotations
  - Annotation list with color swatches, computed labels (distance, angle,
    area), and per-item delete

### `ViewportContainer.swift`

- Passes all annotation state to `Drawing2DViewRepresentable`.

### `project.pbxproj`

- Added `Annotation.swift` to app target
- Added `AnnotationTests.swift` to test target

## Architecture

```
User click (screen coords)
    ↓
Drawing2DView.mouseDown
    ↓ screenToWorld (CGAffineTransform.inverted)
    ↓ findSnapTarget (Geometry2D.closestPointOn*)
    ↓
Drawing2DAnnotationDelegate.didCompleteMeasurement/...
    ↓
DocumentViewModel.add2DMeasurement/...
    ↓ @Published annotations array
    ↓
Drawing2DView.drawAnnotations (Core Graphics overlay)
DocumentViewModel.exportPDF (CGPDFContext)
```

## Test Results

- **Rust**: 200 tests pass, 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 60 tests pass (22 Picking + 11 Transform + 27 Annotation),
  0 failures

## Known Limitations

1. **No 3D annotation rendering** — 3D measurement still uses the existing
   Metal overlay. Text/dimension/arrow annotations are 2D-only.
2. **No annotation persistence** — annotations are not saved to file.
3. **No drag-to-reposition** — text annotations are placed once.
4. **PDF export 3D fallback** — falls back to image export for 3D models.
5. **No entity selection** — snap-to-entity finds nearest point but doesn't
   select/highlight the entity.
