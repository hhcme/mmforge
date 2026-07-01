# DXF 2D Foundation — macOS Native 2D Drawing

Date: 2026-07-02
Agent: ZCode (mimo-v2.5-pro)
Target: DXF 2D parsing pipeline + macOS Core Graphics 2D viewer foundation.

---

## Summary

MMForge now supports DXF 2D drawing files end-to-end:

```
DXF file → tokenizer → section parser → entity parser → Drawing2DGeometry
  → LsmModel (Drawing2D variant) → RenderPacket (empty) → macOS 2D viewer
```

The implementation adds platform-agnostic DXF parsing in Rust, 2D drawing types in mmforge-core, a DrawList builder in mmforge-render, and a Core Graphics 2D viewer in the macOS app with zoom/pan/fit and layer visibility support.

---

## Architecture

```
mmforge-core/src/drawing.rs     ← Drawing2DGeometry, Entity2D, Layer, Block, BBox2D
mmforge-render/src/draw2d.rs    ← DrawingDrawList, DrawCommand2D, build_draw_list()
mmforge-format-dxf/             ← DXF tokenizer, section/entity/tables parser
mmforge-bridge/src/lib.rs       ← mmf_parse_file dispatches DXF, 2D C ABI functions
macos/DrawingView.swift         ← Core Graphics 2D viewer with pan/zoom/fit
macos/ViewportContainer.swift   ← Switches 3D Metal / 2D CG based on document type
```

---

## New Crate: `mmforge-format-dxf`

| File | Purpose |
|------|---------|
| `src/tokenizer.rs` | `DxfTokenizer` — reads group code + value pairs from DXF text |
| `src/section_parser.rs` | Segments into HEADER/TABLES/BLOCKS/ENTITIES/OBJECTS sections |
| `src/entity_parser.rs` | Parses LINE, CIRCLE, ARC, LWPOLYLINE, TEXT entities |
| `src/tables_parser.rs` | Parses LAYER table entries (name, color index, frozen flag) |
| `src/detect.rs` | DXF format detection (`.dxf` extension + SECTION marker) |
| `src/parser.rs` | `DxfParser` implementing `FormatParser`, `parse_dxf()` |

### Supported Entities

| Entity | Group Codes | Status |
|--------|-------------|--------|
| LINE | 10/20 (start), 11/21 (end), 8 (layer) | ✅ |
| CIRCLE | 10/20 (center), 40 (radius), 8 (layer) | ✅ |
| ARC | 10/20 (center), 40 (radius), 50/51 (angles), 8 (layer) | ✅ |
| LWPOLYLINE | 90 (count), 70 (closed), 10/20/42 (point+bulge), 8 (layer) | ✅ |
| TEXT | 10/20 (position), 1 (content), 40 (height), 50 (rotation), 8 (layer) | ✅ |
| MTEXT | — | Planned |
| SPLINE | — | Planned |
| INSERT/BLOCK | — | Planned |

---

## Core Types

### `mmforge-core/src/drawing.rs`

```rust
pub struct Drawing2DGeometry {
    pub entities: Vec<Entity2D>,
    pub layers: Vec<Layer>,
    pub blocks: Vec<Block>,
}

pub enum Entity2D {
    Line { start: [f64; 2], end: [f64; 2], layer: String },
    Circle { center: [f64; 2], radius: f64, layer: String },
    Arc { center: [f64; 2], radius: f64, start_angle: f64, end_angle: f64, layer: String },
    Polyline { vertices: Vec<PolylineVertex>, closed: bool, layer: String },
    Text { position: [f64; 2], content: String, height: f64, rotation: f64, layer: String },
}

pub struct Layer { pub name: String, pub color_index: i16, pub visible: bool }
pub struct BBox2D { pub min: [f64; 2], pub max: [f64; 2] }
```

`Geometry::Drawing2D` extended with `drawing: Box<Drawing2DGeometry>`.

### `mmforge-render/src/draw2d.rs`

```rust
pub struct DrawingDrawList { pub layers: Vec<LayerDrawList>, pub bounds: BBox2D }
pub struct LayerDrawList { pub layer_name: String, pub visible: bool, pub color_index: i16, pub commands: Vec<DrawCommand2D> }
pub enum DrawCommand2D { Line, Arc, Circle, Polyline, Text }
pub fn build_draw_list(drawing: &Drawing2DGeometry) -> DrawingDrawList
```

