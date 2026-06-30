# macOS Metal 3D Viewer — Main Chain

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: macOS SwiftUI/AppKit document-based app with Metal 3D viewer,
        Rust C ABI bridge, real STEP file rendering

---

## Summary

The macOS app now has a working main chain: STEP file → Rust C ABI
bridge → tessellation → RenderPacket → Metal 3D rendering.

The app builds with `xcodebuild` (with real OCCT), opens STEP files
via Cmd+O or drag-and-drop, parses them through the Rust bridge, and
renders the tessellated mesh in a Metal view with diffuse lighting.

---

## Fixes Applied (this round)

### 1. Xcode Run Script builds with OCCT

The Run Script build phase now:
- Detects `libmmforge_occt_shim.a` at `MMFORGE_SHIM_DIR`
- If found: builds with `--features occt` and sets OCCT env vars
- If not found: builds without OCCT (stub mode)
- Default OCCT paths: `/opt/homebrew/include/opencascade`, `/opt/homebrew/lib`

### 2. Renderer race condition fixed

`DocumentViewModel` now stores a `pendingDTO` when parsing completes
before the Metal renderer is created.  When `setRenderer()` is called,
the pending DTO is uploaded immediately.

### 3. CString leak fixed

`mmf_node_name` no longer leaks CString.  Node names are pre-computed
as `Vec<CString>` in `MmfDocument` and returned as borrowed pointers.
Freed when `mmf_document_free()` is called.

### 4. C++ stdlib + OCCT libs linked

Added `-lc++` and all 21 OCCT libraries to `OTHER_LDFLAGS` in the
Xcode project.  Added `/opt/homebrew/lib` to `LIBRARY_SEARCH_PATHS`.

---

## Architecture

```
User opens STEP file (Cmd+O / drag-drop)
  → MMForgeDocument stores file data
  → DocumentViewModel.parseFile(data:)
    → writes temp file
    → RustBridge.parseFile(at:) [background thread]
      → mmf_parse_step(path) [C ABI → Rust]
        → parse_step_with_tessellation()
        → build_render_packet()
      → RenderPacketDTO (flat C arrays)
    → MetalRenderer.upload(dto:)
      → interleaved vertex buffers (position+normal, 24 bytes)
      → index buffers
      → scene bounds → camera.fit()
  → MTKView renders each frame
    → vertex_main: MVP transform
    → fragment_main: N·L diffuse lighting
```

---

## Files Created

### `crates/mmforge-bridge/` — Rust C ABI bridge

| File | Purpose |
|------|---------|
| `Cargo.toml` | staticlib crate, depends on mmforge-format-step + mmforge-render |
| `src/lib.rs` | 15 `#[unsafe(no_mangle)] pub extern "C"` functions |

C ABI functions:
- `mmf_parse_step(path) → *mut MmfDocument` — parse+tessellate+build
- `mmf_document_free(doc)` — free
- `mmf_last_error() → *const c_char` — error message
- `mmf_version() → *const c_char` — version string
- `mmf_mesh_count/vertex_count/index_count` — mesh queries
- `mmf_mesh_positions/normals/indices` — borrowed data pointers
- `mmf_scene_bounds` — bounding box
- `mmf_node_count/name` — scene tree
- `mmf_triangle_count/material_count` — stats

### `macos/MMForge/RustBridge/mmforge_bridge.h`

C header declaring all `mmf_*` functions and `MmfDocument` opaque type.

### `macos/MMForge/RustBridge/RustBridge.swift`

Rewritten to call real C ABI functions. `RenderPacketDTO` holds flat
arrays for Metal upload. `parseFile(at:)` returns `(OpaquePointer,
RenderPacketDTO)`.

### `macos/MMForge/Metal/Shaders.metal`

Metal shader:
- `vertex_main`: MVP transform, pass world-space normal
- `fragment_main`: N·L diffuse lighting, ambient floor 0.15

### `macos/MMForge/Metal/MetalRenderer.swift`

`MetalRenderer: NSObject, MTKViewDelegate`:
- Interleaved vertex buffer upload (24 bytes: position+normal)
- Orbit camera with rotate/zoom/pan/fitToView
- Depth stencil (depth32Float, less-than compare)
- Per-frame: clear → set pipeline → upload uniforms → draw indexed

---

## Files Modified

| File | Change |
|------|--------|
| `Cargo.toml` (workspace) | Added mmforge-bridge to members |
| `MMForge-Bridging-Header.h` | Include mmforge_bridge.h |
| `MMForgeDocument.swift` | Added `DocumentState` enum, `DocumentViewModel` with async parsing |
| `ViewportContainer.swift` | Real MTKView + MetalRenderer, loading/error/empty states, gestures |
| `ContentView.swift` | Drag-drop support, `@Binding var document`, wired to ViewModel |
| `StructureSidebar.swift` | Accepts `nodeNames` from ViewModel |
| `MMForgeApp.swift` | Fixed `file.$document` binding |
| `Info.plist` | Registered `com.mmforge.step` UTType with .step/.stp extensions |
| `project.pbxproj` | Added Run Script build phase, library search paths, linker flags |

---

## Data Flow

```
STEP file
  → MMForgeDocument.fileData
  → DocumentViewModel.parseFile(data:)
    → write to temp file
    → RustBridge.parseFile(at:) [background]
      → mmf_parse_step(path) [C ABI]
        → parse_step_with_tessellation()
          → OCCT STEPCAFControl_Reader
          → BRepMesh_IncrementalMesh
          → TessellationRegistry
        → build_render_packet(registry)
          → RenderPacket
      → RenderPacketDTO (extract flat arrays)
    → MetalRenderer.upload(dto:)
      → interleaved vertex buffers
      → index buffers
      → camera.fit(center, radius)
  → MTKView.draw(in:)
    → vertex_main (MVP transform)
    → fragment_main (diffuse lighting)
    → present drawable
```

---

## Gesture Controls

| Gesture | Action |
|---------|--------|
| Drag | Orbit (yaw + pitch) |
| Alt+Drag | Pan |
| Scroll/Magnify | Zoom |

---

## UI States

| State | View |
|-------|------|
| `.empty` | EmptyStateView (cube icon + "Open a STEP file") |
| `.loading` | LoadingStateView (spinner + "Parsing STEP file…") |
| `.loaded` | MetalViewWrapper (MTKView with MetalRenderer) |
| `.error(msg)` | ErrorStateView (warning icon + error message) |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 79 tests pass |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 84 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo build --release -p mmforge-bridge --features occt` | ✅ Builds with OCCT |
| `xcodebuild -scheme MMForge build` (real OCCT) | ✅ BUILD SUCCEEDED |

---

## Risks

| Risk | Mitigation |
|------|-----------|
| Metal Toolchain not installed | `xcodebuild -downloadComponent MetalToolchain` |
| OCCT not available in CI | Bridge returns error, app shows error state |
| Large STEP files block UI | Background thread parsing |
| Temp file cleanup | Removed after parsing |
| `NSGestureRecognizer.modifierFlags` macOS 26+ | Use `NSApp.currentEvent?.modifierFlags` |
