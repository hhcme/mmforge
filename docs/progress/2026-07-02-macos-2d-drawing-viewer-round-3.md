# 2D Drawing Viewer — Spatial Culling, LTYPE Dash Patterns, Layer Line Type Inheritance

**Date**: 2026-07-02
**Scope**: macOS 2D DXF drawing viewer validation — round 3

## Summary

Fixed remaining validation gaps in the 2D drawing viewer: wired spatial query
for viewport culling, passed real LTYPE dash patterns through the rendering
pipeline, implemented ByLayer/ByBlock line type inheritance, and fixed default
line width to stable 1px screen logic.

## Changes

### 1. Spatial Query Viewport Culling (Swift + Rust)

- `Drawing2DView.draw(_:)` now computes the visible world-space viewport from
  the current screen bounds, pan, and zoom state
- Calls `RustBridge.spatialQuery()` which invokes `mmf_draw_spatial_query` via
  C ABI to get only the draw command indices whose AABB overlaps the viewport
- Falls back to full iteration when spatial query returns empty (index
  unavailable or viewport outside world bounds)
- `ViewportContainer` passes `viewModel.rustDoc` (document pointer) to
  `Drawing2DViewRepresentable` for spatial query access
- `DocumentViewModel.rustDoc` changed from `private` to `private(set)` to
  expose the pointer

### 2. LTYPE Dash Pattern Pipeline (Rust → C ABI → Swift)

- `FlatDrawCommand` now carries `line_dash: Option<Vec<f64>>` — the resolved
  dash pattern from the LTYPE table
- `build_draw_list()` resolves line types against layer defaults and looks up
  LTYPE dash patterns via `lookup_dash_pattern()`
- New C ABI functions:
  - `mmf_draw_cmd_line_dash_count()` — number of dash pattern elements
  - `mmf_draw_cmd_line_dash()` — reads dash pattern data into caller buffer
- `DrawCommandDTO` cases now carry `lineDash: [Double]` (populated via C ABI)
- `Drawing2DView.lineDashPattern()` uses command's LTYPE-derived dash data
  with fallback to standard name-based patterns (DASHED, DASHDOT, etc.)

### 3. Layer Line Type Inheritance (Rust + Swift)

- `Layer` struct in `mmforge-core/src/drawing.rs` gains `line_type: Option<String>`
- `tables_parser::parse_layers()` reads group 6 (line type name) from LAYER
  table entries; normalizes "Continuous" to `None`
- `build_draw_list()` resolves entity line types via `resolve_line_type()`:
  1. Entity-level line type (group 6), unless "ByLayer"/"ByBlock"
  2. Layer's default line type (from LAYER table)
  3. "Continuous" (solid line) — returns `None`
- New C ABI: `mmf_drawing_layer_line_type()` and `mmf_drawing_layer_color_index()`
- `Drawing2DLayerInfo` now includes `lineType: String?` and proper
  `colorIndex` from the LAYER table (was hardcoded to 7)

### 4. LTYPE Parser Fix (Rust)

- `tables_parser::parse_line_types()` rewritten to correctly track entry
  boundaries using an `in_entry` flag and a `save_entry!` macro
- Previously, the name (code 2) might not be set when saving the previous
  entry because the parser relied on code 0 positions rather than entry state

### 5. Default Line Width Fix (Swift)

- `Drawing2DView.lineWidth()` now returns `1.0 / scale` when no line weight
  is set (weight == 0), producing a stable 1px screen line regardless of zoom
- Previously returned `1.0` in world coordinates, which scaled with zoom and
  became thicker when zoomed in

### 6. Entity2D Line Type Accessor (Rust)

- Added `Entity2D::line_type()` method returning `Option<&str>` for the
  entity-level line type name (group 6)

## New Test Fixture

- `crates/mmforge-format-dxf/testdata/linetypes.dxf` — DXF file with:
  - 4 LTYPE entries: DASHED (6/-6), DASHDOT (6/-3/1/-3), DOTTED (0/-4), Continuous
  - 3 LAYER entries: solid_layer (Continuous), dashed_layer (DASHED), dotted_layer (DOTTED)
  - 5 LINE/CIRCLE entities testing layer inheritance and entity-level overrides

## Test Results

- **Rust**: 191 tests pass (36 + 63 + 39 + 6 + 12 + 5 + 30), 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 22 tests pass, 0 failures

### New/Updated Tests

- `tables_parser::parse_layer_with_line_type` — LAYER group 6 parsing
- `tables_parser::parse_single_ltype` — single LTYPE entry
- `tables_parser::parse_multiple_ltypes` — multiple LTYPE entries
- `tables_parser::ltype_with_dot_pattern` — zero-length dash (dot)
- `parser::line_types_from_fixture` — E2E LTYPE + layer line type parsing
- `parser::draw_list_line_type_resolution` — line type resolution and dash
  pattern propagation through the draw list pipeline
- `drawing::entity_line_type_accessor` — Entity2D::line_type() accessor

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-core/src/drawing.rs` | Layer.line_type, Entity2D::line_type() |
| `crates/mmforge-format-dxf/src/tables_parser.rs` | LAYER group 6, LTYPE parser fix |
| `crates/mmforge-format-dxf/src/parser.rs` | Default layer line_type, new tests |
| `crates/mmforge-render/src/draw2d.rs` | FlatDrawCommand.line_dash, line type resolution |
| `crates/mmforge-render/src/spatial2d.rs` | Updated make_cmd helper |
| `crates/mmforge-bridge/src/lib.rs` | New C ABI: dash, layer line_type/color_index |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | New C declarations |
| `macos/MMForge/RustBridge/RustBridge.swift` | Dash pattern fetch, layer info |
| `macos/MMForge/Views/DrawingView.swift` | Spatial culling, dash, line width |
| `macos/MMForge/Views/ViewportContainer.swift` | Pass document pointer |
| `macos/MMForge/Document/MMForgeDocument.swift` | Expose rustDoc |
| `crates/mmforge-format-dxf/testdata/linetypes.dxf` | New test fixture |