---

## Bridge Integration

- `mmf_parse_file` dispatches `.dxf` → `mmforge_format_dxf::parse_dxf` → empty TessellationRegistry
- New C ABI functions:
  - `mmf_is_2d_drawing(doc)` → 1 if document has Drawing2D geometry
  - `mmf_drawing_entity_count(doc)` → number of 2D entities
  - `mmf_drawing_layer_count(doc)` → number of layers
  - `mmf_drawing_bounds(doc, ...)` → 2D bounding box
  - `mmf_drawing_layer_name(doc, index)` → layer name
  - `mmf_drawing_layer_visible(doc, index)` → layer visibility

---

## macOS 2D Viewer

**`DrawingView.swift`**: NSView subclass using Core Graphics.
- Draws grid with auto-scaling grid size (1/2/5 mantissa)
- Axis lines at origin
- Pan via mouse drag, zoom via scroll wheel / magnify gesture
- `fitToView()` resets viewport
- Layer visibility via `layerVisibility` dictionary

**`Drawing2DViewRepresentable`**: NSViewRepresentable wrapper for SwiftUI.

**`ViewportContainer.swift`**: Switches between 3D Metal view and 2D Drawing view based on `viewModel.is2DDrawing`.

**`DocumentViewModel`**: Added `is2DDrawing` and `drawing2DInfo` computed properties.

---

## DXF Fixtures

| File | Purpose |
|------|---------|
| `testdata/test.dxf` | Valid DXF with 2 LINE, 1 CIRCLE, 1 ARC, 1 LWPOLYLINE (closed rectangle), 1 TEXT, 3 LAYERs (walls/text/hidden) |
| `testdata/error.dxf` | Malformed DXF with non-numeric group value for error handling |

Fixture source: hand-written, trivial geometry. Public domain.

---

## Tests

| Module | # | Key tests |
|--------|---|-----------|
| drawing.rs | 5 | empty bounds, line/circle/polyline bounds, ACI colors |
| draw2d.rs | 4 | empty, group by layer, hidden layer, unknown layer default |
| tokenizer.rs | 5 | empty, single pair, multiple, whitespace, collect entity pairs |
| section_parser.rs | 3 | empty, single section, two sections |
| entity_parser.rs | 8 | LINE, CIRCLE, ARC, LWPOLYLINE (straight+closed), TEXT, unknown entity |
| tables_parser.rs | 4 | empty, single layer, frozen layer, multiple layers, ignore non-layer tables |
| detect.rs | 4 | section marker, extension only, reject non-dxf, reject no extension |
| bridge dxf_detector | 3 | section marker, extension only, reject non-dxf |
| core model | 60 | existing tests still pass with Drawing2D extension |
| render | 14 | existing + 4 new draw2d tests |
| **Total** | **157** | All pass |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --all` | ✅ Clean |
| `cargo clippy --workspace` | ✅ Clean |
| `cargo check --workspace` | ✅ Clean |
| `cargo test --workspace` | ✅ 157 tests pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test` | ✅ 22 tests pass |

---

## Files Modified / Created

