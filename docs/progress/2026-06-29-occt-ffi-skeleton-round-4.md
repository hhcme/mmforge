# Phase 1 Goal 3 Round 4: OCCT FFI Build Gating — Strict Link-Directive Isolation

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Ensure `locate_occt` never emits any `rustc-link-search`/`rustc-link-lib`; all link directives deferred until shim passes boundary validation

---

## Problem

Round 3 gated `occt_found` on shim presence, but `locate_occt()` still
emitted `rustc-link-search=native={OCCT_LIB_DIR}` and
`rustc-link-lib={lib}` **before** the shim was verified.  This caused:

- Linker warnings/errors on machines where OCCT is installed but the
  shim is not yet built — OCCT libs were linked without the shim
  bridge, producing undefined-symbol failures.
- Confusing build output: link directives appeared even when the build
  ultimately fell back to stubs.

---

## Solution

### 1. `locate_occt()` → returns `Option<OcctInfo>`, emits nothing

Introduced `OcctInfo` struct:

```rust
struct OcctInfo {
    inc_dir: std::path::PathBuf,
    lib_dir: std::path::PathBuf,
    libs: Vec<String>,
}
```

`locate_occt()` and `try_pkg_config()` both return `Option<OcctInfo>`.
**No `cargo:rustc-link-*` or `cargo:include` directives are emitted**
at this stage — only data is collected.

### 2. `detect_occt()` emits everything only after shim verification

All link directives are emitted in a single block at the end of
`detect_occt()`, after:

1. `locate_occt()` succeeds → `OcctInfo` available
2. `MMFORGE_SHIM_DIR` is set and `libmmforge_occt_shim.a` exists
3. Boundary validation passes (see below)

Only then:

```
cargo:include={OCCT_INCLUDE_DIR}
cargo:rustc-link-search=native={OCCT_LIB_DIR}
cargo:rustc-link-lib={each OCCT lib}
cargo:rustc-link-search=native={MMFORGE_SHIM_DIR}
cargo:rustc-link-lib=static=mmforge_occt_shim
cargo:rustc-cfg=occt_found
```

### 3. Boundary validation

Two new checks before emitting any link directives:

| Check | What | Failure action |
|-------|------|----------------|
| Shim file metadata | `libmmforge_occt_shim.a` must exist and be >0 bytes | Warning + stubs |
| OCCT lib dir non-empty | `OCCT_LIB_DIR` must contain at least one file | Warning + stubs |

The shim check uses `std::fs::metadata()` to verify readability and
non-zero size.  An empty `.a` file (e.g. from a failed build) is
rejected.

### 4. `occt_not_available()` gated on `#[cfg(not(occt_found))]`

The helper function in `adapter.rs` is now explicitly gated to avoid
dead-code warnings when the real FFI path is active.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/build.rs` | `locate_occt`/`try_pkg_config` return `Option<OcctInfo>` (no link output); all link directives deferred to post-shim-verification; boundary validation for shim size and OCCT lib dir |
| `crates/mmforge-geometry/src/occt/adapter.rs` | `occt_not_available()` gated with `#[cfg(not(occt_found))]` |

---

## Architecture: occt_found Decision Tree (Updated)

```
feature = "occt" enabled?
├── No → stubs only (adapter module not compiled)
└── Yes → locate_occt()  [collects data, emits NOTHING]
         ├── OCCT not found → warning, stubs only
         └── OCCT found (OcctInfo) → check MMFORGE_SHIM_DIR
              ├── Not set → warning, stubs only
              ├── Set but libmmforge_occt_shim.a missing → warning, stubs only
              ├── Set but shim is 0 bytes → warning, stubs only
              ├── Set but OCCT lib dir is empty → warning, stubs only
              └── All checks pass →
                   emit ALL link directives (OCCT + shim)
                   set occt_found
                   real FFI enabled
```

**Key invariant: zero `rustc-link-*` output before shim verification.**

---

## Build Output Verification

`cargo build --features occt -v` (no OCCT env vars set) shows:

```
rustc mmforge_geometry ... --check-cfg 'cfg(occt_found)'
```

- No `rustc-link-search`
- No `rustc-link-lib`
- No `--cfg 'occt_found'`
- Only `--check-cfg` declaration

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `OCCT_INCLUDE_DIR` | Both | OCCT header directory |
| `OCCT_LIB_DIR` | Both | OCCT library directory |
| `OCCT_LIBS` | Optional | Semicolon-separated list of OCCT libs (default: 21 STEP-minimum) |
| `MMFORGE_SHIM_DIR` | For real FFI | Directory containing `libmmforge_occt_shim.a` |
