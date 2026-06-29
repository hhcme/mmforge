# Phase 1 Goal 2: OCCT Integration & STEP Parser Shell

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: STEP parser shell, OCCT module boundary, feature-gated integration
Gate: ⛔ ARCHITECTURE GATE — OCCT wrapper — awaiting Codex review

---

## Summary

The STEP parser crate and OCCT module boundary are implemented:

1. **`mmforge-format-step`** — new crate implementing `FormatParser` for STEP files.
   - `detect.rs` — format detection via `ISO-10303-21;` magic header (Strong/Medium/Low confidence).
   - `parser.rs` — `StepParser` implementing `FormatParser` trait. Without `occt` feature, `parse()` returns a clear error. With `occt`, delegates to OCCT via `mmforge-geometry::occt`.
   - 12 unit tests (detection, extension matching, error paths).

2. **`mmforge-geometry::occt`** — new module with safe wrapper design.
   - `mod.rs` — `OcctError` enum, module-level docs on safety contract.
   - `shape.rs` — `OcctShapeHandle` (label, bounds, shape_type) and `ShapeType` enum.
   - `step_reader.rs` — `StepData`, `read_step_file()`, `extract_shapes()`. Without OCCT feature, returns `OcctError::NotAvailable`.
   - 2 unit tests.

3. **Feature gate** — `occt` feature in both `mmforge-geometry` and `mmforge-format-step`. CI runs without OCCT. No C++ dependency in the default build.

4. **75 tests total** (55 core + 12 format-step + 3 geometry + 5 render). All pass, clippy clean, fmt clean.

---

## Modified Files

| File | Change |
|------|--------|
| `Cargo.toml` | Added `mmforge-format-step` to workspace members and dependencies |
| `crates/mmforge-format-step/Cargo.toml` | **New** — STEP parser crate manifest with `occt` feature |
| `crates/mmforge-format-step/src/lib.rs` | **New** — crate root |
| `crates/mmforge-format-step/src/detect.rs` | **New** — STEP format detection (magic header + extension) |
| `crates/mmforge-format-step/src/parser.rs` | **New** — `StepParser` implementing `FormatParser` |
| `crates/mmforge-format-step/README.md` | **New** — crate documentation |
| `crates/mmforge-geometry/Cargo.toml` | Added `occt` feature flag |
| `crates/mmforge-geometry/src/lib.rs` | Added `pub mod occt` |
| `crates/mmforge-geometry/src/occt/mod.rs` | **New** — OCCT module root, `OcctError` type |
| `crates/mmforge-geometry/src/occt/shape.rs` | **New** — `OcctShapeHandle`, `ShapeType` |
| `crates/mmforge-geometry/src/occt/step_reader.rs` | **New** — `StepData`, `read_step_file`, `extract_shapes` |

---

## Architecture Decisions

1. **Feature-gated OCCT**: Both `mmforge-geometry` and `mmforge-format-step` have an `occt` feature (off by default). Without it, all OCCT functions return `OcctError::NotAvailable`. This lets CI and contributors build/test without installing OCCT.

2. **`StepParser` delegates to `mmforge-geometry::occt`**: The format-step crate never touches FFI directly. It calls `step_reader::read_step_file()` which is the single entry point to OCCT. This keeps `unsafe` in one place.

3. **`OcctShapeHandle` is metadata-only**: The raw C++ pointer is not exposed. The handle carries `label`, `bounds`, and `shape_type`. The actual B-Rep pointer will be stored internally when the FFI is implemented.

4. **STEP detection uses magic header, not extension**: `ISO-10303-21;` at byte 0 = High confidence. Extension + partial magic = Medium. Extension only = Low. This matches the development plan §4.1 algorithm.

5. **`occt_parse` placeholder**: The `#[cfg(feature = "occt")]` path in `parser.rs` currently returns `NotAvailable` — this is where the real `STEPControl_Reader` FFI calls will go in the next goal.

6. **`StepData` is the handoff type**: `read_step_file()` returns `StepData` containing `Vec<OcctShapeHandle>` and transfer messages. `extract_shapes()` returns a slice of shape handles. This is the clean boundary between OCCT and the parser.

---

## Key Algorithms

### STEP format detection

```text
1. Read first 4 KB.
2. If starts_with("ISO-10303-21;") → High confidence.
3. If extension is stp/step/p21 AND header contains "ISO-10303" → Medium.
4. If extension is stp/step/p21 only → Low.
5. Otherwise → None (not STEP).
```

### parse() flow