| File | Action |
|------|--------|
| `Cargo.toml` (workspace) | Added mmforge-format-dxf member + glam/tempfile deps |
| `crates/mmforge-core/src/drawing.rs` | **New** — Drawing2DGeometry, Entity2D, Layer, Block, BBox2D, aci_to_rgba |
| `crates/mmforge-core/src/lib.rs` | Added pub mod drawing |
| `crates/mmforge-core/src/model.rs` | Extended Geometry::Drawing2D with drawing field |
| `crates/mmforge-render/src/draw2d.rs` | **New** — DrawingDrawList, DrawCommand2D, build_draw_list |
| `crates/mmforge-render/src/lib.rs` | Added pub mod draw2d |
| `crates/mmforge-format-dxf/Cargo.toml` | **New** |
| `crates/mmforge-format-dxf/src/lib.rs` | **New** |
| `crates/mmforge-format-dxf/src/tokenizer.rs` | **New** — DxfTokenizer |
| `crates/mmforge-format-dxf/src/section_parser.rs` | **New** — section segmentation |
| `crates/mmforge-format-dxf/src/entity_parser.rs` | **New** — LINE/CIRCLE/ARC/LWPOLYLINE/TEXT |
| `crates/mmforge-format-dxf/src/tables_parser.rs` | **New** — LAYER table |
| `crates/mmforge-format-dxf/src/detect.rs` | **New** — DXF detection |
| `crates/mmforge-format-dxf/src/parser.rs` | **New** — DxfParser + FormatParser impl |
| `crates/mmforge-format-dxf/testdata/test.dxf` | **New** — test fixture |
| `crates/mmforge-format-dxf/testdata/error.dxf` | **New** — error fixture |
| `crates/mmforge-bridge/src/dxf_detector.rs` | **New** — .dxf detection |
| `crates/mmforge-bridge/src/lib.rs` | Wired DXF into mmf_parse_file, added 6 2D C ABI functions |
| `crates/mmforge-bridge/Cargo.toml` | Added mmforge-format-dxf dep |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | Added 6 DXF C ABI declarations |
| `macos/MMForge/RustBridge/RustBridge.swift` | Added Drawing2DInfo, Drawing2DLayerInfo, is2DDrawing, drawing2DInfo |
| `macos/MMForge/Views/DrawingView.swift` | **New** — Core Graphics 2D view with pan/zoom/fit/grid |
| `macos/MMForge/Views/ViewportContainer.swift` | Switches 3D/2D based on is2DDrawing |
| `macos/MMForge/Document/MMForgeDocument.swift` | Added UTType.dxf, .dxf in readableContentTypes, is2DDrawing/drawing2DInfo |
| `macos/MMForge/Resources/Info.plist` | Added com.mmforge.dxf UTType |
| `macos/MMForge.xcodeproj/project.pbxproj` | Added DrawingView.swift to build |

---

---

## Round 2 — Real rendering via C ABI

### Problem
Round 1's DrawingView only drew a bounding box placeholder. The C ABI exposed entity counts but not the actual draw command data (coordinates, types). LWPOLYLINE bulge-to-arc was documented but not implemented.

### Fixes

**1. C ABI draw command accessors (16 new functions)**
- `mmf_draw_cmd_count/type/layer_index/layer_name/color_index/layer_visible` — per-command metadata
- `mmf_draw_cmd_line(circle/arc/polyline/text` — per-type coordinate accessors
- `mmf_draw_cmd_polyline_count/point/closed` — polyline vertex access
- All return proper error codes (0/-1 on invalid, 1 on success)

**2. MmfDocument stores DrawingDrawList**
- `build_document()` now calls `build_draw_list()` for Drawing2D geometries
- Pre-computed `draw_text_cstrings` and `draw_layer_cstrings` for stable C string pointers
- `draw_list.flat_commands` provides indexed access for C ABI

**3. LWPOLYLINE bulge-to-arc implemented**
- `bulge_to_arc(p1, p2, bulge)` → `ArcParams { center, radius, start_angle, end_angle }`
- `expand_polyline(vertices, closed)` → `Vec<DrawCommand2D>` (lines for bulge≈0, arcs for bulge≠0)
- Closed polylines wrap around (segment from last to first vertex)
- Degenerate cases handled (zero distance, zero bulge)

**4. DrawingView renders actual entities via Core Graphics**
- LINE: `CGContext.move/addLine/stroke`
- CIRCLE: `CGContext.strokeEllipse`
- ARC: `CGContext.addArc` with start/end angles
- POLYLINE: `move/addLine` per point, `closePath` if closed
- TEXT: `NSAttributedString.draw` with rotation transform
- Each entity checks layer visibility before rendering
- ACI color index → CGColor mapping (1=red, 2=yellow, 3=green, 4=cyan, 5=blue, 6=magenta, 7=white)

**5. Layer visibility effective in rendering**
- `layerVisibilityOverrides: [Int: Bool]` dictionary in Drawing2DView
- Each draw command checks `isLayerVisible(layerIndex, default: visible)`
- UI can override layer visibility via the dictionary

