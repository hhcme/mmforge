# Phase 1 Goal 3 Round 5: OCCT FFI Shim Validation — Archive + Symbol Verification

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Verify shim archive format and required symbol exports before setting `occt_found`; add link-verification probe test

---

## Problem

Round 4 deferred all link directives until shim presence was confirmed,
but only checked that `libmmforge_occt_shim.a` existed and was non-zero
bytes.  A corrupt, truncated, or incomplete archive (e.g. from a failed
build) would pass this check and cause linker errors or runtime
undefined behavior.

---

## Solution

### 1. Archive validation (`validate_shim_archive`)

Three sequential checks, fail-fast:

| # | Check | Failure message |
|---|-------|-----------------|
| 1 | File readable, non-empty | "…is empty (0 bytes)" or "Cannot read…" |
| 2 | Ar magic `!<arch>\n` (first 8 bytes) | "…is not a valid ar archive (bad magic header)" |
| 3 | Required symbols present | "…is missing required symbols: {list}. Rebuild the shim library." |

### 2. Required symbol list

```rust
const REQUIRED_SHIM_SYMBOLS: &[&str] = &[
    "mmforge_step_reader_new",
    "mmforge_step_reader_free",
    "mmforge_occt_version",
];
```

These correspond to the `extern "C"` declarations in `sys.rs` that the
link probe test (below) also references.  If any are missing, the shim
is incomplete and `occt_found` is not set.

### 3. Symbol scanning strategy (`archive_has_symbols`)

1. Parse ar member headers (60-byte fixed format, starting at offset 8).
2. For each member, extract its body (size from header field 48..58).
3. Scan the body for each required symbol as a byte substring.
4. First match removes that symbol from the remaining set.
5. Early-exit when all symbols found.

The scan covers all member types: the `/` GNU symbol table (where
symbol names appear as plain strings), regular `.o` members (where
symbol references appear in relocation entries), and even the `//`
extended-name table (harmless — our symbol names are specific enough
for zero false-positive risk).

### 4. Link-verification probe test

New test in `adapter.rs`, gated on `#[cfg(occt_found)]`:

```rust
#[cfg(occt_found)]
#[test]
fn link_probe_references_real_shim_symbols() {
    let ptr = unsafe { super::super::sys::mmforge_occt_version() };
    assert!(!ptr.is_null());
    let version = unsafe { CStr::from_ptr(ptr) }.to_string_lossy();
    assert!(!version.is_empty());
}
```

This test **only compiles when `occt_found` is set** (which requires the
shim to pass archive validation).  It calls the real `extern "C"`
function `mmforge_occt_version()` through the shim.  If the shim was
not actually linked (impossible given our gating, but defense-in-depth),
the test would fail to **link** — a loud, unmissable build error.

**Why `mmforge_occt_version`?** It is cheap, read-only, and always
available (no OCCT session needed).  The important thing is that the
linker resolves the symbol.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/build.rs` | Replaced simple metadata check with `validate_shim_archive` (magic + symbol scan); added `archive_has_symbols` and `REQUIRED_SHIM_SYMBOLS` |
| `crates/mmforge-geometry/src/occt/adapter.rs` | Added `link_probe_references_real_shim_symbols` test gated on `#[cfg(occt_found)]` |

---

## Architecture: occt_found Decision Tree (Updated)

```
feature = "occt" enabled?
├── No → stubs only
└── Yes → locate_occt()  [collects data, emits NOTHING]
         ├── OCCT not found → warning, stubs
         └── OCCT found → check MMFORGE_SHIM_DIR
              ├── Not set → warning, stubs
              ├── Set but shim missing/unreadable → warning, stubs
              ├── Set but shim is 0 bytes → warning, stubs
              ├── Set but shim has bad ar magic → warning, stubs
              ├── Set but shim missing required symbols → warning, stubs
              ├── Set but OCCT lib dir empty → warning, stubs
              └── All checks pass →
                   emit ALL link directives (OCCT + shim)
                   set occt_found
                   real FFI enabled
```

**Key invariants:**

1. Zero `rustc-link-*` output before shim verification.
2. Shim must be a real ar archive exporting all 3 required symbols.
3. `occt_found` is the sole gate for `extern "C"` blocks in `sys.rs`
   and real implementations in `adapter.rs`.
4. Link-probe test catches any regression where `occt_found` is set
   but shim is not actually linked.

---

## Validation Layers Summary

| Layer | Where | What | When |
|-------|-------|------|------|
| Archive magic | build.rs | `!<arch>\n` header | Before link output |
| Symbol exports | build.rs | 3 required C symbols in archive body | Before link output |
| Link resolution | adapter.rs test | `mmforge_occt_version()` symbol resolves | Test time (`--features occt`) |

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

Build-script verbose output (`cargo build --features occt -v`) confirms:
- No `rustc-link-search`, `rustc-link-lib`, or `--cfg occt_found` in rustc invocation
- Only `--check-cfg 'cfg(occt_found)'` declaration
