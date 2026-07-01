# Multi-Format 3D Import: STL, glTF/GLB

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Multi-format 3D import with auto-detection, unified LSM model pipeline, structural fixes.

---

## Summary

The macOS viewer opens STL (binary/ASCII), glTF/GLB, and STEP files with automatic format detection. All formats flow through `mmf_parse_file`, produce a unified `LsmModel` + `TessellationRegistry`, and render identically in the Metal viewer.

IGES is **planned but not yet openable** — requires OCCT `IGESControl_Reader` adapter (C++ shim + Rust FFI). The IGES detection module (`iges_detector.rs`) exists with tests but is not wired into the parse pipeline. IGES is not listed as a supported UTType or `readableContentTypes`.

---

## Key Changes (cumulative)

### Round 1 — Initial multi-format
- STL parser, glTF parser, `mmf_parse_file` auto-detect, C header, Swift bridge, UTTypes

### Round 2 — Structural fixes
- glTF multi-root synthetic assembly, multi-primitive child nodes, data URI buffers, validate_references, IGES detection module

### Round 3 — Validation fixes
- macOS temp file extension preserved from original filename
- IGES removed from openable formats (no real parser)
- STL detection rewritten with "facet" keyword disambiguation
- `c_path_to_rust` → `c_path_to_owned` (owned PathBuf)

### Round 4 — STL robustness + format strictness
- **Removed `.data` from `readableContentTypes`**: Only explicitly supported formats (STEP/STP, STL, glTF/GLB) are openable. No catch-all fallback.
- **STL solid-first-ASCII parsing**: `parse_stl` now tries ASCII parse first when "solid" prefix is present. If ASCII produces 0 triangles, falls back to strict binary. This correctly handles binary STL with "solid" in the 80-byte header.
- **STL full-file "facet" scan**: `is_ascii_stl` searches the entire file for "facet", not just the first 200 bytes. Handles ASCII STL with very long header lines.
- **STL strict binary validation**: `parse_binary_stl` rejects files where `len > 84 + tri_count*50 + 80` (significant size mismatch). Accepts small trailing padding (nulls, newlines).
- **Regression tests**: solid header with "facet" after 200 bytes, binary strict length rejection, binary small padding acceptance.

### Round 5 — STL binary/ASCII disambiguation fix
- **Prefer binary when file structure validates**: `parse_stl` now checks `binary_length_valid` first. If the file length matches `84 + tri_count * 50` exactly (±80 bytes padding), it's parsed as binary regardless of "solid" prefix or "facet" bytes in the data. Binary's exact-length check is a much stronger signal than searching for text keywords in potentially binary data.
- **ASCII is now a fallback**: `is_probably_ascii` only checks for "solid" prefix (no "facet" search). It's only reached when binary validation has already failed.
- **Regression test**: binary STL with "solid" header + "facet" bytes embedded in triangle data + non-UTF-8 bytes — correctly parsed as binary.

---

## Detection Priority

```
mmf_parse_file(path):
  read first 84 bytes
  ├── STL? → parse_stl       (extension .stl + solid/reasonable tri_count)
  ├── glTF? → parse_gltf     (GLB magic "glTF", or JSON '{' + .gltf/.glb)
  ├── STEP? → parse_step     (ISO-10303-21 header)
  └── fallback → parse_step  (try STEP anyway)
```

STL internal disambiguation:
```
parse_stl(data):
  binary_length_valid? (exact 84 + tri_count*50 ± 80 bytes)
  ├── yes → parse_binary_stl   (binary preferred — strongest signal)
  └── no  → is_probably_ascii? (starts with "solid")
            ├── yes → parse_ascii_stl
            └── no  → error "neither binary nor ASCII"
```

---

## glTF Architecture

Multi-primitive: parent node → `geometry: None`, each primitive → child node (`{name}_prim{idx}`).
Multi-root: synthetic `glTF_Assembly` root with orphan roots re-parented.

---

## Tests (33 total)

| Module | # | Key tests |
|--------|---|-----------|
| stl_parser | 13 | binary/ascii detection, solid+facet disambiguation, solid+digit regression, binary+solid header, facet-after-200-bytes, solid+facet-bytes+non-UTF-8 regression, strict length rejection, small padding acceptance, fixture parsing |
| gltf_parser | 13 | GLB/glTF detection, data URI, multi-root assembly, single root, minimal triangle parse, decode errors |
| iges_detector | 7 | .igs/.iges detection, header marker, rejection (reserved, not wired) |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --all` | ✅ Clean |
| `cargo clippy -p mmforge-bridge` | ✅ No warnings |
| `cargo test -p mmforge-bridge` | ✅ 33 tests pass |
| `cargo test --workspace` | ✅ All pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |
| `xcodebuild test` | ✅ 22 tests pass |

---

## Open Items (not in this PR)

| Item | Status | Notes |
|------|--------|-------|
| IGES parsing | **Planned** | Requires `IGESCAFControl_Reader` in C++ shim + Rust FFI adapter |
| Normal transform under non-uniform scale | Known issue | `transform_vector3` is incorrect for non-uniform scale |

---

## Dependencies

| Crate | Version | License | Purpose |
|-------|---------|---------|---------|
| `gltf` | 1.4.1 | MIT OR Apache-2.0 | glTF/GLB parsing |
| `base64` | 0.22.1 | MIT OR Apache-2.0 | Data URI buffer decoding |
| `tempfile` | 3.27 | MIT OR Apache-2.0 | Test fixtures (dev-dep) |

---

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-bridge/src/lib.rs` | `c_path_to_owned`, `mmf_parse_file`, IGES gated |
| `crates/mmforge-bridge/src/stl_parser.rs` | Full-file facet scan, ASCII-first parse, strict binary validation |
| `crates/mmforge-bridge/src/gltf_parser.rs` | Multi-root/primitive fixes, data URI, validate_references |
| `crates/mmforge-bridge/src/iges_detector.rs` | IGES detection (reserved, not wired) |
| `macos/MMForge/Document/MMForgeDocument.swift` | `fileExtension` preserved, `.data` removed from readableContentTypes |
| `macos/MMForge/Views/ContentView.swift` | Extension passed in parseFile + drag-drop |
| `macos/MMForge/Resources/Info.plist` | IGES UTType removed |
