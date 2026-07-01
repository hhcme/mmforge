# macOS 2D Drawing Viewer Completion

Date: 2026-07-02
Agent: ZCode (mimo-v2.5-pro)

## Summary

Completed the DXF 2D drawing viewer with BLOCK/INSERT expansion, line type/weight infrastructure, spatial index viewport culling, layer panel UI, and comprehensive tests. The 2D viewer now handles real-world DXF files with block references and provides a proper layer management panel.

## Changes Made

### 1. BLOCK/INSERT Expansion

**`crates/mmforge-core/src/drawing.rs`:**
- Added `Entity2D::Insert` variant with `block_name`, `insert_point`, `scale`, `rotation`, `layer`
- Added `LineType` struct with `name`, `description`, `dashes`, `total_length`
- Added `line_types: Vec<LineType>` to `Drawing2DGeometry`
- Added `transform_entity()` function — applies translate/rotate/scale to any entity
- Added `expand_inserts()` method — resolves all INSERT entities by cloning block entities with transforms
- Updated `bounds()` to handle Insert variant

**`crates/mmforge-format-dxf/src/blocks_parser.rs` (NEW):**
- Parses BLOCKS section to extract block definitions
- Separates header fields (name, base point) from entity pairs
- Handles nested BLOCK/ENDBLK markers
- 4 unit tests: empty, single block, multiple entities, multiple blocks

**`crates/mmforge-format-dxf/src/entity_parser.rs`:**
- Added `parse_insert()` function for INSERT entities (group codes 2, 10/20, 41/42/43, 50, 8)
- Added INSERT to entity dispatch

**`crates/mmforge-format-dxf/src/parser.rs`:**
- Parses BLOCKS section
- Calls `drawing.expand_inserts()` after building entity list

### 2. Line Type/Weight Infrastructure

**`crates/mmforge-format-dxf/src/tables_parser.rs`:**
- Added `parse_line_types()` function for LINETYPE table entries
- Parses group codes 2 (name), 3 (description), 40 (total length), 49 (dash values)

**`crates/mmforge-render/src/draw2d.rs`:**
- Added `line_type: Option<String>` and `line_weight: Option<f64>` to `FlatDrawCommand`

**`crates/mmforge-bridge/src/lib.rs`:**
- Added `draw_linetype_cstrings: Vec<CString>` to `MmfDocument`
- Added `mmf_draw_cmd_line_type()` C ABI function
- Added `mmf_draw_cmd_line_weight()` C ABI function

### 3. Spatial Index Viewport Culling

**`crates/mmforge-render/src/spatial2d.rs` (NEW):**
- Grid-based spatial index (32×32 grid)
- `SpatialIndex2D::build()` partitions commands by AABB into grid cells
- `query(viewport)` returns command indices visible in viewport rect
- Conservative AABB for each command type (Line, Circle, Arc, Polyline, Text)
- 3 unit tests: empty index, full coverage, partial culling

**`crates/mmforge-bridge/src/lib.rs`:**
- Added `spatial_index: Option<SpatialIndex2D>` to `MmfDocument`
- Builds spatial index in `build_document()` (32×32 grid)
- Added `mmf_draw_spatial_query()` C ABI function — returns indices of visible commands

### 4. Layer Panel UI

**`macos/MMForge/Views/InspectorPanel.swift`:**
- Added 4th tab "Layers" to the segmented picker
- `layersView` shows layer list with ACI color swatch and visibility toggle
- `aciSwiftUIColor()` helper for layer color display

**`macos/MMForge/Document/MMForgeDocument.swift`:**
- Added `@Published layerVisibility: [String: Bool]` — maps layer name → visible
- Added `@Published layerColors: [String: Int]` — maps layer name → ACI index
- Added `initLayerState()` — populates from `Drawing2DInfo` after parse
- Added `toggleLayerVisibility()` — toggles layer visibility by name

**`macos/MMForge/Views/ViewportContainer.swift`:**
- Computes `layerIndexOverrides` from view model's name-based `layerVisibility`
- Passes overrides to `Drawing2DViewRepresentable` for real-time layer toggle

**`macos/MMForge/Views/DrawingView.swift`:**
- Updated `Drawing2DViewRepresentable` to accept overrides directly (not binding)

### 5. HIG Compliance

- Layer panel uses standard `List` style with proper spacing
- Accessibility labels on layer visibility toggles
- Color swatches use ACI standard colors
- Dark mode compatible (grid/axis colors work in both appearances)

## Verification

```
cargo fmt --all                    ✅ Clean
cargo clippy --workspace -- -D warnings  ✅ Clean
cargo test --workspace             ✅ 182 tests pass (36+60+33+6+12+5+30+0)
xcodebuild build                   ✅ BUILD SUCCEEDED
xcodebuild test                    ✅ 22 tests pass, 0 failures
```

## Key Points for Codex Review

1. **BLOCK/INSERT transform order**: `transform_entity()` applies scale → rotate → translate, matching DXF INSERT semantics. The layer override only applies to entities with layer "0" (default).

2. **Spatial index grid size**: Fixed at 32×32. For very large drawings, this may need tuning. The `query()` returns deduplicated indices via `HashSet`.

3. **Line type/weight**: Infrastructure is in place but not yet populated from DXF entity data (group code 6 for linetype, 370/39 for weight). The `FlatDrawCommand` fields are `Option<>` and default to `None`.

4. **Layer visibility architecture**: Name-based in view model → index-based conversion in `ViewportContainer` → passed to `Drawing2DView`. This avoids binding complexity but means the view redraws on any layer state change.

5. **BLOCKS parser header/entity separation**: Fixed a bug where header pairs (code 2, 10, 20) were being included in entity parsing. Now uses a `header_done` flag to separate them.

## Files Changed

| File | Lines | Change |
|------|-------|--------|
| `crates/mmforge-core/src/drawing.rs` | +95 | Insert variant, LineType, transform_entity, expand_inserts |
| `crates/mmforge-format-dxf/src/blocks_parser.rs` | +160 | **NEW** — BLOCKS section parser |
| `crates/mmforge-format-dxf/src/entity_parser.rs` | +20 | INSERT entity parsing |
| `crates/mmforge-format-dxf/src/tables_parser.rs` | +80 | LINETYPE table parsing |
| `crates/mmforge-format-dxf/src/parser.rs` | +15 | Wire blocks + expand inserts |
| `crates/mmforge-format-dxf/src/lib.rs` | +1 | Module declaration |
| `crates/mmforge-render/src/draw2d.rs` | +15 | FlatDrawCommand line_type/weight fields |
| `crates/mmforge-render/src/spatial2d.rs` | +195 | **NEW** — grid spatial index |
| `crates/mmforge-render/src/lib.rs` | +1 | Module declaration |
| `crates/mmforge-bridge/src/lib.rs` | +80 | Spatial index, linetype/weight C ABI |
| `macos/MMForge/Views/InspectorPanel.swift` | +55 | Layers tab |
| `macos/MMForge/Views/DrawingView.swift` | +5 | Override acceptance |
| `macos/MMForge/Views/ViewportContainer.swift` | +15 | Layer index computation |
| `macos/MMForge/Document/MMForgeDocument.swift` | +25 | Layer state management |
