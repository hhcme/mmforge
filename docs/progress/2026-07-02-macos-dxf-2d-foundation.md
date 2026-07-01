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

## Open Items

| Item | Status | Notes |
|------|--------|-------|
| Per-entity layer data via C ABI | Planned | Currently only aggregate counts; need per-entity DTO for full 2D rendering |
| Actual entity rendering in DrawingView | Planned | Currently draws bounding box placeholder; need to iterate entities via C ABI |
| LWPOLYLINE bulge-to-arc | Spec complete | Algorithm documented; not yet applied in draw list builder |
| MTEXT, SPLINE, ELLIPSE | Planned | P1 entities |
| INSERT/BLOCK expansion | Planned | P1 — block references with transform |
| Spatial index for large drawings | Planned | Phase 4 acceptance criterion |
| 2D measurement | Planned | Phase 5 |
