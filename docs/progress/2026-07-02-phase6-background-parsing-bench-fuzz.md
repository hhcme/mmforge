# Phase 6: Background Parsing, Progress, Cancellation, Benchmarks, Fuzz

**Date**: 2026-07-02
**Scope**: Phase 6 kickoff — OpenDocumentJob main pipeline, RenderPacket stats, benchmark/fuzz framework.

## What Was Built

### 1. CancellationToken (`crates/mmforge-core/src/cancel.rs`)

Thread-safe cooperative cancellation token using `AtomicBool` with `Relaxed`
ordering.  Cheap to poll in tight loops (`is_cancelled()` is a single atomic
load).  `Clone` returns a handle to the same underlying flag via `Arc`.

### 2. ParseProgress + ProgressCallback (`crates/mmforge-core/src/progress.rs`)

- `ParseProgress { stage: &'static str, current: u32, total: u32 }` — stage
  name ("detecting", "parsing", "tessellating", "building"), items processed,
  total items (0 = indeterminate).
- `ProgressCallback = Box<dyn Fn(&ParseProgress) + Send + Sync>` — invoked
  from worker threads.

### 3. Error::Cancelled (`crates/mmforge-core/src/error.rs`)

New variant added to the unified error enum.  Parsers return this when the
cancellation token is set.

### 4. FormatParser trait extension (`crates/mmforge-core/src/parser.rs`)

Added `parse_with_progress(&self, path, progress, cancel) -> Result<ParseOutput>`
with a default implementation that checks cancellation once and delegates to
`parse()`.  Parsers that support incremental progress can override this.

### 5. RenderPacket statistics (`crates/mmforge-render/src/packet.rs` + `builder.rs`)

Extended `RenderStats` with:
- `total_vertices: usize`
- `total_indices: usize`
- `memory_bytes: usize` — approximate GPU footprint (positions + normals + indices)
- `build_duration_ms: f64` — wall-clock time for `build_render_packet`

Exposed via C ABI: `mmf_render_stats(doc, out_mesh_count, out_vertex_count,
out_triangle_count, out_memory_bytes, out_build_ms)`.

### 6. OpenDocumentJob (`crates/mmforge-bridge/src/job.rs`)

Background document open job with progress and cancellation:

- `mmf_cancel_token_new()` / `mmf_cancel_token_cancel()` / `mmf_cancel_token_free()`
- `mmf_open_async(path, cancel_token, progress_cb, completion_cb, user_data)`
  spawns a background thread that runs detect → parse → tessellate → build.
  Progress and completion callbacks are C function pointers with `void* user_data`.
- `mmf_open_job_cancel(job)` / `mmf_open_job_free(job)`

Uses `UserdataPtr(usize)` wrapper to safely pass `*mut c_void` across thread
boundaries (avoids `Send`/`Sync` issues with raw pointers).

### 7. Shared parse detection (`crates/mmforge-bridge/src/lib.rs`)

Extracted `parse_with_detection()` — the format detection cascade used by both
`synchronous mmf_parse_file` and the async job.  Eliminates code duplication.

### 8. DXF benchmark framework (`crates/mmforge-format-dxf/benches/dxf_bench.rs`)

Criterion benchmarks for:
- `parse_dxf_test_fixture` — full parse of test.dxf
- `parse_dxf_linetypes` — full parse of linetypes.dxf
- `tokenize_test_fixture` — tokenizer throughput
- `build_draw_list` — draw list construction

Run with: `cargo bench -p mmforge-format-dxf`

### 9. Fuzz targets (`fuzz/`)

- `fuzz_dxf_tokenizer` — feeds random bytes to `DxfTokenizer`
- `fuzz_dxf_parser` — feeds random bytes to `parse_dxf` via temp file

Run with: `cargo +nightly fuzz run fuzz_dxf_tokenizer`

### 10. Swift integration

- `DocumentViewModel.parseFile()` now uses `mmf_open_async` with progress
  callback and cancellation token.
- `ParseCallbackContext` (private class) holds weak reference to view model +
  generation counter for stale-result detection.
