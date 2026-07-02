# Phase 6 Round 2: Async Parse Lifecycle & Resource Management Fixes

**Date**: 2026-07-02
**Scope**: Fix lifecycle and resource management issues in the Phase 6 async parsing pipeline, and propagate cancellation through native parser loops.

## Problems Fixed

### 1. Progress callback stage string use-after-free (Swift)

**Bug**: `parseProgressCallback` read the `stage: UnsafePointer<CChar>?` inside the
`DispatchQueue.main.async` block.  The pointer is only valid for the duration of the C
callback — by the time the main-thread block executes, the backing `CString` on the Rust
side may have been dropped.

**Fix**: Copy the stage string (`String(cString:)`) and progress value immediately in the
callback thread, before dispatching to main.  The copied `String` is captured by the closure.

**File**: `macos/MMForge/Document/MMForgeDocument.swift` — `parseProgressCallback`

### 2. Completion callback reads thread-local error on wrong thread (Rust → Swift)

**Bug**: On parse failure, the completion callback set `doc = null` and the Swift side called
`mmf_last_error()` to get the error message.  But `mmf_last_error()` reads `LAST_ERROR`
which is thread-local to the Rust background thread.  The Swift callback dispatched to
`DispatchQueue.main.async`, where the thread-local was empty or stale.

**Fix**: Changed `CCompletionCallback` signature to include an `error: *const c_char`
parameter.  On failure, the Rust side formats the error into a `CString` and passes the
pointer to the callback.  The Swift side copies the string immediately (like the progress
callback) before dispatching to main.

**Files**:
- `crates/mmforge-bridge/src/job.rs` — `CCompletionCallback` type, `mmf_open_async_inner`
- `macos/MMForge/RustBridge/mmforge_bridge.h` — `mmf_completion_fn` typedef
- `macos/MMForge/Document/MMForgeDocument.swift` — `parseCompletionCallback`

### 3. Resource leak: currentJob / currentCancelToken not released on completion

**Bug**: `parseCompletionCallback` set `currentJob = nil` but never freed
`currentCancelToken`.  On deinit, only `rustDoc` was freed — `currentJob` and
`currentCancelToken` were leaked.

**Fix**:
- Completion callback now frees both `currentJob` and `currentCancelToken` after
  the generation check.
- `freeCurrentDocument()` frees job first (which cancels the token internally),
  then frees the token.
- `deinit` now frees `currentJob`, `currentCancelToken`, and `rustDoc`.

**Files**: `macos/MMForge/Document/MMForgeDocument.swift`

### 4. mmf_open_job_free blocks main thread (Rust)

**Bug**: `mmf_open_job_free` called `handle.join()` which blocks until the background
thread finishes.  If called from the main thread (via `freeCurrentDocument`), this could
freeze the UI for the duration of a large-file parse.

**Fix**: Changed `mmf_open_job_free` to `drop(job.handle.take())` instead of `join()`.
Dropping a `JoinHandle` detaches the thread — it continues running in the background.
The completion callback handles its own cleanup via the generation counter and weak
`viewModel` reference.

**File**: `crates/mmforge-bridge/src/job.rs` — `mmf_open_job_free`

### 5. Missing cancellation check before build_document (Rust)

**Bug**: `parse_with_detection` checked cancellation at entry but not before the expensive
`build_document` step.  A user cancelling during parse would still wait for the full build.

**Fix**: Added `cancel.is_cancelled()` check before `build_document` in
`parse_with_detection`.

**File**: `crates/mmforge-bridge/src/lib.rs` — `parse_with_detection`

### 6. Cancellation token not propagated into native parser loops (Rust)

**Bug**: Native parsers (DXF, STL, glTF) did not check the cancellation token during
long-running loops.  A user cancelling mid-parse would still complete the full loop.

**Fix**: Added `parse_*_with_progress(path, progress, cancel)` variants for DXF, STL,
glTF, STEP, and IGES.  Each parser reports stage progress and checks cancellation at
boundaries and inside loops:

- **DXF**: checks between read, tokenize, sections, tables, blocks, entities, and build.
- **STL**: checks every 1024 triangles/lines in binary/ASCII parsing.
- **glTF**: checks every 1024 vertices during primitive extraction and recurses through
  nodes with cancellation.
- **STEP/IGES**: checks before the OCCT read and between shape creation; OCCT itself
  does not support mid-operation cancellation, so this is boundary-only for now.

**Helper functions** added:

```rust
fn report_progress(progress: Option<&ProgressCallback>, stage: &'static str, current: u32, total: u32)
fn check_cancel(cancel: Option<&CancellationToken>) -> Result<()>
```

**Files**:
- `crates/mmforge-format-dxf/src/parser.rs`
- `crates/mmforge-bridge/src/stl_parser.rs`
- `crates/mmforge-bridge/src/gltf_parser.rs`
- `crates/mmforge-format-step/src/parser.rs`
- `crates/mmforge-format-iges/src/parser.rs`
- `crates/mmforge-bridge/src/lib.rs` — calls `_with_progress` variants

### 7. OCCT IGES adapter failed to compile with `--features occt` but no shim (Rust)

**Bug**: `crates/mmforge-geometry/src/occt/iges_reader.rs` gated the real OCCT-backed
`occt_read_iges` and `occt_read_iges_with_tessellation` functions with
`#[cfg(feature = "occt")]`.  When the `occt` feature was enabled but the OCCT shim was
not found (`occt_found` not set), those functions still compiled and called methods
(`to_handle`) and types (`TessellatedMesh`) that only exist when `occt_found` is set,
producing compiler errors.

**Fix**: Changed the real implementations to `#[cfg(occt_found)]` and added stub
implementations under `#[cfg(all(feature = "occt", not(occt_found)))]` that return
`OcctError::NotAvailable`.  Also gated `OCCT_TEST_MUTEX` with
`#[cfg(all(test, occt_found))]` to avoid a dead-code warning when OCCT is not linked.

**Files**:
- `crates/mmforge-geometry/src/occt/iges_reader.rs`
- `crates/mmforge-geometry/src/occt/mod.rs`

### 8. Benchmark unused import warning

**Bug**: `dxf_bench.rs` imported `mmforge_core::drawing::Drawing2DGeometry` which was
unused (the type is inferred, not explicitly annotated).

**Fix**: Removed the unused import.

**File**: `crates/mmforge-format-dxf/benches/dxf_bench.rs`

### 9. Dead code warnings in STEP/IGES parsers

**Bug**: `occt_parse` helper functions in `mmforge-format-step/src/parser.rs` and
`mmforge-format-iges/src/parser.rs` were unused; only `occt_parse_with_progress` was
called.

**Fix**: Removed the unused `occt_parse` functions.

**Files**:
- `crates/mmforge-format-step/src/parser.rs`
- `crates/mmforge-format-iges/src/parser.rs`

## New Tests

### Rust (`crates/mmforge-bridge/src/job.rs`)

| Test | Coverage |
|------|----------|
| `cancel_token_new_and_cancel` | Token lifecycle |
| `cancel_token_clone_shares_state` | Clone semantics |
| `open_async_null_path_returns_null` | Null input validation |
| `open_async_invalid_utf8_returns_null` | Invalid path validation |
| `open_async_nonexistent_file_returns_error_via_callback` | Error propagation via completion callback |
| `open_async_cancel_before_parse` | Pre-cancelled token → Cancelled error |
| `open_async_progress_callback_fires` | Progress callback invocation |
| `job_free_is_non_blocking` | `mmf_open_job_free` returns promptly |

### Rust native parser cancellation

| Test | Coverage |
|------|----------|
| `parse_stl_cancellation_returns_error` | STL binary/ASCII loop checks |
| `parse_gltf_cancellation_returns_error` | glTF node/primitive loop checks |

### Swift (`macos/MMForgeTests/AsyncParseTests.swift`)

