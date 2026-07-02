# 2D Drawing Viewer — Spatial Culling / LTYPE / Layer Line Type Fixes (Round 3b)

**Date**: 2026-07-02
**Scope**: Fix spatial query, LTYPE, layer line type, viewport culling issues from round 3.

## Summary

Fixed spatial query viewport inverse transform (now includes panOffset with
single transform chain), ABI return semantics (distinguishes -1/0/total),
buffer overflow with dynamic realloc, zero-length dash→visible dot in Core
Graphics, and fully case-insensitive ByLayer/ByBlock handling.

## Issues Fixed

### 1. Spatial Viewport Inverse Transform

**Problem**: The viewport inverse transform was computed with separate
per-component formulas that did not include `panOffset`, causing the spatial
query to return incorrect results when the view was panned.

**Fix**: Replaced with a single `screenToWorld` closure that applies the exact
inverse of the full draw transform chain (translate→scale→pan→worldCenter→
Y-flip→Y-translate), including `panOffset`. Both screen corners are mapped
through this function and min/max is taken (Y-flip swaps min/max).

### 2. ABI Return Semantics — Distinguish Error vs Empty

**Problem**: `mmf_draw_spatial_query` returned -1 for both "no spatial index"
and "error", and returned the number written (not total). When the result was
0 (legitimate empty viewport), the Swift side fell back to full draw.

**Fix**:
- Returns `-1` when spatial index is unavailable or error (caller falls back).
- Returns `0` when no commands are visible (legitimate empty — caller draws nothing).
- Returns `>0` the **total** number of matching indices. If `total > max_count`,
  only `max_count` were written; caller can detect overflow and re-query.

### 3. Buffer Overflow — Dynamic Realloc

**Problem**: When spatial query returned more indices than the 10,000 buffer,
geometry was silently dropped.

**Fix**: `RustBridge.spatialQuery()` now returns `[Int]?`:
- `nil` = spatial index unavailable (caller falls back to full draw).
- `[]` = legitimate empty viewport (caller draws nothing).
- `[...]` = visible command indices.

On overflow (`total > capacity`), the buffer is reallocated with the exact total
and the query is re-issued. No geometry is silently dropped.

### 4. Legitimate Empty Result — No Fallback

**Problem**: When the viewport contained no visible commands (e.g., user panned
away from the drawing), the view fell back to drawing all commands.

**Fix**: `spatiallyCulledCommands()` returns `Optional<[DrawCommandDTO]>`:
- `nil` = index unavailable → falls back to `drawCommands` in `draw(_:)`.
- `[]` = nothing visible → draws nothing.
- `[...]` = culled commands → draws only those.

### 5. Zero-Length Dash → Visible Dot

**Problem**: DXF zero-length dashes (dots) produced `[0.0]` in the CGLineDash,
which Core Graphics interprets as "no dash" (solid line), making dots invisible.

**Fix**: `lineDashPattern()` converts zero-length values (`< 1e-10`) to `0.5`
drawing units, producing a visible dot. New Rust test `ltype_dot_pattern_preserved`
verifies the zero value survives through the draw list pipeline.

### 6. ByLayer/ByBlock Fully Case-Insensitive

**Problem**: `resolve_line_type()` only matched `"ByLayer"`, `"BYLAYER"`,
`"ByBlock"`, `"BYBLOCK"` — not arbitrary casing like `"bylayer"`.

**Fix**: Uses `eq_ignore_ascii_case()` for all ByLayer/ByBlock comparisons.
New tests: `resolve_bylayer_case_insensitive`, `resolve_byblock_case_insensitive`.

## Test Results

- **Rust**: 200 tests pass (36 + 63 + 39 + 6 + 12 + 5 + 39), 0 failures
- **Clippy**: clean (0 warnings)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 22 tests pass, 0 failures

### New Tests (9)

- `resolve_bylayer_case_insensitive` — "bylayer"/"BYLAYER"/"ByLayer" all resolve
- `resolve_byblock_case_insensitive` — "byblock"/"BYBLOCK" resolve
- `resolve_bylayer_fallback_to_continuous` — ByLayer with no layer → None
- `resolve_entity_overrides_layer` — explicit entity type overrides layer
- `resolve_no_entity_uses_layer` — nil entity inherits from layer
- `resolve_no_entity_no_layer_is_continuous` — nil/nil → None
- `ltype_dot_pattern_preserved` — zero-length dash preserved in draw list
- `layer_line_type_inherited_by_entity` — entity inherits layer's DASHED
- `entity_level_overrides_layer_line_type` — entity DASHDOT overrides layer DASHED

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-render/src/draw2d.rs` | Case-insensitive ByLayer/ByBlock, 9 new tests |
| `crates/mmforge-bridge/src/lib.rs` | Spatial query returns total count, -1/0/total semantics |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | Updated doc comment for spatial query |
| `macos/MMForge/RustBridge/RustBridge.swift` | `spatialQuery` returns `[Int]?`, dynamic realloc on overflow |
| `macos/MMForge/Views/DrawingView.swift` | Fixed viewport inverse transform, nil/empty handling, dot conversion |
