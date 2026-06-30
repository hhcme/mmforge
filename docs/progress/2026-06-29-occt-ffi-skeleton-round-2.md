# Phase 1 Goal 3 Round 2: OCCT FFI Build Gating Fix

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Fix build gating — paired env vars validation, cfg(occt_found) extern gates, stub adapter paths, minimal libs

---

## Summary

Three build gating issues fixed:

1. **`build.rs` env var validation** — `OCCT_INCLUDE_DIR` and `OCCT_LIB_DIR` must both be set AND point to existing directories. Partial or invalid paths fall through to pkg-config, not to `occt_found`.

2. **`cfg(occt_found)` extern gates** — `sys.rs` extern blocks are now gated on `cfg(occt_found)` (set by build.rs only when OCCT is actually found), not `cfg(feature = "occt")`. This prevents linker errors when the feature is on but OCCT is not installed.

3. **Stub adapter path** — `adapter.rs` provides stub impls (`OcctError::NotAvailable`) when `occt_found` is not set. Real call paths are `#[cfg(occt_found)]`. No undefined symbols can be reached.

4. **Minimal OCCT_LIBS** — Narrowed from 40+ libraries to 21 STEP-minimum: `TKernel;TKMath;TKG3d;TKBRep;TKTopAlgo;TKGeomAlgo;TKGeomBase;TKShHealing;TKMesh;TKBO;TKBool;TKXSBase;TKSTEPBase;TKSTEP;TKSTEP209;TKSTEPAttr;TKXDESTEP;TKXCAF;TKCAF;TKCDF;TKService`.

5. **`cargo::rustc-check-cfg=cfg(occt_found)`** — Declared in build.rs so the compiler doesn't warn about unknown cfg.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/build.rs` | Require both env dirs valid; `rustc-check-cfg` declaration; narrowed lib list |
| `crates/mmforge-geometry/src/occt/sys.rs` | `cfg(feature = "occt")` → `cfg(occt_found)` on all extern blocks |
| `crates/mmforge-geometry/src/occt/adapter.rs` | Real impls gated on `cfg(occt_found)`, stub impls otherwise; conditional imports; `#[allow(dead_code)]` on struct fields |

---

## Architecture Decisions

1. **`cfg(occt_found)` vs `cfg(feature = "occt")`**: The feature flag controls whether the code *attempts* OCCT integration. The `occt_found` cfg controls whether OCCT was *actually found* at build time. Extern blocks and real call paths need `occt_found` to avoid linker errors.

2. **Stub impls always compile**: `StepReaderAdapter::new()` and friends always compile — they just return `NotAvailable` when `occt_found` is off. This keeps the API surface stable regardless of build environment.

3. **Env vars must be paired**: Setting only `OCCT_INCLUDE_DIR` without `OCCT_LIB_DIR` (or vice versa) is a configuration error. The build script warns and falls through to pkg-config rather than producing a broken build.

4. **Path existence check**: `is_dir()` verifies the paths actually exist on disk before emitting link flags. Stale or typo'd env vars produce a clear warning, not silent linker failures.

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

## Verification Matrix

| Configuration | Compile | Tests | Clippy | Link |
|---------------|---------|-------|--------|------|
| default (no occt feature) | ✅ | 75 | ✅ | N/A |
| `--features occt` (no OCCT installed) | ✅ | 77 | ✅ | N/A (no extern symbols) |
| `--features occt` + OCCT installed | would link | would pass | would pass | would succeed |

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None.