```text
1. Read 4 KB header.
2. Verify ISO-10303 presence → Err if missing.
3. If occt feature: delegate to occt_parse(path).
4. If not occt: Err("OCCT feature not enabled").
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo fmt` | ✅ Applied |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |

---

## ⛔ Architecture Gate — Pending Codex Review

| File | What to review |
|------|---------------|
| `crates/mmforge-format-step/src/parser.rs` | `FormatParser` impl, occt feature gating |
| `crates/mmforge-format-step/src/detect.rs` | Detection algorithm correctness |
| `crates/mmforge-geometry/src/occt/mod.rs` | Module boundary, `OcctError` |
| `crates/mmforge-geometry/src/occt/shape.rs` | `OcctShapeHandle` design |
| `crates/mmforge-geometry/src/occt/step_reader.rs` | `StepData`, `read_step_file`, `extract_shapes` API |

### Review questions:

1. Is `OcctShapeHandle` the right level of abstraction? Should it hold a raw pointer internally (for when OCCT is enabled) or is metadata-only sufficient for now?
2. Is `StepData` the right handoff type between OCCT and the parser, or should `read_step_file` return the model directly?
3. Should `extract_shapes` take `&StepData` or `StepData` (consuming)?
4. Is the detection algorithm's 3-tier confidence (High/Medium/Low) appropriate?
5. Is the feature gate naming (`occt`) clear enough, or should it be `opencascade` or `occt-ffi`?
6. Should the `occt_parse` function in `parser.rs` be in the format-step crate or should it live entirely in `mmforge-geometry::occt`?

---

## Next Target (after gate passes)

**Phase 1 Goal 2 continuation**: Implement the real OCCT FFI — `STEPControl_Reader` C bindings, `TopoDS_Shape` pointer management, shape tree traversal, bounding box computation. This requires OCCT to be installed.

---

## Sample Files / testfile Usage

None. STEP test fixtures will be added when OCCT FFI is implemented.

---

## Fix Record (Round 2)

Date: 2026-06-29

### Issues fixed

1. **`cargo check --workspace --features occt` now passes**: Added proper `use LsmModel` import in `occt_parse`, explicit `map_err` for `OcctError → Error`, and `extract_shapes` error handling.

2. **`occt_parse` imports `LsmModel` explicitly**: `use mmforge_core::model::LsmModel` inside the `#[cfg(feature = "occt")]` function.

3. **`OcctError` mapped explicitly to `Error`**: No reliance on `From<OcctError>`. Uses `.map_err(|e| Error::parse("STEP", format!("OCCT read failed: {e}")))` for both `read_step_file` and `extract_shapes`.

4. **Scene tree root assembly node**: All shapes now hang under a `STEP_Assembly` root node (NodeId 0). Shape nodes get `parent: Some(root_id)`. Root bounds are computed from children. This prevents orphan nodes in `validate_references()`.

### Verification

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo check --workspace --features occt` | ✅ Passes |
| `cargo check -p mmforge-format-step --features occt` | ✅ Passes |

### Modified files (round 2)

| File | Change |
|------|--------|
| `crates/mmforge-format-step/src/parser.rs` | Fixed `occt_parse`: explicit LsmModel import, OcctError→Error mapping, root assembly node, root bounds computation |
| `docs/progress/2026-06-29-step-parser-occt-shell.md` | This fix record |

---

## Fix Record (Round 3)

Date: 2026-06-29

### Issue fixed

`read_step_file_without_occt_errors` test was unconditionally compiled — it only makes sense without the `occt` feature.

### Changes

1. **`#[cfg(not(feature = "occt"))]`** added to `read_step_file_without_occt_errors`.
2. **`#[cfg(feature = "occt")]` test added**: `read_step_file_occt_placeholder_returns_not_available` — asserts the placeholder returns `OcctError::NotAvailable` with message containing `"OCCT FFI not yet implemented"` or `"STEPControl_Reader"`.

### Verification

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 74 tests pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

### Modified files (round 3)

| File | Change |
|------|--------|
| `crates/mmforge-geometry/src/occt/step_reader.rs` | Added `cfg` gates to tests, added occt placeholder test |
| `docs/progress/2026-06-29-step-parser-occt-shell.md` | This fix record |

---

## New Dependencies And Licenses

| Dependency | Version | License | Used by |
|------------|---------|---------|---------|
| (no new deps — reuses workspace deps) | | | |

No new external dependencies. `mmforge-format-step` uses only `mmforge-core`, `mmforge-geometry`, `thiserror`, and `glam` from the workspace.
