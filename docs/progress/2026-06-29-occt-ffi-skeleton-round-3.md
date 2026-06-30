# Phase 1 Goal 3 Round 3: OCCT FFI Gating — Shim-Verified occt_found

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Only set `occt_found` when shim library is verified linkable, not merely when OCCT dirs exist

---

## Summary

The `occt_found` cfg is now gated on the actual shim library being linkable, not just OCCT directories existing:

1. **`build.rs` restructured into two phases**:
   - **Phase 1**: Locate OCCT dirs (env vars or pkg-config). This only emits link search paths and OCCT library flags.
   - **Phase 2**: Verify `MMFORGE_SHIM_DIR` contains `libmmforge_occt_shim.a`. Only then set `occt_found` and link the shim.

2. **`MMFORGE_SHIM_DIR` env var**: New required env var for real FFI. Points to the directory containing the pre-built `libmmforge_occt_shim.a`. Without it, `occt_found` is never set — even if OCCT dirs are found.

3. **Stub path always works**: When `occt_found` is not set (which is always the case until the shim is built), all adapter functions return `OcctError::NotAvailable`. No undefined symbols.

4. **`stub_new_returns_not_available` test**: Gated on `#[cfg(not(occt_found))]` — only runs in stub mode.

5. **Dead code handled**: `#[allow(dead_code)]` on struct fields that are only read in the `occt_found` impl path.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/build.rs` | Two-phase detection: locate OCCT dirs → verify shim; `MMFORGE_SHIM_DIR` required for `occt_found` |
| `crates/mmforge-geometry/src/occt/adapter.rs` | Updated `occt_not_available` message; `stub_new_returns_not_available` gated on `#[cfg(not(occt_found))]` |

---

## Architecture: occt_found Decision Tree

```
feature = "occt" enabled?
├── No → stubs only (adapter module not compiled)
└── Yes → locate_occt()
         ├── OCCT not found → warning, stubs only
         └── OCCT found → check MMFORGE_SHIM_DIR
              ├── Not set → warning, stubs only
              ├── Set but libmmforge_occt_shim.a missing → warning, stubs only
              └── Set and shim present →
                   link shim + OCCT libs
                   set occt_found
                   real FFI enabled
```

Key: **finding OCCT ≠ usable FFI**. The shim bridge is the missing piece.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

`occt_found` is NOT set in any configuration (verified via `-v` output: only in `--check-cfg`, not in `--cfg`).

---

## Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `OCCT_INCLUDE_DIR` | Both | OCCT header directory |
| `OCCT_LIB_DIR` | Both | OCCT library directory |
| `OCCT_LIBS` | Optional | Semicolon-separated list of OCCT libs (default: 21 STEP-minimum) |
| `MMFORGE_SHIM_DIR` | For real FFI | Directory containing `libmmforge_occt_shim.a` |

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None.
