# mmforge_occt_shim — OpenCASCADE C++ Bridge

Static library bridging the 22 `extern "C"` functions declared in
`mmforge-geometry/src/occt/sys.rs` to real OpenCASCADE C++ API calls.
Includes STEP reading, shape queries, and B-Rep tessellation.

## Prerequisites

- **OpenCASCADE >= 7.5** (headers + libraries)
- **CMake >= 3.16**
- **C++17 compiler**

## Build

```bash
cd crates/mmforge-geometry/shim
mkdir build && cd build

# Option A: OpenCASCADE found via system paths
cmake ..

# Option B: specify OCCT location explicitly
cmake .. -DOpenCASCADE_DIR=/path/to/occt/lib/cmake/opencascade

# Option C: via prefix path
cmake .. -DCMAKE_PREFIX_PATH=/opt/opencascade

# Build
cmake --build .

# Optional: install system-wide
cmake --install . --prefix /usr/local
```

## Integration with mmforge-geometry

The Rust `build.rs` auto-detects the shim in these locations (in order):

1. `MMFORGE_SHIM_DIR` env var (explicit override)
2. `shim/build/lib/` (CMake default install prefix)
3. `shim/build/` (CMake build directory)
4. `../target/shim/lib/` (Cargo workspace target)
5. `/usr/local/lib/`
6. `/opt/homebrew/lib/`

If auto-detect finds `libmmforge_occt_shim.a`, it validates the archive
(ar magic + nm symbol check) and sets `occt_found`.

## Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `OCCT_INCLUDE_DIR` | Yes | OCCT header directory |
| `OCCT_LIB_DIR` | Yes | OCCT library directory |
| `OCCT_LIBS` | No | Semicolon-separated lib list (default: 21 STEP libs) |
| `MMFORGE_SHIM_DIR` | No | Explicit shim directory (overrides auto-detect) |

## Architecture

```
Rust (sys.rs)           C (shim header)        C++ (shim impl)         OCCT
┌──────────────┐       ┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│ extern "C"   │──────>│ MmfStepReader│──────>│ ReaderWrapper│──────>│ STEP Control │
│ declarations │       │ MmfShape     │       │ cafReader    │       │ XCAF         │
│              │       │ MmfOcctError │       │ shapeTool    │       │ BRep / Bnd   │
│              │       │ MmfOcctBBox  │       │ roots/warns  │       │ BRepMesh     │
│              │       │ MmfMesh      │──────>│ MeshData     │──────>│ Poly_Tri     │
│              │       │ MmfOcctShape │       │ positions    │       │ TopExp       │
│              │       │              │       │ normals/idx  │       │ TopLoc       │
└──────────────┘       └──────────────┘       └──────────────┘       └──────────────┘
```

## Verification

```bash
# After building the shim:
nm -g --defined-only build/lib/libmmforge_occt_shim.a | grep mmforge_
# Should show all 22 symbols

# With real OCCT:
OCCT_INCLUDE_DIR=/opt/occt/include \
OCCT_LIB_DIR=/opt/occt/lib \
MMFORGE_SHIM_DIR=$(pwd)/build/lib \
cargo test -p mmforge-geometry --features occt
```
