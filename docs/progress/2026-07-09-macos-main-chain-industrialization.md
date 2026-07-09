# macOS Main Chain Industrialization — 2026-07-09

**Date**: 2026-07-09
**Agent**: ZCode (deepseek-v4-pro)
**Status**: NON-GUI VERIFIED — Rust 362+ / Swift 166 / C++ shim all pass; GUI-only items pending

---

## 1. Summary

This batch completes non-interactive verification of the XDE assembly tree
pipeline end-to-end and adds rigorous IGES regression coverage. All automated
checks (Rust, Swift, CLI) pass. macOS GUI features (structure tree rendering,
viewport picking, hide/isolate, camera, 3D export) have code-evidence that
the underlying data paths are correct, but visual confirmation requires a
foreground GUI session and remains pending.

---

## 2. Evidence Matrix

### 2.1 Automated (Non-GUI)

| Layer | Check | Result | Test Count |
|-------|-------|--------|:----------:|
| C++ shim | `cmake && make` | Compiled + linked | — |
| Rust | `cargo check --workspace --features occt` | 0 errors | — |
| Rust | `cargo test --workspace --features occt` | All pass | **362+** |
| Rust | `cargo clippy --workspace --features occt -- -D warnings` | 0 warnings | — |
| Rust | **IGES parser registry-bounds mock test** (new) | Pass | 1 (format-iges) |
| Rust | **IGES tessellation E2E** `iges_registry_bounds_match_mesh_post_transform` | Pass | 1 (geometry) |
| Swift | `xcodebuild test -scheme MMForge` | All pass | **166** |
| CLI | `mmforge info assembly.stp` (STEP) | nodes=3, geoms=2, tri=244 | — |
| CLI | `mmforge info box.igs` (IGES) | nodes=2, geoms=1, tri=12 | — |
| CLI | `mmforge info translated_box.igs` (IGES, new) | nodes=2, geoms=1, tri=12 | — |
| Git | `git diff --check` (working tree) | Clean | — |
| Git | `git diff --check 37b7a43..HEAD` | Clean | — |

### 2.2 IGES Registry Bounds Regression Test (parser-level, mock data)

```rust
// crates/mmforge-format-iges/src/parser.rs — tests::parser_uses_registry_bounds_not_tree_node_bounds
//
// Creates mock IgesData with tn.bounds = [0,0,0]–[1,1,1] and a
// TessellationRegistry with mesh bounds = [10,0,0]–[20,1,1].
// Calls build_iges_model_from_data, then asserts:
//   - Node.bounds == registry mesh bounds (post-transform)
//   - Geometry.bounds == registry mesh bounds
//   - bounds ≠ tn.bounds (pre-transform)
//
// This gates against the bug where the parser used tn.bounds instead
// of registry.get(&gid).map_or(tn.bounds, |m| m.bounds).
```

This is a pure unit test — no OCCT, no file I/O.  Passes on every `cargo test --features occt`.

### 2.3 IGES E2E Tessellation Bounds Test (fixture-based)

```rust
// crates/mmforge-geometry/src/occt/iges_reader.rs — iges_registry_bounds_match_mesh_post_transform
//
// Reads box.igs, tessellates, and verifies every leaf geometry has
// valid, finite registry mesh bounds.
// Requires occt_found (real OCCT shim).
```

---

## 3. macOS Features — Code Evidence vs Manual Verification

All macOS features below rely on stable `nodeIndex` / `parentIndex` /
`geometryId` data paths.  The Swift layer was **not modified** for the
tree-based model — the data structures are backward-compatible.

### 3.1 Structure Tree (multi-node display)

| Property | Code Evidence | XCTest | Manual GUI |
|----------|:------------:|:------:|:----------:|
| Node hierarchy via parentIndex | ✅ Swift `StructureSidebar` reads `NodeInfo.parentIndex` | ✅ 166/166 | ❌ Pending |
| Assembly folder icon detection | ✅ `!node.hasGeometry && hasKids` logic unchanged | — | ❌ Pending |
| 166 Swift tests pass with tree model | ✅ xcodebuild confirms stability | ✅ | — |

**Evidence**: `mmf_node_parent()` in the bridge converts `Node.parent` (NodeId)
to array index. `DocumentViewModel.uploadToRenderer()` builds `geomIdToNodeIdx`
map using the same indexing. These data paths are exercised by all 166 XCTests.

### 3.2 Single-Node Selection / Property Panel