| Test | Coverage |
|------|----------|
| `testParseValidSTL_succeeds` | Success path: valid STL → .loaded |
| `testParseInvalidData_setsErrorState` | Failure path: garbage → .error |
| `testParseCancel_releasesResources` | Cancel: second parse cancels first |
| `testDuplicateOpen_cancelsFirstAndSucceeds` | Duplicate open: resource release |
| `testParseEmptyData_setsEmptyState` | Empty data → .empty, no job created |
| `testParseReportsProgress` | Progress callback updates parseStage |

## Architecture (Updated)

```
Swift UI
  │  parseFile(data, ext)
  ▼
DocumentViewModel
  │  mmf_cancel_token_new()
  │  mmf_open_async(path, token, progress_cb, completion_cb, ctx)
  ▼
OpenDocumentJob (Rust, background thread)
  │  cancel check → detect → parse_with_progress → cancel check → build
  │  progress_cb("parsing", current, total) — stage CString copied per call
  │  completion_cb(doc, error, user_data) — error CString passed on failure
  ▼
ParseCallbackContext (Swift, via Unmanaged)
  │  Copy stage/error strings immediately in callback thread
  │  DispatchQueue.main.async → update viewModel state
  │  Release currentJob + currentCancelToken on completion
  ▼
DocumentViewModel
  │  rustDoc = doc; buildDTO; uploadToRenderer
  ▼
Metal Renderer

mmf_open_job_free:
  │  cancel token
  │  drop(JoinHandle) → detach thread (non-blocking)
  │  completion callback fires later, generation check discards stale results

Native parsers (DXF/STL/glTF):
  check_cancel inside loops → cooperative cancellation

OCCT parsers (STEP/IGES):
  check_cancel at boundaries only → OCCT monolithic calls are not interruptible
```

## Test Results

- **cargo fmt --all --check**: passed
- **cargo test --workspace --locked**: 216 tests pass (44 bridge + 71 core + 39 dxf + 6 geometry + 12 render + 5 step + 39 iges)
- **cargo clippy --workspace -- -D warnings**: clean (0 warnings)
- **cargo bench -p mmforge-format-dxf --no-run**: compiles successfully
- **cargo test --workspace --features occt --locked**: passes.  OCCT is not installed on this machine, so the build script emits a warning and the stub paths are exercised; no real OCCT E2E tests run.
- **xcodebuild test**: 83 tests pass, 0 failures (77 existing + 6 new AsyncParseTests)

## Status Notes

- **Cancellation**: Cooperative cancellation is now implemented for native parsers
  (DXF/STL/glTF) at stage boundaries and inside loops.  For STEP/IGES, cancellation is
  boundary-only because the OCCT read/tessellation operations are monolithic and do not
  expose a way to interrupt them mid-call.
- **OCCT**: The `--features occt` stub build now compiles and tests pass.  Real OCCT
  E2E tests require a pre-built `libmmforge_occt_shim.a` and OCCT headers/libs to be
  available at build time (see `MMFORGE_SHIM_DIR`, `OCCT_INCLUDE_DIR`, `OCCT_LIB_DIR`).
  On this machine those are not present, so the OCCT stub path is what was verified.

## Review Focus for Codex

1. **Drop vs Join**: `mmf_open_job_free` now detaches the thread.  Verify that the
   completion callback's generation check is sufficient to prevent use-after-free of the
   `ParseCallbackContext` (retained via `Unmanaged.passRetained`).

2. **Error CString lifetime**: The error `CString` is created in the Rust completion
   callback and passed as a raw pointer.  The Swift side copies it immediately.  Verify
   no path where the pointer outlives the `CString`.

3. **Token free order**: `freeCurrentDocument` frees the job first (which cancels the
   token internally), then frees the token.  The completion callback also frees the token.
   Verify no double-free when the callback fires after `freeCurrentDocument` already freed it
   (generation check should prevent this).

4. **OCCT cfg gates**: The IGES reader now mirrors the STEP reader pattern
   (`#[cfg(occt_found)]` real impl + `#[cfg(all(feature = "occt", not(occt_found)))]`
   stub).  Verify this is consistent across OCCT modules.