**6. Swift DrawCommandDTO enum**
- `DrawCommandDTO` with cases: `.line`, `.circle`, `.arc`, `.polyline`, `.text`
- Each case carries layerIndex, layerName, colorIndex, visible
- `RustBridge.drawCommands(_:)` fetches all commands from C ABI

**7. E2E tests added**
- `parse_test_fixture` — verifies entity counts, layer names, bounds, model structure
- `parse_error_fixture_gracefully` — malformed DXF doesn't panic
- `draw_list_from_fixture` — verifies draw list has commands, layer grouping, text command
- `polyline_bulge_expanded_to_arc` — verifies bulge=0 produces LINE commands

### Verification

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 166 tests pass |
| `cargo clippy --workspace` | ✅ Clean |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test` | ✅ 22 tests pass |

---

---

## Round 3 — Arc angle unification + negative bulge fix

### Problem
1. DXF ARC entity stores angles in **degrees** but `DrawCommand2D::Arc` had no documented unit convention. The `bulge_to_arc` function returned radians, but DXF ARC passed degrees through unchanged. Swift `CGContext.addArc` expects radians — DXF arcs were rendered at wrong angles.
2. `bulge_to_arc` used signed `sagitta` in the radius formula, causing incorrect center position for negative bulge (CW arcs). For `|bulge| > 1` (arcs > 180°), the center was placed on the wrong side.
3. No `ccw` direction field on `DrawCommand2D::Arc` — Swift couldn't distinguish CW from CCW arcs.

### Fixes

**1. Unified angle convention: radians everywhere in DrawCommand2D**
- `DrawCommand2D::Arc` doc comment: "All angles in **radians**."
- `build_draw_list()` converts DXF ARC degrees → radians via `deg_to_rad()` (line: `start_angle: deg_to_rad(*start_angle)`).
- `bulge_to_arc()` returns radians (from `atan2`).
- Swift `DrawingView` passes radians directly to `CGContext.addArc`.

**2. Added `ccw: bool` to `DrawCommand2D::Arc`**
- `true` = counter-clockwise (positive bulge, DXF default)
- `false` = clockwise (negative bulge)
- C ABI: `mmf_draw_cmd_arc` now has `out_ccw: *mut i32` parameter
- Swift `DrawCommandDTO.arc` carries `ccw: Bool`
- DrawingView uses `clockwise: !ccw` for `CGContext.addArc`

**3. Fixed negative bulge center calculation**
- Before: `offset = radius - sagitta` (signed) → wrong for negative sagitta
- After: `offset = radius - abs_sagitta` (always positive) → correct center placement
- `bulge.signum()` still controls which side of the chord the center is on
- Semicircle (|bulge|=1): offset=0, center at midpoint ✓
- Arc > 180° (|bulge|>1): offset < 0, center on opposite side ✓

**4. New tests (10 added, 175 total)**

| Test | What |
|------|------|
| `dxf_arc_converted_to_radians` | 0°→0.0, 90°→π/2, ccw=true |
| `dxf_arc_180_degrees` | 45°→π/4, 225°→5π/4 |
| `bulge_positive_semicircle` | bulge=1.0, center at midpoint, ccw=true |
| `bulge_negative_semicircle` | bulge=-1.0, center at midpoint, ccw=false |
| `bulge_positive_small_arc` | bulge=0.1, center above chord, ccw=true |
| `bulge_negative_small_arc` | bulge=-0.1, center below chord, ccw=false |
| `bulge_positive_large_arc` | bulge=2.0, center on opposite side, ccw=true |
| `arc_crossing_zero_degrees` | 350°→10°, radians correct |
| `bulge_opposite_directions_have_opposite_centers` | ±0.5 → opposite Y, same radius |
| `arc_e2e_dxf_degrees_to_draw_list_radians` | Full E2E: DXF ARC(0°,180°) → rad(0,π) in draw list |

---

## Open Items (updated)

| Item | Status | Notes |
|------|--------|-------|
| MTEXT, SPLINE, ELLIPSE | Planned | P1 entities |
| INSERT/BLOCK expansion | Planned | P1 — block references with transform |
| Spatial index for large drawings | Planned | Phase 4 acceptance criterion |
| 2D measurement | Planned | Phase 5 |
