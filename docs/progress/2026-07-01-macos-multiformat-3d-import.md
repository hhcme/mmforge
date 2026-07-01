# Multi-Format 3D Import: STL, glTF/GLB

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Multi-format 3D import with auto-detection, unified LSM model pipeline, structural fixes.

---

## Summary

The macOS viewer opens STL (binary/ASCII), glTF/GLB, and STEP files with automatic format detection. All formats flow through `mmf_parse_file`, produce a unified `LsmModel` + `TessellationRegistry`, and render identically in the Metal viewer.

IGES is **planned but not yet openable** — requires OCCT `IGESControl_Reader` adapter (C++ shim + Rust FFI). The IGES detection module (`iges_detector.rs`) exists with tests but is not wired into the parse pipeline. IGES is not listed as a supported UTType.

---

## Key Changes

### Round 1 — Initial multi-format
- STL parser, glTF parser, `mmf_parse_file` auto-detect, C header, Swift bridge, UTTypes

### Round 2 — Structural fixes
- glTF multi-root synthetic assembly, multi-primitive child nodes, data URI buffers, validate_references, IGES detection module

### Round 3 — Validation fixes
1. **macOS temp file extension preserved**: `MMForgeDocument` now stores `fileExtension` from `ReadConfiguration.file.filename`. Temp files are written with the original extension (`.stl`, `.glb`, `.gltf`, `.step`) so Rust format detection works correctly. Drag-and-drop also extracts the URL extension.
2. **IGES removed from openable formats**: No real parser exists. `com.mmforge.iges` UTType removed from Info.plist and `readableContentTypes`. IGES detection module kept (with `#[allow(dead_code)]`) for future OCCT integration.
3. **STL detection rewritten**: ASCII detection now uses "facet" keyword search (first 200 bytes) instead of fragile byte-range checks. Binary detection correctly disambiguates "solid" header edge case. Regression tests added for ASCII STL with digit bytes at offset 80-84 and binary STL with "solid" header.
4. **`c_path_to_rust` → `c_path_to_owned`**: Returns owned `PathBuf` instead of `&'static Path`. No more unsound lifetime extension from C string pointers. Callers updated to borrow `&path`.

---

## Detection Priority

```
mmf_parse_file(path):
  read first 84 bytes
  ├── STL? → parse_stl       (binary: "solid"+facet disambiguation, or valid tri_count)
  ├── glTF? → parse_gltf     (GLB magic "glTF", or JSON '{' + .gltf/.glb)
  ├── STEP? → parse_step     (ISO-10303-21 header)
  └── fallback → parse_step  (try STEP anyway)
```

---

## glTF Multi-Primitive Architecture

```
Node "Mesh" → geometry: None (container)
  ├─ Node "Mesh_prim0" → geometry: prim0
  ├─ Node "Mesh_prim1" → geometry: prim1
  └─ Node "Mesh_prim2" → geometry: prim2
```

Single-primitive meshes: geometry assigned directly to the node.

---

## glTF Multi-Root Architecture

```
scene.root → Node "glTF_Assembly" (parent: None)
  ├─ Node "A" (parent: Assembly)
  └─ Node "B" (parent: Assembly)
```

---

## Tests (29 total)

| Module | # | Key tests |
|--------|---|-----------|
| stl_parser | 9 | binary/ascii detection, solid+facet disambiguation, solid+digit regression, binary+solid header, fixture parsing |
| gltf_parser | 13 | GLB/glTF detection, data URI, multi-root assembly, single root, minimal triangle parse, decode errors |
| iges_detector | 7 | .igs/.iges detection, header marker, rejection (reserved, not wired) |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --all` | ✅ Clean |
| `cargo clippy -p mmforge-bridge` | ✅ No warnings |
| `cargo test -p mmforge-bridge` | ✅ 29 tests pass |
| `cargo test --workspace` | ✅ All pass |
| `cargo build -p mmforge-bridge --release` | ✅ Built |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test` | ✅ 22 tests pass |

---

## Open Items (not in this PR)

| Item | Status | Notes |
|------|--------|-------|
| IGES parsing | **Planned** | Requires `IGESCAFControl_Reader` in C++ shim + Rust FFI adapter |
| Normal transform under non-uniform scale | Known issue | `transform_vector3` is incorrect for non-uniform scale |
| STL parser dead code in `parse_binary_stl` | Harmless | First-pass normal logic is discarded and redone |

---

## New Dependencies

| Crate | Version | License | Purpose |
|-------|---------|---------|---------|
| `gltf` | 1.4.1 | MIT OR Apache-2.0 | glTF/GLB parsing |
| `base64` | 0.22.1 | MIT OR Apache-2.0 | Data URI buffer decoding |
| `tempfile` | 3.27 | MIT OR Apache-2.0 | Test fixtures (dev-dependency) |

---

## Modified / New Files

| File | Change |
|------|--------|
| `Cargo.toml` (workspace) | Added `base64`, `tempfile` deps |
| `crates/mmforge-bridge/Cargo.toml` | Added `base64`, `tempfile` dev-dep |
| `crates/mmforge-bridge/src/iges_detector.rs` | **New** — IGES detection (reserved, not wired) |
| `crates/mmforge-bridge/src/lib.rs` | `c_path_to_owned`, `mmf_parse_file` auto-detect, IGES gated |
| `crates/mmforge-bridge/src/gltf_parser.rs` | Multi-root/primitive fixes, data URI, validate_references |
| `crates/mmforge-bridge/src/stl_parser.rs` | Rewritten detection (facet-based ASCII disambiguation) |
| `macos/MMForge/Document/MMForgeDocument.swift` | `fileExtension` preserved from original filename |
| `macos/MMForge/Views/ContentView.swift` | Pass extension in parseFile + drag-drop |
| `macos/MMForge/Resources/Info.plist` | IGES UTType removed (planned only) |
