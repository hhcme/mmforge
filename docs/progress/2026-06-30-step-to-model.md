# STEP → Model Conversion — E2E Verified

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Wire STEP parsing to LsmModel with BRepHandleRef geometry,
        preserve label/shape_type/bounds/transfer messages

---

## Summary

`occt_parse()` in `mmforge-format-step/src/parser.rs` converts
`StepData.shapes` into `LsmModel` with `BRepHandleRef` geometry.
Transfer messages are preserved as `ParseWarning::PrecisionLoss`.
Shape type is embedded in the node label (e.g. "PQ-04909-A [Solid]").

E2E verified with real OCCT 7.9.3 against the 37KB STEP fixture.

---

## Model Structure

```
LsmModel
├── header: { source_format: "STEP", source_path: "..." }
├── scene: SceneTree
│   └── root: NodeId(0) "STEP_Assembly"
│       bounds: union of all children
│       └── NodeId(1) "PQ-04909-A [Solid]"
│           geometry: GeometryId(0)
│           bounds: BoundingBox { min, max }
├── geometries: [
│     BRepHandleRef { id: GeometryId(0), bounds, label: "PQ-04909-A [Solid]" }
│   ]
├── materials: []
└── metadata: {}
```

---

## Changes

### `mmforge-format-step/src/parser.rs` — `occt_parse()` updated

**Transfer messages** → `ParseWarning::PrecisionLoss`:
```rust
let mut warnings: Vec<ParseWarning> = step_data
    .transfer_messages
    .iter()
    .map(|msg| ParseWarning::PrecisionLoss {
        message: format!("OCCT: {msg}"),
    })
    .collect();
```

**Shape type in label**:
```rust
let display_label = format!("{} [{:?}]", shape.label, shape.shape_type);
// e.g. "PQ-04909-A [Solid]"
```

**Fallback label warning**:
```rust
if shape.label.starts_with("Shape_") {
    warnings.push(ParseWarning::PrecisionLoss {
        message: format!("shape {i} has no STEP product name, using fallback"),
    });
}
```

### `mmforge-format-step/build.rs` — new

Declares `occt_found` as valid check-cfg and detects the shim library
(same logic as mmforge-geometry build.rs).  This is needed because
`cargo:rustc-cfg` flags don't propagate across crate boundaries.

### `mmforge-format-step/src/parser.rs` — e2e test added

`e2e_step_fixture_to_model` — gated on `#[cfg(occt_found)]`:

Assertions:
- Header: `source_format == "STEP"`, `source_path` set
- Root node: name "STEP_Assembly", valid bounds
- Children: at least one, each has geometry + valid bounds + `[ShapeType]` in label
- Geometries: all `BRepHandleRef` with valid bounds
- Stats: consistent node/geometry counts

---

## E2E Output (real OCCT 7.9.3)

```
E2E: 2 nodes, 1 geometries, 0 warnings
  node 'STEP_Assembly' bounds=BoundingBox {
    min: Vec3(-24.249462, -5.5880003, -24.249462),
    max: Vec3(24.249462, 3.937, 24.249462)
  }
  node 'PQ-04909-A [Solid]' bounds=BoundingBox {
    min: Vec3(-24.249462, -5.5880003, -24.249462),
    max: Vec3(24.249462, 3.937, 24.249462)
  }
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 75 tests pass |
| `cargo test --workspace --features occt` | ✅ 78 tests pass |
| `cargo test -p mmforge-format-step --features occt` (real OCCT) | ✅ 12 tests pass, e2e verified |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |

---

## Data Flow

```
PQ-04909-A.STEP
  └→ StepParser::parse(path)
       └→ occt_parse(path)
            └→ read_step_file(path) → StepData
            └→ extract_shapes(&step_data) → &[OcctShapeHandle]
            └→ LsmModel::empty("STEP")
            └→ add root "STEP_Assembly"
            └→ for each shape:
                 add child "label [ShapeType]"
                 add BRepHandleRef geometry
            └→ compute root bounds
            └→ transfer_messages → ParseWarning::PrecisionLoss
            └→ ParseOutput { model, warnings, stats }
```

---

## Risks

| Risk | Mitigation |
|------|-----------|
| `occt_found` not set in format-step | New build.rs detects shim |
| Shape type in label changes format | Use `{:?}` Debug — stable for enums |
| Large STEP files slow CI | Use 37KB fixture; larger files for manual testing |
| No transfer messages in fixture | Test asserts 0 warnings (fixture-specific) |
