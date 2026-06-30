# Phase 1 Goal 3: OCCT FFI Skeleton & Build Detection

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Real OCCT FFI skeleton with sys/adapter boundary, build.rs detection, C ABI design
Gate: ⛔ ARCHITECTURE GATE — OCCT FFI — awaiting Codex review

---

## Summary

The OCCT FFI skeleton is implemented with a clean `sys`/`adapter` boundary:

1. **`occt/sys.rs`** — Raw `unsafe extern "C"` declarations for the C shim library. Defines opaque handle types (`StepControlReader`, `TopoDsShape`, `ShapeIterator`), status codes (`OcctStatus`), bounding box struct (`OcctBBox`), shape type enum (`OcctShapeType`). All `extern` blocks are `#[cfg(feature = "occt")]` — dead code without OCCT.

2. **`occt/adapter.rs`** — Safe Rust wrappers over `sys`. `StepReaderAdapter` owns the C++ reader pointer and frees it on `Drop`. `ShapeHandle<'a>` is a borrowed handle with lifetime tied to the reader. All `OcctStatus` codes are mapped to `OcctError` via `status_to_result()`. Not `Send`/`Sync` via `PhantomData<*const ()>`.

3. **`build.rs`** — OCCT detection with 2 strategies:
   - `OCCT_INCLUDE_DIR` + `OCCT_LIB_DIR` env vars (primary)
   - `pkg-config` fallback (`OpenCASCADE` package)
   - If neither works, prints a `cargo:warning` and continues with stubs (build never fails).

4. **`Cargo.toml`** — Added `pkg-config = "0.3"` build dependency.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-geometry/Cargo.toml` | Added `[build-dependencies] pkg-config = "0.3"` |
| `crates/mmforge-geometry/build.rs` | **New** — OCCT detection (env vars → pkg-config → warning fallback) |
| `crates/mmforge-geometry/src/occt/mod.rs` | Added `pub mod sys`, `#[cfg(feature = "occt")] pub mod adapter` |
| `crates/mmforge-geometry/src/occt/sys.rs` | **New** — C ABI declarations (opaque handles, status codes, extern functions) |
| `crates/mmforge-geometry/src/occt/adapter.rs` | **New** — Safe wrappers (StepReaderAdapter, ShapeHandle, status_to_result) |

---

## Architecture Decisions

### sys/adapter boundary

```
┌─────────────────────────────────┐
│  mmforge-format-step            │
│    parser.rs → occt_parse()     │
│         │                       │
│         ▼                       │
│  mmforge-geometry::occt         │
│    adapter.rs (safe Rust)       │
│         │                       │
│         ▼                       │
│    sys.rs (unsafe extern "C")   │
│         │                       │
│         ▼                       │
│    C shim library               │
│    (mmforge_occt_shim.c)        │
│         │                       │
│         ▼                       │
│    OCCT C++ library             │
└─────────────────────────────────┘
```

- **`sys`**: Only `unsafe extern "C"` blocks and `#[repr(C)]` types. No logic.
- **`adapter`**: Only module that calls `unsafe` sys functions. Converts to safe Rust types.
- **Format-step crate**: Never touches sys directly. Only calls adapter.

### C ABI design

| Function | Purpose |
|----------|---------|
| `mmforge_step_reader_new()` | Allocate reader → `*mut StepControlReader` |
| `mmforge_step_reader_read_file(reader, path)` | Read STEP file → `OcctStatus` |
| `mmforge_step_reader_transfer_roots(reader)` | Transfer shapes → `OcctStatus` |
| `mmforge_step_reader_root_count(reader)` | Count roots → `c_int` |
| `mmforge_step_reader_get_root(reader, i)` | Borrow root shape → `*const TopoDsShape` |
| `mmforge_step_reader_warning_count(reader)` | Count warnings → `c_int` |
| `mmforge_step_reader_get_warning(reader, i)` | Borrow warning string → `*const c_char` |
| `mmforge_step_reader_free(reader)` | Free reader (null-safe) |
| `mmforge_shape_type(shape)` | Shape type → `OcctShapeType` |
| `mmforge_shape_bbox(shape, out)` | Compute AABB → `OcctStatus` |
| `mmforge_shape_label(shape)` | Product label → `*const c_char` |
| `mmforge_shape_free(shape)` | Free copied shape (null-safe) |
| `mmforge_occt_version()` | Version string → `*const c_char` |

