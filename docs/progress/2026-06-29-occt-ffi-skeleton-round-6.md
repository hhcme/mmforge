# Phase 1 Goal 3 Round 6: OCCT FFI Shim Validation — nm-Based Symbol Verification

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Replace byte-scan shim validation with `nm`/`llvm-nm` symbol
        verification; expand `REQUIRED_SHIM_SYMBOLS` to all 13 `extern "C"`
        symbols; add comprehensive link-probe test

---

## Problem

Round 5 validated shim archives by scanning raw bytes for symbol name
substrings.  This approach is fragile:

- **False positives**: byte patterns matching symbol names can appear in
  `.o` data sections, string literals, or debug info.
- **No actual linker guarantee**: a symbol name in the archive body does
  not mean the linker can resolve it (it could be an undefined
  reference, a weak alias, etc.).
- **Incomplete symbol list**: only 3 of 13 symbols were checked.

---

## Solution

### 1. `nm`-based symbol verification (`nm_defined_symbols`)

Runs `nm` (or `llvm-nm`) on `libmmforge_occt_shim.a` and parses the
output for **defined** global symbols (T/t/D/d/b sections).

Tool cascade (first success wins):

| # | Command | Platform |
|---|---------|----------|
| 1 | `nm -gjU` | macOS system nm |
| 2 | `nm -g --defined-only` | GNU nm (Linux / Homebrew) |
| 3 | `llvm-nm -g --defined-only` | LLVM nm (cross-platform fallback) |

Symbol names are normalised by stripping the leading `_` (macOS C-ABI
convention) so the same `REQUIRED_SHIM_SYMBOLS` list works on all
platforms.

If **no** `nm` tool succeeds, validation fails with an explicit error
— there is no silent fallback to byte scanning.

### 2. `REQUIRED_SHIM_SYMBOLS` expanded to all 13 extern symbols

Every `extern "C"` function declared in `sys.rs` under `#[cfg(occt_found)]`
is now required:

```
STEPControl_Reader (8 symbols):
  mmforge_step_reader_new
  mmforge_step_reader_read_file
  mmforge_step_reader_transfer_roots
  mmforge_step_reader_root_count
  mmforge_step_reader_get_root
  mmforge_step_reader_warning_count
  mmforge_step_reader_get_warning
  mmforge_step_reader_free

TopoDS_Shape (4 symbols):
  mmforge_shape_type
  mmforge_shape_bbox
  mmforge_shape_label
  mmforge_shape_free

Version (1 symbol):
  mmforge_occt_version
```

A partial shim missing **any** of these → rejected, no `occt_found`,
no link output.

### 3. Link-probe test references all 13 symbols

The test in `adapter.rs` now takes the address of **every** extern
function and asserts each resolves to a non-zero address:

```rust
let addrs: Vec<usize> = vec![
    sys.mmforge_step_reader_new as usize,
    sys.mmforge_step_reader_read_file as usize,
    // ... all 13 symbols ...
    sys.mmforge_occt_version as usize,
];
for (i, &addr) in addrs.iter().enumerate() {
    assert_ne!(addr, 0, "extern symbol at index {i} resolved to null");
}
```

This ensures the linker resolves every symbol — not just one.  If even
one symbol is missing from the shim, the test fails to link.

### 4. `validate_shim_archive` flow (updated)

```
File readable?
├── No → error
└── Yes → non-empty?
         ├── No → error
         └── Yes → ar magic?
                  ├── No → error
                  └── Yes → nm_defined_symbols()
                           ├── nm fails → error
                           └── nm succeeds → check all 13 symbols
                                            ├── all present → Ok
                                            └── missing N → error
```

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/build.rs` | Replaced `archive_has_symbols` byte-scan with `nm_defined_symbols`; expanded `REQUIRED_SHIM_SYMBOLS` from 3 to 13 symbols; removed dead `archive_has_symbols` function |
| `crates/mmforge-geometry/src/occt/adapter.rs` | Updated link-probe test to reference all 13 symbols via address-of; renamed to `link_probe_references_all_shim_symbols` |

---

## Architecture: occt_found Decision Tree

```
feature = "occt" enabled?
├── No → stubs only
└── Yes → locate_occt()  [collects data, emits NOTHING]
         ├── OCCT not found → warning, stubs
         └── OCCT found → check MMFORGE_SHIM_DIR
              ├── Not set → warning, stubs
              ├── Shim missing/unreadable → warning, stubs
              ├── Shim is 0 bytes → warning, stubs
              ├── Shim has bad ar magic → warning, stubs
              ├── nm tool unavailable → error, stubs
              ├── nm missing symbols → warning, stubs
              ├── OCCT lib dir empty → warning, stubs
              └── All 13 symbols verified →
                   emit ALL link directives (OCCT + shim)
                   set occt_found
                   real FFI enabled
```

---

## Validation Layers Summary

| Layer | Where | What | Strength |
|-------|-------|------|----------|
| File existence | build.rs | metadata check | Basic I/O |
| Ar magic | build.rs | `!<arch>\n` header | Format validation |
| Symbol exports | build.rs | `nm`-based, 13 symbols | Linker-grade verification |
| Link resolution | adapter.rs test | address-of all 13 symbols | Actual linker check |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