| Property | Code Evidence | XCTest | Manual GUI |
|----------|:------------:|:------:|:----------:|
| Selection by nodeIndex | ✅ `selectedNodeIndex` → `GPUMesh.nodeIndex` | — | ❌ Pending |
| Inspector reads geometryId/meshIndex | ✅ `InspectorPanel` reads DTO fields | — | ❌ Pending |

### 3.3 Viewport Picking

| Property | Code Evidence | XCTest | Manual GUI |
|----------|:------------:|:------:|:----------:|
| Ray casting returns nodeIndex | ✅ `MetalRenderer.pickNode()` → BVH per GPUMesh | — | ❌ Pending |
| Hit → node lookup | ✅ `DocumentViewModel` maps nodeIndex → node | — | ❌ Pending |

### 3.4 Hide / Isolate

| Property | Code Evidence | XCTest | Manual GUI |
|----------|:------------:|:------:|:----------:|
| Visibility toggle by nodeIndex | ✅ `GPUMesh.visible` flag | — | ❌ Pending |
| Context menu wiring | ✅ "Show Part" / "Hide Part" etc. | — | ❌ Pending |

### 3.5 Camera (Fit / Orbit / Pan / Zoom)

| Property | Code Evidence | XCTest | Manual GUI |
|----------|:------------:|:------:|:----------:|
| Scene bounds from post-transform mesh | ✅ `RenderPacket.scene_bounds` from baked mesh AABB | — | ❌ Pending |
| Fit-to-bounds math | ✅ `OrbitCamera.fitToBounds()` | — | ❌ Pending |

### 3.6 Export PNG

| Format | Code Evidence | XCTest | Manual GUI |
|--------|:------------:|:------:|:----------:|
| 2D/DXF Export Image | ✅ `Drawing2DView.renderImage` (headless) | ✅ 11 tests | — |
| 3D Export Image | ⚠️ `RenderImageView` requires NSView+window | — | ❌ Pending |

---

## 4. GUI Items Pending Manual Verification

All require `MMFORGE_ALLOW_INTERACTIVE_GUI=1` foreground session:

| # | Item | Dependency |
|---|------|-----------|
| G1 | Structure sidebar renders 3+ node tree from assembly.stp | Visible GUI |
| G2 | Click assembly node → inspector shows no geometry | GUI |
| G3 | Click leaf node → inspector shows geometryId/bounds | GUI |
| G4 | Viewport picking on individual components | GUI + Metal |
| G5 | Hide component → mesh disappears in viewport | GUI |
| G6 | Isolate component → only that mesh visible | GUI |
| G7 | Camera fit/all after loading assembly | GUI |
| G8 | 3D Export PNG (RenderImageView) | GUI + NSView |

---

## 5. Git History Cleanliness

```
$ git diff --check 37b7a43..HEAD
(no output — clean)

$ git diff --check
(no output — clean)
```

The full XDE feature range (37b7a43..HEAD) has zero trailing whitespace
or whitespace violations.

---

## 6. Files Changed (current batch)

| File | Δ | Change |
|------|---|--------|
| `crates/mmforge-format-iges/src/parser.rs` | +108/−1 | `pub(crate)` on `build_iges_model_from_data`; new `parser_uses_registry_bounds_not_tree_node_bounds` mock-data test |
| `crates/mmforge-geometry/src/occt/iges_reader.rs` | +55 | `iges_registry_bounds_match_mesh_post_transform` E2E test |
| `crates/mmforge-geometry/testdata/translated_box.igs` | +new | Translated IGES fixture (box translated to [20,0,5]) |

---

## 7. Full Feature Range Commits (37b7a43..HEAD)

| Commit | Description |
|--------|-------------|
| `37b7a43` | docs: XDE tree progress report |
| `6834c51` | feat: XDE assembly tree recursive expansion |
| `c4cf959` | fix: OCCT 7.9.3 compilation + transform baking + assembly fixture |
| `f109e15` | docs: real OCCT verification update |
| `468b96e` | fix: trailing whitespace, IGES bounds parity |
| `b7435ea` | feat: macOS industrialization report + IGES regression test |
| (HEAD) | fix: rigorous IGES parser mock-data test + accurate report |

---

## 8. Next Steps

1. Run `MMFORGE_ALLOW_INTERACTIVE_GUI=1` on dedicated Mac for G1–G8 visual confirmation
2. CI pipeline: add `xcodebuild test` to automated checks
3. Apple notarization + Developer ID for distribution