### Resource ownership

- Reader owns all shapes. Shapes are **borrowed**, not copied.
- `StepReaderAdapter::drop()` calls `mmforge_step_reader_free()`.
- `ShapeHandle<'a>` lifetime tied to `StepReaderAdapter` via `PhantomData`.
- `mmforge_shape_free` is for future use (explicit copies only).

### Error mapping

| OcctStatus | OcctError |
|------------|-----------|
| `Ok` | `Ok(())` |
| `IoError` | `Io(Error::other("OCCT I/O error"))` |
| `ParseError` | `StepError("STEP parse error")` |
| `TransferError` | `StepError("STEP transfer error")` |
| `NullArgument` | `ShapeError("null pointer argument")` |
| `InternalError` | `ShapeError("OCCT internal error")` |

### Build detection

```
build.rs (occt feature enabled):
  1. Check OCCT_INCLUDE_DIR + OCCT_LIB_DIR env vars
     → emit link search + cargo:rustc-cfg=occt_found
  2. Fallback: pkg-config probe("OpenCASCADE") >= 7.5
     → emit cfg=occt_found
  3. Neither: cargo:warning, no link flags
     → crate compiles with stubs, adapter functions are dead code
```

---

## Key Design Points

1. **`unsafe extern "C"`** — Required by Rust 2024 edition. All extern blocks are `#[cfg(feature = "occt")]`.

2. **`PhantomData<*const ()>` instead of `!Send`/`!Sync`** — Negative impls require nightly. The phantom pointer makes the type `!Send + !Sync` on stable.

3. **Build never fails** — If OCCT is not found, the build prints a warning but succeeds. Runtime calls to `read_step_file()` return `OcctError::NotAvailable`.

4. **`occt_found` cfg** — Set by build.rs when OCCT is actually found. Could be used in future for finer-grained conditional compilation (e.g. XDE support detection).

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 76 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo check --workspace` | ✅ Passes |
| `cargo check --workspace --features occt` | ✅ Passes (with OCCT-not-found warning) |

---

## ⛔ Architecture Gate — Pending Codex Review

| File | What to review |
|------|---------------|
| `crates/mmforge-geometry/src/occt/sys.rs` | C ABI types, extern function signatures |
| `crates/mmforge-geometry/src/occt/adapter.rs` | Safe wrapper design, Drop impl, lifetime management |
| `crates/mmforge-geometry/build.rs` | Detection strategy, env var names, fallback behavior |

### Review questions:

1. Is `OcctStatus` the right error representation, or should we use a richer error struct with message pointers?
2. Is `PhantomData<*const ()>` the idiomatic way to make a type `!Send + !Sync` on stable?
3. Should `mmforge_shape_free` exist if shapes are always borrowed from the reader?
4. Is the `OCCT_LIBS` semicolon-separated list approach appropriate, or should we use individual env vars per library?
5. Should build.rs set `cargo:rustc-cfg=occt_found` even when OCCT is not found (to allow `cfg(occt_found)` guards)?
6. Is the C shim naming convention (`mmforge_step_reader_*`, `mmforge_shape_*`) clear enough?

---

## Next Target (after gate passes)

**Phase 1 Goal 3 continuation**: Implement the C shim library (`mmforge_occt_shim.c`) that bridges these C function declarations to actual OCCT C++ calls. This requires OCCT to be installed.

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

| Dependency | Version | License | Used by |
|------------|---------|---------|---------|
| `pkg-config` | 0.3 | MIT OR Apache-2.0 | mmforge-geometry (build) |

MIT/Apache-2.0 — compatible with project dual license.
