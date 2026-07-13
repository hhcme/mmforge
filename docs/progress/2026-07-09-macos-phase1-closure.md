# macOS Phase 1 Closure — 2026-07-13

**Status**: NON-GUI VERIFIED — 362+ Rust / 218 Swift (52 acceptance + 166 existing) / C++ shim / headless Metal offscreen render all pass

---

## Deliverables

### Offscreen Metal Render (Production API)
- `renderOffscreen(size:)` → `(Data, Int, Int)` — raw RGBA8, no drawable required
- `renderOffscreenImage(size:)` → `NSImage?` — PNG/TIFF-ready
- 3D `exportImage()` uses offscreen path (no `currentDrawable` dependency)

### Bridge Acceptance Tests (52 tests)
| Category | Count | Key Assertions |
|----------|:-----:|----------------|
| DTO structure | 9 | assembly.stp (3), deep_assembly (1), box.igs, translated_box.igs (exact epsilon), box.stl, box.gltf, test.dxf, LSM golden |
| Tree consistency | 2 | parentIndex pre-order, mesh→geometryId |
| VM visibility (real DTO) | 4 | selectNode, isolate, hide/show all, visibleNodeIndices |
| Headless MetalRenderer | 15 | geometryId→nodeIndex→GPUMesh, selectNode sync, toggle/hide/isolate chain, pendingDTO, async+bound renderer, camera init |
| Camera math | 6 | orbit (concrete delta), fit/reset, pan (target shift), zoom (distance decrease), projection toggle, named views (7 views) |
| Picking | 1 | 10×10 grid scan → deterministic hit, toggleNodeVisibility → verify miss |
| Offscreen snapshot | 4 | solid non-empty pixels, 2 sizes, wireframe≠solid, hide→show restore |
| PNG export | 6 | solid non-empty, 4 modes, 2 sizes aspect, selected highlight, hide-all vs all-visible, LSM fixture |
| Detection parity | 2 | sync/async LSM and STEP produce same node count |
| Async + error | 2 | progress reporting, nonexistent file |
| Tree operations | 3 | expand/collapse, search, child count |

### Fixtures
| Fixture | Format | Entities | Nodes | Geoms | Triangles |
|---------|--------|:-------:|:-----:|:-----:|:---------:|
| `assembly.stp` | STEP AP214 | 494 | 3 | 2 | 244 |
| `deep_assembly.stp` | STEP AP214 | 2138 | 7 | 6 | 72 |
| `box.igs` | IGES | 50 | 2 | 1 | 12 |
| `translated_box.igs` | IGES | — | 2 | 1 | 12 |
| `box.stl` | STL | — | 2 | 1 | 12 |
| `box.gltf` | glTF | — | 1 | 1 | 1 |
| `test.dxf` | DXF | — | — | — | 2D |
| `model_golden_v1.lsm` | LSM | — | 2 | 1 | 1 |

### Bridge Detection
Sync (`mmf_parse_file`) and async (`parse_with_detection`) share unified cascade:
DXF → STL → glTF → IGES → LSM → STEP

CLI `mmforge info` reports both container and source format for LSM:
```
container: LSM
format  : STL
```

### Verification
| Check | Result |
|-------|--------|
| `cmake && make` (shim) | ✅ |
| `cargo check --workspace --features occt` | ✅ |
| `cargo test --workspace --features occt` | ✅ 362+ |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ |
| `xcodebuild test` | ✅ **218** (52 acc + 166) |
| `git diff --check 37b7a43..HEAD` | ✅ |

### GUI Items (manual pending)
| # | Item |
|---|------|
| G1 | Structure sidebar visual rendering |
| G2 | Viewport picking visual feedback |
| G3 | Camera orbit/pan/zoom gestures |
| G4 | 3D Export PNG via save panel |
| G5 | Inspector per-part bounds |
| G6 | Color/material per component |
| G7 | Window-scoped GUI acceptance (8 formats) |
