# Phase 6 Round 9: Streaming Load Path — Production Integration

**Date**: 2026-07-03
**Scope**: Wire `buildChunks`/`uploadChunk` into the actual macOS file loading
flow, providing a real progressive loading path that the app calls automatically
for large models.

## Changes

### 1. Streaming threshold + conditional dispatch

Added two static constants to `DocumentViewModel`:

- `defaultChunkBudget: UInt32 = 64 * 1024 * 1024` — 64 MB per chunk
- `streamingTriangleThreshold = 100_000` — models with >100k triangles use streaming

New method `shouldStream(_ dto:) -> Bool` checks the triangle count against the
threshold.

### 2. `uploadStreaming(dto:)` — progressive chunk upload loop

Replaces the full-upload path when the model exceeds the threshold:

1. Builds chunks via `buildChunks(budgetBytes:)`
2. If chunking produces 0 chunks, falls back to `uploadToRenderer(dto:)`
3. Clears the renderer
4. Loops through chunks 0..N:
   - Sets `parseStage = "Uploading meshes (chunk X/N)..."`
   - Sets `parseProgress = current / total`
   - Calls `RustBridge.shared.uploadChunk(...)` per chunk
5. Sets scene bounds, triggers section fill if needed
6. Transitions state to `.loaded(triangleCount:meshCount:nodeCount:)`

The old `uploadToRenderer(dto:)` path is kept intact and is called for models
below the threshold.

### 3. `parseCompletionCallback` — conditional dispatch

The completion callback now checks `vm.shouldStream(dto)` before deciding
which upload path to use:

```swift
if vm.shouldStream(dto) {
    vm.uploadStreaming(dto: dto)   // sets state to .loaded internally
} else {
    vm.uploadToRenderer(dto: dto)  // existing path
    vm.parseStage = ""
    vm.parseProgress = 1
    vm.state = .loaded(...)
}
```

### 4. `RustBridge.uploadChunk` — actual upload count

Previously returned `meshCount` unconditionally.  Now returns
`var uploaded = 0; ... uploaded += 1` per successful mesh, so the
return value reflects the actual number of meshes uploaded (excluding
those skipped due to null pointers or zero counts).

### 5. Swift tests (3 new)

| Test | Purpose |
|------|---------|
| `testShouldStream_falseForSmallModel` | 1-triangle DTO → false |
| `testShouldStream_trueForLargeModel` | 200k-triangle DTO → true |
| `testSmallModelUsesFullUploadPath` | End-to-end: small STL still loads via full path |

The existing 6 AsyncParseTests continue to pass — full-upload path is
backward compatible.

### 6. Rust tests

Existing `reset_rebuild_chunks_with_new_budget` and `chunk_streaming_on_parsed_doc`
tests continue to pass, covering the chunk building and querying path exercised
by `uploadStreaming`.

## Files Changed

| File | Change |
|------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | Add `shouldStream`, `uploadStreaming`, constants; modify `parseCompletionCallback` dispatch |
| `macos/MMForge/RustBridge/RustBridge.swift` | Fix `uploadChunk` return count |
| `macos/MMForgeTests/AsyncParseTests.swift` | 3 new streaming path tests |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 272 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 278 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| `xcodebuild ... build` | BUILD SUCCEEDED |

## Architecture

```
parseCompletionCallback
  ├─ shouldStream(dto)? ─ NO ── uploadToRenderer(dto)  [existing, unchanged]
  └─ YES
       └─ uploadStreaming(dto)
            ├─ buildChunks(budget)
            ├─ clearMeshes()
            ├─ for chunk 0..N:
            │    ├─ parseStage = "Uploading (chunk X/N)..."
            │    ├─ parseProgress = X/N
            │    └─ RustBridge.uploadChunk(chunk) → renderer
            ├─ setSceneBounds()
            └─ state = .loaded
```
