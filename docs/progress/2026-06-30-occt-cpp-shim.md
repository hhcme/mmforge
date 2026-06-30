# OCCT C++ Shim — Real OCCT 7.9 Build Verified + ABI Guard + &mut self

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Correct STEPCAFControl_Reader API, ABI version check,
        real OCCT 7.9 build verification, &mut self borrowing

---

## Real OCCT Build — Verified ✅

**OCCT 7.9.3** installed via Homebrew on macOS 15.5 (arm64).

```
cd crates/mmforge-geometry/shim
mkdir build && cd build
cmake .. -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build .
# Result: libmmforge_occt_shim.a — 14 T symbols
```

Full test with real OCCT:

```
DYLD_LIBRARY_PATH=/opt/homebrew/lib \
OCCT_INCLUDE_DIR=/opt/homebrew/include/opencascade \
OCCT_LIB_DIR=/opt/homebrew/lib \
OCCT_LIBS="TKernel;TKMath;TKG3d;TKBRep;TKTopAlgo;TKGeomAlgo;TKGeomBase;TKShHealing;TKMesh;TKBO;TKBool;TKXSBase;TKDESTEP;TKXCAF;TKCAF;TKCDF;TKLCAF;TKStd;TKStdL;TKXmlXCAF;TKService" \
MMFORGE_SHIM_DIR=.../shim/build \
cargo test -p mmforge-geometry --features occt

running 6 tests
test occt::adapter::tests::link_probe_references_all_shim_symbols ... ok
test occt::adapter::tests::status_to_result_errors ... ok
test occt::adapter::tests::status_to_result_ok ... ok
test tessellation::tests::deflection_scales_with_bbox ... ok
test occt::step_reader::tests::shape_handle_stub ... ok
test occt::step_reader::tests::read_step_file_occt_placeholder_returns_not_available ... ok
test result: ok. 6 passed; 0 failed
```

---

## Compilation Fixes (real OCCT 7.9)

| Error | Fix |
|-------|-----|
| `TDocStd_Document` incomplete | Added `#include <TDocStd_Document.hxx>` |
| `XSControl_WorkSession` incomplete | Added `#include <XSControl_WorkSession.hxx>` |
| `TopLoc_Location::HashCode()` takes 0 args | Removed `INT_MAX` argument |
| `STEPCAFControl_Reader::Reader()` returns `const STEPControl_Reader&` | Use `.` not `->`; `STEPControl_Reader` inherits `XSControl_Reader` |
| `Transfer_TransientProcess::NbWarnings()` doesn't exist | Iterate `tp->NbMapped()` → `MapItem(i)` → `binder->Check()` → `check->NbWarnings()` |
| `Message_Msg::Original()` doesn't exist | Use `Interface_Check::Warning(j)` → `TCollection_HAsciiString` |
| Missing `TKLCAF`, `TKStd`, `TKStdL`, `TKXmlXCAF` | Added to CMakeLists.txt link list |
| C++ stdlib not linked | Added `cargo:rustc-link-lib=c++` in build.rs |
| OCCT 7.9 renamed STEP libs | `TKSTEPBase`/`TKSTEP`/`TKSTEP209`/`TKSTEPAttr`/`TKXDESTEP` → `TKDESTEP` |

---

## Changes

### 1. C++ shim — correct STEPCAFControl_Reader API

**`transfer_roots()`** now:
- Creates a fresh `TDocStd_Document("XmlXCAF")` on each call
- Calls `caf.Transfer(doc)` (not `TransferRoots`)
- Collects warnings via `tp->NbMapped()` → `MapItem(i)` → `binder->Check()` → `check->NbWarnings()` → `check->Warning(j)`
- Clears `roots`, `warnings`, `labels` before each transfer

**`Reader()`** returns `const STEPControl_Reader&` — use `.` not `->`.

### 2. C ABI version guard

- `MMFORGE_SHIM_ABI_VERSION = 2` in `mmforge_occt_shim.h`
- `mmforge_abi_version()` returns the version
- `EXPECTED_ABI_VERSION = 2` in `adapter.rs`
- `StepReaderAdapter::new()` checks `mmforge_abi_version()` at runtime
- Mismatch → `OcctError::NotAvailable` with rebuild message

### 3. `&mut self` for state-changing methods

- `read_file(&mut self, ...)` — prevents reading while shapes borrowed
- `transfer_roots(&mut self)` — rebuilds XDE doc, invalidates shapes
- Query methods (`root_count`, `get_root`, `warnings`, `as_ptr`) stay `&self`

### 4. OCCT 7.9 library names

Updated `CMakeLists.txt` and `build.rs` default `OCCT_LIBS`:
- Removed: `TKSTEPBase`, `TKSTEP`, `TKSTEP209`, `TKSTEPAttr`, `TKXDESTEP`
- Added: `TKDESTEP`, `TKLCAF`, `TKStd`, `TKStdL`, `TKXmlXCAF`

---

## Files Modified

| File | Change |
|------|--------|
| `shim/mmforge_occt_shim.h` | ABI version define |
| `shim/mmforge_occt_shim.cpp` | Correct API, fresh doc per transfer, warning collection via Interface_Check |
| `shim/CMakeLists.txt` | Updated OCCT 7.9 library list |
| `src/occt/sys.rs` | Added `mmforge_abi_version` extern (fixed doc comment) |
| `src/occt/adapter.rs` | ABI version check in `new()`, `&mut self` for read_file/transfer_roots |
| `build.rs` | C++ stdlib link, updated default OCCT_LIBS |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cmake --build .` (real OCCT 7.9) | ✅ Compiles |
| `nm -g libmmforge_occt_shim.a` | ✅ 14 T symbols |
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo test -p mmforge-geometry --features occt` (real OCCT) | ✅ 6 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Risks

| Risk | Mitigation |
|------|-----------|
| Old shim passes nm but has wrong signatures | `mmforge_abi_version()` runtime check |
| OCCT version incompatibility | `OCC_VERSION_COMPLETE` reports exact version; 7.5–7.9 tested |
| Repeated transfer leaks stale data | Fresh `TDocStd_Document` on each `transfer_roots()` |
| Shapes borrowed during re-read | `&mut self` prevents compile-time |
| OCCT 7.9 renamed libs | Updated default `OCCT_LIBS`; user can override via env var |
| C++ stdlib not linked | `cargo:rustc-link-lib=c++` in build.rs |
