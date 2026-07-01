# BVH Input Validation — Robust buildMeshBVH

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Add input validation to buildMeshBVH; edge case tests;
        fix standalone test

---

## Changes

### 1. `buildMeshBVH` input validation (Picking.swift)

Added guards before BVH construction:

- `positions.count % 3 == 0` — positions must be xyz triples
- `indices.count % 3 == 0` — indices must be triangle triples
- Each index `< positions.count / 3` — skip triangles with OOB indices
- Empty `triInfos` after filtering → return empty `MeshBVH`

Invalid triangles are silently skipped, not crashed on.

### 2. Xcode test edge cases (PickingTests.swift)

Added 4 new tests via `@testable import MMForge`:

| Test | Coverage |
|------|----------|
| `testOutOfBoundsIndices` | Index 99 with 3 vertices → empty BVH |
| `testIndicesNotMultipleOfThree` | 2 indices → empty BVH |
| `testPositionsNotMultipleOfThree` | 5 floats → empty BVH |
| `testMixedValidAndInvalidTriangles` | Valid [0,1,2] + invalid [99,100,101] → 1 triangle |

Total: 9 Xcode tests, all pass.

### 3. Standalone test cleanup (BVHPickingTests.swift)

- Fixed `var` → `let` warning
- Removed edge-case tests (now in Xcode target only)
- Added note that Xcode test is authoritative
- 12 standalone tests, all pass

### 4. `rayAABB` NaN fix (Picking.swift)

Per-axis slab test with explicit NaN handling for boundary-parallel
rays.  Prevents `0 * infinity = NaN` from causing false negatives.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild test-without-building` | ✅ 9/9 pass |
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Metal/Picking.swift` | `buildMeshBVH` input validation; `rayAABB` NaN fix |
| `macos/MMForgeTests/PickingTests.swift` | 4 edge case tests for input validation |
| `macos/MMForgeTests/BVHPickingTests.swift` | Removed edge cases, fixed var warning, added note |
