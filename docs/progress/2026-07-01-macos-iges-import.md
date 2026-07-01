# IGES/IGS End-to-End Import via OCCT

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Full IGES/IGS file opening via OCCT IGESCAFControl_Reader, mirroring the STEP pipeline.

---

## Summary

IGES/IGS files are now fully openable in the macOS viewer. The pipeline mirrors STEP exactly:

```
IGES file → IGESCAFControl_Reader → XDE document → shapes → tessellation → RenderPacket → Metal
```

The implementation adds IGES support at every layer: C++ shim, Rust FFI, safe adapter, format parser crate, bridge dispatch, and macOS UTType/document registration.

---

## Architecture

The IGES pipeline reuses the same shape/tessellation/mesh infrastructure as STEP. Only the reader lifecycle differs:

| Layer | STEP | IGES |
|-------|------|------|
| C++ shim | `STEPCAFControl_Reader` via `ReaderWrapper` | `IGESCAFControl_Reader` via `IgesReaderWrapper` |
| OCCT lib | `TKDESTEP` | `TKDEIGES` |
| Rust FFI | `StepControlReader` opaque + 8 extern "C" | `IgesControlReader` opaque + 8+3 extern "C" |
| Rust adapter | `StepReaderAdapter` + `ShapeHandle` | `IgesReaderAdapter` + `IgesShapeHandle` |
| Reader module | `step_reader.rs` → `StepData` | `iges_reader.rs` → `IgesData` |
| Format crate | `mmforge-format-step` | `mmforge-format-iges` |
| Bridge dispatch | `detect_step` → `parse_step_with_tessellation` | `detect_iges` → `parse_iges_with_tessellation` |

Shape queries (`mmforge_iges_shape_type/bbox/label`) are separate functions that take `const MmfIgesReader*` but delegate to the same internal logic. Tessellation reuses `mmforge_tessellate_shape` (which ignores the reader parameter).

---

## Files Changed

### C++ Shim

**`crates/mmforge-geometry/shim/mmforge_occt_shim.cpp`**
- Added `#include <IGESCAFControl_Reader.hxx>`
- Added `IgesReaderWrapper` struct (same pattern as `ReaderWrapper`)
- Added 8 IGES reader functions: `mmforge_iges_reader_new/read_file/transfer_roots/root_count/get_root/warning_count/get_warning/free`
- Added 3 IGES shape functions: `mmforge_iges_shape_type/bbox/label`
- Transfer warnings collected via `caf.WS()->TransferReader()->TransientProcess()`

**`crates/mmforge-geometry/shim/mmforge_occt_shim.h`**
- Added `MmfIgesReader` opaque type
- Added all 11 IGES function declarations
- Bumped `MMFORGE_SHIM_ABI_VERSION` from 2 to 3

**`crates/mmforge-geometry/shim/CMakeLists.txt`**
- Added `TKDEIGES` to `target_link_libraries`

### Rust FFI + Adapter

**`crates/mmforge-geometry/src/occt/sys.rs`**
- Added `IgesControlReader` opaque type
- Added `#[cfg(occt_found)] extern "C"` block with 11 IGES functions

**`crates/mmforge-geometry/src/occt/adapter.rs`**
- Bumped `EXPECTED_ABI_VERSION` to 3
- Added `IgesReaderAdapter` (new/read_file/transfer_roots/root_count/get_root/warnings/Drop)
- Added `IgesShapeHandle` (shape_type/bbox/label/to_handle)
- Added `TessellatedMesh::tessellate_iges()` — casts IGES reader pointer for shared tessellation
- Updated link probe test with 11 new IGES symbols
- Added stubs for `#[cfg(not(occt_found))]`

**`crates/mmforge-geometry/src/occt/iges_reader.rs`** — **New**
- `IgesData` struct (shapes + transfer_messages)
- `read_iges_file(path)` → `Result<IgesData>`
- `read_iges_file_with_tessellation(path)` → `Result<(IgesData, TessellationRegistry)>`
- `extract_shapes(data)` → `&[OcctShapeHandle]`

**`crates/mmforge-geometry/src/occt/mod.rs`**
- Added `pub mod iges_reader;`

### Build Script

**`crates/mmforge-geometry/build.rs`**
- Added `TKDEIGES` to default `OCCT_LIBS`
- Added 11 `mmforge_iges_*` symbols to `REQUIRED_SHIM_SYMBOLS`

### Format Parser Crate

**`crates/mmforge-format-iges/`** — **New crate**
- `Cargo.toml` — depends on mmforge-core + mmforge-geometry, `occt` feature gate
- `src/lib.rs` — re-exports
- `src/detect.rs` — `detect_iges(header, path)` with `.igs`/`.iges` extension + header marker detection, 6 tests
- `src/parser.rs` — `IgesParser` implementing `FormatParser`, `parse_iges_with_tessellation()` with full OCCT pipeline

### Bridge

**`crates/mmforge-bridge/Cargo.toml`** — Added `mmforge-format-iges` dependency

**`crates/mmforge-bridge/src/lib.rs`**
- Removed `#[allow(dead_code)]` from `mod iges_detector`
- Added IGES detection branch in `mmf_parse_file`: `iges_detector::detect_iges` → `mmforge_format_iges::parse_iges_with_tessellation`

### macOS

**`macos/MMForge/Resources/Info.plist`**
- Added `com.mmforge.iges` UTType with extensions `igs`/`iges`
- Added to `CFBundleDocumentTypes` LSItemContentTypes

**`macos/MMForge/Document/MMForgeDocument.swift`**
- Added `static let iges = UTType("com.mmforge.iges")!`
- Added `.iges` to `readableContentTypes`

**`macos/MMForge.xcodeproj/project.pbxproj`**
- Added `TKDEIGES` to `OCCT_LIBS` in build script
- Added `-lTKDEIGES` to `OTHER_LDFLAGS` in both Debug and Release

---

## Detection Priority (updated)

```
mmf_parse_file(path):
  read first 84 bytes
  ├── STL? → parse_stl
  ├── glTF? → parse_gltf
  ├── IGES? → parse_iges_with_tessellation   ← NEW
  ├── STEP? → parse_step_with_tessellation
  └── fallback → parse_step
```

---

## Tests

| Module | # | Key tests |
|--------|---|-----------|
| mmforge-format-iges detect | 6 | .igs/.iges detection, header marker, rejection |
| mmforge-geometry (OCCT) | 8 | link probe (33 symbols), STEP tessellation E2E |
| mmforge-bridge | 33 | STL/glTF/IGES detection, parsing |
| mmforge-core | 55 | model validation, scene tree |
| mmforge-format-step | 12 | STEP detection, parser |
| mmforge-render | 10 | render packet, camera |
| Xcode | 22 | BVH picking tests |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cmake --build shim/build` | ✅ IGES shim compiles |
| `nm -gU libmmforge_occt_shim.a` | ✅ 11 IGES symbols exported |
| `cargo fmt --all` | ✅ Clean |
| `cargo check --workspace` | ✅ Clean |
| `cargo test --workspace` | ✅ 120 tests pass |
| `cargo clippy --workspace` | ✅ No warnings |
| `cargo test -p mmforge-geometry --features occt` | ✅ 8 tests pass (link probe OK) |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test` | ✅ 22 tests pass |

---

## Dependencies

| Crate | Version | License | Purpose |
|-------|---------|---------|---------|
| `TKDEIGES` (OCCT 7.9) | — | LGPL 2.1 | IGES data exchange |

No new Rust crate dependencies added (reuses existing mmforge-core, mmforge-geometry, glam, thiserror).
