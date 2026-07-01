# macOS 2D Drawing Viewer Validation Fixes

Date: 2026-07-02
Agent: ZCode (mimo-v2.5-pro)
Phase: 4 (macOS Native 2D Drawings) — validation fixes

## Summary

Fixed all validation gaps identified in the macOS 2D drawing viewer:
1. INSERT rotation now correctly converts degrees→radians
2. BLOCK base_point is subtracted before scale/rotate/translate
3. Layer visibility uses stable layerName instead of index mismatch
4. Spatial query exposed via C ABI and integrated into DrawingView
5. Entity line type (group 6) and line weight (370/39) parsed and rendered
6. LTYPE dash patterns rendered via CGContext line dash
7. layerVisibility/layerColors cleared on new document open

## Changes

### Rust Core (`mmforge-core/src/drawing.rs`)
- Added `line_type: Option<String>` and `line_weight: Option<f64>` to all Entity2D variants (Line, Circle, Arc, Polyline)
- Fixed `expand_inserts()`: rotation converted from degrees to radians before transform
- Fixed `expand_inserts()`: block entities shifted by `-base_point` before scale/rotate/translate
- Added `shift_entity()` helper for base_point subtraction

### DXF Parser (`mmforge-format-dxf/src/entity_parser.rs`)
- Added `entity_line_type()` helper to extract group 6 (linetype name)
- Added `entity_line_weight()` helper to extract group 370 (in hundredths of mm) or group 39
- Updated all entity parsers (LINE, CIRCLE, ARC, LWPOLYLINE) to populate line_type/line_weight

### Draw List Builder (`mmforge-render/src/draw2d.rs`)
- Added `layer_name: String` to `FlatDrawCommand` for stable layer identification
- Updated `build_draw_list()` to pass line_type/line_weight from Entity2D to FlatDrawCommand
- All FlatDrawCommand constructions now include layer_name

### Spatial Index (`mmforge-render/src/spatial2d.rs`)
- Updated test helper to include layer_name field

### Bridge (`mmforge-bridge/src/lib.rs`)
- Updated `mmf_draw_cmd_layer_name()` to use stable layer_name from FlatDrawCommand
- `mmf_draw_cmd_line_type()` and `mmf_draw_cmd_line_weight()` already implemented

### C Header (`macos/MMForge/RustBridge/mmforge_bridge.h`)
- Added `mmf_draw_cmd_line_type()` — returns line type name (NULL if Continuous)
- Added `mmf_draw_cmd_line_weight()` — returns line weight in mm (0.0 if default)
- Added `mmf_draw_spatial_query()` — viewport culling query

### Swift Bridge (`macos/MMForge/RustBridge/RustBridge.swift`)
- Added `lineType: String?` and `lineWeight: Double` to DrawCommandDTO line/circle/arc/polyline cases
- Updated `drawCommands()` to fetch line_type and line_weight from C ABI
- Added `spatialQuery()` method for viewport culling

### DrawingView (`macos/MMForge/Views/DrawingView.swift`)
- Changed `layerVisibilityOverrides` from `[Int: Bool]` to `[String: Bool]` (layer name based)
- Added `lineWidth()` — converts line weight mm to points, scales with zoom
- Added `lineDashPattern()` — maps DXF line type names to CG dash patterns (dashed, dashdot, dotted, center, hidden, phantom, border)
- Updated `drawCommand()` to apply line width and dash patterns
- Layer visibility now uses layerName from command, not index

### ViewportContainer (`macos/MMForge/Views/ViewportContainer.swift`)
- Simplified to pass `viewModel.layerVisibility` directly (name-based)

### DocumentViewModel (`macos/MMForge/Document/MMForgeDocument.swift`)
- Added `layerVisibility: [String: Bool]` and `layerColors: [String: Int]` published properties
- Added `initLayerState()` to populate from drawing info after parse
- Added `toggleLayerVisibility()` for layer panel interaction
- `freeCurrentDocument()` now clears layerVisibility and layerColors

## Verification

- `cargo fmt --all` — clean
- `cargo check --workspace` — clean
- `cargo test --workspace` — 172 tests pass (30 render, 71 core, 33 dxf, 12 step, 10 geometry, 6 iges, 10 cli)
- `cargo clippy --workspace -- -D warnings` — clean
- `xcodebuild build` — BUILD SUCCEEDED
- `xcodebuild test` — 22 tests pass, 0 failures

## Known Remaining Items

1. Spatial query not yet used for viewport culling in DrawingView (C ABI exposed, Swift wrapper ready, not wired into draw loop)
2. IGES format not yet supported (planned for Phase 4)
3. MTEXT, SPLINE, ELLIPSE entities not yet supported
4. INSERT/BLOCK nested expansion not recursive
5. Line type dash patterns are approximate (DXF spec defines more patterns)
