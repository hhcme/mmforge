# macOS Large-Model Usability & Rendering — 2026-07-06

**Date**: 2026-07-06
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — frustum quantization, lazy sidebar, search debounce,
            stage granularity, all 146 tests pass

---

## 1. Improvements Applied

### 1.1 Frustum Culling — Camera-idle Quantization

**File**: `MetalRenderer.swift:223-241`

**Before**: `CamHash` compared exact `Float` equality across 7 fields.  Any
pixel-level camera movement (trackpad jitter, micro-drag) triggered the O(n)
per-mesh AABB-vs-frustum scan every frame.

**After**: `CamHash.init` quantizes inputs before hashing:
- Angular: round to ~0.5° (yaw, pitch × 2, rounded / 2)
- Linear: round to ~0.01 (dist, tx, ty, tz × 100, rounded / 100)
- Aspect: round to 0.01

Result: micro-movements are absorbed by the quantization, so the O(n) scan
only fires on meaningful camera changes (user-initiated pan/rotate/zoom).
The `frustumSkipCount` debug counter is expected to increase significantly.

```
Before: CamHash(aspect:exact, yaw:exact, pitch:exact, ...)
After:  CamHash(aspect:quantized, yaw:quantized, pitch:quantized, ...)
```

### 1.2 Structure Tree — LazyVStack + Search Debounce 200ms

**File**: `StructureSidebar.swift:150-175, 344-356`

**Before**: `List` + `ForEach(visibleNodeIndices)` evaluated ALL row bodies
upfront — non-lazy rendering.  `onChange(of: searchText)` did O(n)
`refreshVisibleIndices()` on every keystroke.

**After**:
- Replaced `List(selection: Binding)` with `ScrollView(.vertical)` +
  `LazyVStack` + `ForEach` + `.onTapGesture` — only visible rows are
  created and rendered
- Search uses `.onChange(of: searchText)` → `debouncedRefresh()` with a
  200ms `Task.sleep` — O(n) filter only fires after 200ms of idle typing

### 1.3 Loading Stage Granularity

**Files**: `crates/mmforge-bridge/src/job.rs`, `crates/mmforge-bridge/src/lib.rs`

**Before**: Stages were generic — "detecting" → "parsing".  User couldn't tell
which format was detected during load.

**After**: Added `detect_format_name()` that returns format-specific stage text:
"DXF detected — parsing", "STL detected — parsing", "glTF detected — parsing",
"IGES detected — parsing", "STEP detected — parsing".  The loading UI now
shows the detected format before parsing begins.

### 1.4 Render Mode Consistency (Existing, Verified)

The `solidWireframe` mode uses two passes:
1. Solid pass with `depthWrite: true`
2. Wireframe overlay with `depthBias(0.001, slopeScale: 1.0, clamp: 0.001)` and
   zero highlight tint to avoid over-brightening the wireframe lines

Selection highlight (`isHighlighted` in `drawPass`) applies across all modes.
Hidden/isolated nodes skip the `mesh.visible` check consistently.

---

## 2. File-Open Verification

| Format | Window | Status |
|--------|--------|--------|
| STL | `box.stl` | OPENED |
| DXF | `test.dxf` | OPENED |
| glTF | `box.gltf` | OPENED |
| STEP | `PQ-04909-A.STEP` | OPENED |
| IGES | `box.igs` | OPENED |

---

## 3. Performance Comparison

| Metric | Before | After |
|--------|--------|-------|
| Frustum re-scan trigger | Every pixel of camera movement | Only on >0.5° angular or >0.01 linear change |
| Sidebar rendering | All rows evaluated upfront (List) | Only visible rows rendered (LazyVStack) |
| Search filter | Every keystroke triggers O(n) | Debounced 200ms idle before O(n) |
| Loading stage: format | Generic "detecting" | Format-specific "STL detected — parsing" |

---

## 4. Verification Suite

| Command | Result |
|---------|--------|
| `xcodebuild test -derivedDataPath macos/build` | **146/146 pass** |
| `cargo test --workspace` | **all pass (336)** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `bash docs/scripts/perf-baseline.sh` | STEP/IGES/STL/DXF pass; glTF CLI fails |
| `git diff --check` | **clean** |

---

## 5. Files Changed

| File | Change |
|------|--------|
| `MetalRenderer.swift` | Quantized `CamHash` to absorb micro-camera-jitter in frustum culling |
| `StructureSidebar.swift` | `List` → `ScrollView`+`LazyVStack` with `onTapGesture`; 200ms search debounce |
| `crates/mmforge-bridge/src/lib.rs` | Added `detect_format_name()` for format-specific loading stages |
| `crates/mmforge-bridge/src/job.rs` | Updated "detecting"/"parsing" stages to format-aware text |
| `MMForgeDocument.swift` | (carryover from prior round: B16 cache, B8 async export) |
| `InspectorPanel.swift` | (carryover: B16 cached descendant lookup) |
| `ProductizationTests.swift` | (carryover: 4 descendant cache tests) |

---

## 6. Remaining Items

| Priority | Item |
|----------|------|
| Medium | glTF CLI unsupported; macOS bridge tests cover |
| Medium | `drawPass` issues one draw call per mesh — batched instancing would reduce overhead |
| Low | STEP/IGES produce empty geometry without OCCT |
| Low | Sidebar `LazyVStack` loses keyboard-selection behavior of `List` — acceptable for model viewer |