- `parseProgressCallback` / `parseCompletionCallback` are static C-compatible
  functions that bridge to the main thread.
- `parseStage` and `parseProgress` published properties for UI binding.
- `currentJob` and `currentCancelToken` for cancellation on document free.
- `RustBridge.buildDTO(from:)` extracted from `parseFile` for reuse by async
  callback.
- `RustBridge.renderStats(_:)` returns `RenderStatsDTO`.

## Architecture

```
Swift UI
  │  parseFile(data, ext)
  ▼
DocumentViewModel
  │  mmf_cancel_token_new()
  │  mmf_open_async(path, token, progress_cb, completion_cb, ctx)
  ▼
OpenDocumentJob (Rust, background thread)
  │  cancel check → detect → parse → tessellate → build
  │  progress_cb("parsing", current, total) per stage
  │  completion_cb(doc_ptr, user_data) on finish
  ▼
ParseCallbackContext (Swift, via Unmanaged)
  │  DispatchQueue.main.async → update viewModel state
  ▼
DocumentViewModel
  │  rustDoc = doc; buildDTO; uploadToRenderer
  ▼
Metal Renderer
```

## Test Results

- **Rust**: 209 tests pass (36 + 71 + 39 + 6 + 12 + 5 + 39 + 1 new)
- **Clippy**: clean (0 warnings with `-D warnings`)
- **Xcode build**: SUCCEEDED
- **Xcode tests**: 77 tests pass, 0 failures

## Files Created/Modified

| File | Action |
|------|--------|
| `crates/mmforge-core/src/cancel.rs` | **Create** — CancellationToken |
| `crates/mmforge-core/src/progress.rs` | **Create** — ParseProgress + ProgressCallback |
| `crates/mmforge-core/src/error.rs` | Modify — add Error::Cancelled |
| `crates/mmforge-core/src/lib.rs` | Modify — export cancel, progress modules |
| `crates/mmforge-core/src/parser.rs` | Modify — add parse_with_progress |
| `crates/mmforge-bridge/src/job.rs` | **Create** — OpenDocumentJob + C ABI |
| `crates/mmforge-bridge/src/lib.rs` | Modify — parse_with_detection, mmf_render_stats |
| `crates/mmforge-render/src/packet.rs` | Modify — extended RenderStats |
| `crates/mmforge-render/src/builder.rs` | Modify — populate new stats fields |
| `crates/mmforge-format-dxf/Cargo.toml` | Modify — add criterion |
| `crates/mmforge-format-dxf/benches/dxf_bench.rs` | **Create** — criterion benchmarks |
| `crates/mmforge-format-dxf/src/lib.rs` | Modify — export DxfTokenizer |
| `fuzz/Cargo.toml` | **Create** — fuzz workspace |
| `fuzz/fuzz_targets/fuzz_dxf_tokenizer.rs` | **Create** |
| `fuzz/fuzz_targets/fuzz_dxf_parser.rs` | **Create** |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | Modify — new C declarations |
| `macos/MMForge/RustBridge/RustBridge.swift` | Modify — buildDTO, renderStats, async support |
| `macos/MMForge/Document/MMForgeDocument.swift` | Modify — async parse, progress, cancel |

## Review Focus for Codex

1. **Thread safety**: `UserdataPtr` wraps `*mut c_void` as `usize` with
   `unsafe impl Send + Sync`.  Verify the invariant that the pointed-to data
   outlives the callback invocation.

2. **Cancellation**: `CancellationToken` uses `Relaxed` ordering.  This is
   sufficient for best-effort cancellation but does not guarantee the parser
   sees the cancellation immediately on all architectures.

3. **Swift callback lifetime**: `ParseCallbackContext` is retained via
   `Unmanaged.passRetained` and released via `takeRetainedValue` in the
   completion callback.  If the completion callback is never called (e.g. the
   thread panics), the context leaks.

4. **Benchmark corpus**: Currently uses small test fixtures.  Need larger
   real-world files for meaningful performance regression detection.

5. **Fuzz targets**: Only cover DXF tokenizer and parser.  STEP and STL fuzz
   targets are planned but not yet implemented (STEP requires OCCT).
