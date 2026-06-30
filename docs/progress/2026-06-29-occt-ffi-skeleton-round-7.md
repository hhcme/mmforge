# Phase 1 Goal 3 Round 7: OCCT FFI Link Probe Fix — Full-Path References + Fake Shim Validation

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix link-probe test compilation; validate end-to-end with a
        fake shim exporting all 13 symbols

---

## Problem

The link-probe test introduced in Round 6 used:

```rust
let sys = super::super::sys;
// then: sys.mmforge_step_reader_new as usize, ...
```

This fails to compile when `occt_found` is set because **modules are
not values in Rust** — `let sys = super::super::sys` is not a valid
binding.  The test was dead code (gated on `#[cfg(occt_found)]` which
was never set in CI), so the error was not caught until now.

Additionally, `as usize` directly on a function item triggers
`function_casts_as_integer` warnings — the correct pattern is
`as *const () as usize`.

---

## Solution

### 1. Full `crate::occt::sys::` paths (no intermediate variable)

```rust
let addrs: Vec<usize> = vec![
    crate::occt::sys::mmforge_step_reader_new as *const () as usize,
    crate::occt::sys::mmforge_step_reader_read_file as *const () as usize,
    // ... all 13 symbols ...
    crate::occt::sys::mmforge_occt_version as *const () as usize,
];
```

- Uses `crate::occt::sys::` prefix on every symbol — no module variable.
- Casts via `as *const () as usize` — avoids
  `function_casts_as_integer` warning.

### 2. Fake shim for end-to-end validation

Created a minimal C stub (`/tmp/mmforge_fake_shim.c`) implementing all
13 `extern "C"` functions with safe defaults (null/0/Ok).  Compiled to
`libmmforge_occt_shim.a` with `ar rcs`.

Also created minimal Mach-O dylib stubs for all 21 OCCT shared libs
(TKernel, TKMath, … TKService) so the linker can resolve the `-l`
flags.

### 3. Verified `occt_found` end-to-end

```
OCCT_INCLUDE_DIR=/tmp/mmforge_fake_occt/include \
OCCT_LIB_DIR=/tmp/mmforge_fake_occt/lib \
MMFORGE_SHIM_DIR=/tmp/mmforge_fake_shim \
cargo test -p mmforge-geometry --features occt
```

Result:

```
warning: OCCT shim verified at /tmp/mmforge_fake_shim. Real FFI enabled.

running 6 tests
test occt::adapter::tests::link_probe_references_all_shim_symbols ... ok
test occt::adapter::tests::status_to_result_errors ... ok
test occt::adapter::tests::status_to_result_ok ... ok
test occt::step_reader::tests::read_step_file_occt_placeholder_returns_not_available ... ok
test occt::step_reader::tests::shape_handle_stub ... ok
test tessellation::tests::deflection_scales_with_bbox ... ok

test result: ok. 6 passed; 0 failed
```

Key observations:

- `--cfg occt_found` appears in the rustc invocation (verbose output).
- `-l static=mmforge_occt_shim` and all 21 `-l TKernel …` flags are
  emitted.
- `link_probe_references_all_shim_symbols` compiles **and passes** —
  all 13 function addresses resolve to non-null, and
  `mmforge_occt_version()` returns `"0.0.0-fake"`.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/src/occt/adapter.rs` | Replaced `let sys = super::super::sys` with full `crate::occt::sys::` paths; changed `as usize` to `as *const () as usize` for all 13 function addresses |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo test -p mmforge-geometry --features occt` (with fake shim) | ✅ 6 tests pass (occt_found set, link probe passes) |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Fake Shim Artifacts

| File | Purpose |
|------|---------|
| `/tmp/mmforge_fake_shim.c` | C stubs for all 13 `extern "C"` functions |
| `/tmp/mmforge_fake_shim/libmmforge_occt_shim.a` | Compiled static archive |
| `/tmp/mmforge_fake_occt/lib/lib*.dylib` | 21 minimal Mach-O stubs for OCCT shared libs |

These are temporary test fixtures, not checked into the repository.
