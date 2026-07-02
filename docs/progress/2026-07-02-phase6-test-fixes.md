# Phase 6 Round 3: Test Fixes

**Date**: 2026-07-02
**Scope**: Fix two blocking test failures: missing OCCT import and flaky progress assertion.

## Problems Fixed

### 1. OCCT test: `read_iges_file_with_tessellation` not found

**Bug**: The test `read_iges_with_tessellation_e2e_real_occt` in
`crates/mmforge-geometry/src/occt/iges_reader.rs` called
`read_iges_file_with_tessellation` without importing it. The test module only
had `use super::read_iges_file;` but missed the tessellation variant.

**Fix**: Added `#[cfg(occt_found)] use super::read_iges_file_with_tessellation;`
to the `mod tests` imports.

**File**: `crates/mmforge-geometry/src/occt/iges_reader.rs`

### 2. AsyncParseTests.testParseReportsProgress reads cleared `parseStage`

**Bug**: `testParseReportsProgress` subscribed to `vm.$parseStage` via Combine,
filtered for non-empty, and fulfilled an expectation on `.first()`. After
the wait, it asserted `XCTAssertFalse(vm.parseStage.isEmpty)` — but
`parseCompletionCallback` clears `parseStage` to `""` on success before
`state` transitions to `.loaded`. Depending on timing, the assertion could
fail because the property is already cleared.

**Fix**: Capture the non-empty stage string in the `sink` closure and assert
on the captured value instead of the (possibly cleared) `vm.parseStage`.

**File**: `macos/MMForgeTests/AsyncParseTests.swift`

## Verification

- `cargo fmt --all --check` — pass
- `cargo test --workspace --locked` — 218 tests pass
- `cargo clippy --workspace -- -D warnings` — 0 warnings
- `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` — 224 tests pass
  (incl. `read_iges_with_tessellation_e2e_real_occt`, `read_step_file_e2e_real_occt`,
  `tessellate_step_fixture`)
- `cargo bench -p mmforge-format-dxf --no-run` — compiles + links
- `xcodebuild -project macos/MMForge.xcodeproj ... test` — 83 tests pass
  (incl. `AsyncParseTests.testParseReportsProgress`)
