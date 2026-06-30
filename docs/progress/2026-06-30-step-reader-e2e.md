# STEP Reader E2E — Real OCCT Integration

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Wire up `step_reader.rs` to real OCCT adapter, verify with
        real STEP fixture end-to-end

---

## Summary

`occt_read_step()` in `step_reader.rs` is no longer a placeholder.
It now calls `StepReaderAdapter` to read STEP files, transfer roots,
and extract shape metadata (bbox, label, type) via the real OCCT shim.

E2E test verified with **real OCCT 7.9.3** against a 37KB STEP fixture
(`testfile/PQ-04909-A.STEP`).

---

## What Changed

### `step_reader.rs` — `occt_read_step()` wired up

**Before**: placeholder returning `OcctError::NotAvailable`.

**After** (`#[cfg(occt_found)]`):

```rust
fn occt_read_step(path: &Path) -> Result<StepData, OcctError> {
    let mut reader = StepReaderAdapter::new()?;
    reader.read_file(path)?;
    reader.transfer_roots()?;

    let count = reader.root_count();
    let mut shapes = Vec::with_capacity(count);
    for i in 0..count {
        let handle = reader.get_root(i)?;
        let fallback = format!("Shape_{i}");
        shapes.push(handle.to_handle(&fallback)?);
    }

    Ok(StepData {
        shapes,
        transfer_messages: reader.warnings(),
    })
}
```

When `occt` feature is on but `occt_found` is not set (no shim), a
stub returns `NotAvailable`.

### E2E test — `read_step_file_e2e_real_occt`

Gated on `#[cfg(occt_found)]`.  Reads `testfile/PQ-04909-A.STEP`
(relative to workspace root via `CARGO_MANIFEST_DIR`).

Assertions:
- `read_step_file()` succeeds
- At least one root shape returned
- Every shape has a valid bounding box
- Soft check: at least one non-fallback label

---

## E2E Test Output (real OCCT 7.9.3)

```
E2E: read 1 shapes from STEP file, 0 transfer messages
  [0] type=Solid label='PQ-04909-A'
      bbox=BoundingBox {
        min: Vec3(-24.249462, -5.5880003, -24.249462),
        max: Vec3(24.249462, 3.937, 24.249462)
      }
```

- **Shape count**: 1 root shape
- **Shape type**: Solid
- **Label**: `PQ-04909-A` (from STEP product name via XDE)
- **BBox**: ~48.5 × 9.5 × 48.5 mm

---

## Data Flow

```
read_step_file(path)
  └→ occt_read_step(path)
       └→ StepReaderAdapter::new()
            └→ mmforge_abi_version() check
            └→ mmforge_step_reader_new()
       └→ reader.read_file(path)
            └→ mmforge_step_reader_read_file(r, path)
       └→ reader.transfer_roots()
            └→ mmforge_step_reader_transfer_roots(r)
               C++: caf.Transfer(doc)
               C++: collect warnings, roots, labels
       └→ for i in 0..root_count:
            reader.get_root(i)
              └→ mmforge_step_reader_get_root(r, i)
            handle.to_handle(fallback)
              └→ mmforge_shape_bbox(r, s) → BoundingBox
              └→ mmforge_shape_label(r, s) → String
              └→ mmforge_shape_type(r, s) → ShapeType
       └→ StepData { shapes, transfer_messages }
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 77 tests pass |
| `cargo test -p mmforge-geometry --features occt` (real OCCT) | ✅ 6 tests pass, e2e reads STEP file |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Test Fixture

| File | Size | Content |
|------|------|---------|
| `testfile/PQ-04909-A.STEP` | 37 KB | 1 solid body, product name "PQ-04909-A" |

Other fixtures available for future testing:
- `方盒子.step` (21 MB)
- `JY-LT-260401-OP10.stp` (39 MB)
- `赛车.step` (235 MB)

---

## Risks

| Risk | Mitigation |
|------|-----------|
| Fixture file missing in CI | Test prints SKIP and passes if file not found |
| STEP file has no product names | Soft check — eprintln NOTE, test still passes |
| Large STEP files slow CI | Use 37KB fixture; larger files for manual testing |
| Label extraction returns empty | Fallback label "Shape_{i}" from `to_handle()` |
