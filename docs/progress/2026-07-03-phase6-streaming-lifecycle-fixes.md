# Phase 6 Round 11: Streaming Task Lifecycle Fixes

**Date**: 2026-07-03
**Scope**: Fix streaming upload task lifecycle: save `Task` handle, cancel on
document transitions, generation-guard each chunk upload, prevent stale writes.

## Changes

### 1. `streamingTask: Task<Void, Never>?` handle

The async `Task` created by `startStreamingUpload` is now saved in
`streamingTask`.  This allows explicit cancellation via `Task.cancel()`
before the natural end-of-loop bailout.

### 2. Generation guard per chunk + final publish

At task creation, `let gen = self.parseGeneration` is captured.  Before each
chunk upload and before publishing `.loaded` at the end, the task checks:

```swift
guard gen == self.parseGeneration,
      self.rustDoc != nil,
      let renderer = self.renderer,
      !Task.isCancelled
else {
    self.streamingTask = nil
    return
}
```

This prevents three classes of bug:
- **New parse started** (`gen` mismatch) → old task's chunks won't touch the new
  renderer or set `.loaded`.
- **Document freed** (`rustDoc == nil`) → won't pass stale doc pointer to
  `mmf_chunk_mesh_*` (use-after-free).
- **Task cancelled** → immediate bailout.

### 3. Cancel on document transitions

| Event | Action |
|-------|--------|
| `parseFile()` | `streamingTask?.cancel()` + `streamingTask = nil` (first, before generation bump) |
| `freeCurrentDocument()` | `streamingTask?.cancel()` + `streamingTask = nil` |
| `deinit` | `streamingTask?.cancel()` |

The explicit cancel in `parseFile` is faster than waiting for the generation
check; it also prevents wasted Metal buffer allocations for abandoned chunks.

### 4. Clear `pendingStreamingDTO` in `freeCurrentDocument`

Added `pendingStreamingDTO = nil` alongside the existing `pendingDTO = nil`.

### 5. Tests (3 new, 92 total)

| Test | Purpose |
|------|---------|
| `testReopenDuringStreaming_newFileLoads` | Open file, then immediately open another — second file reaches `.loaded` without stale data |
| `testPendingStreaming_clearedOnReopen` | Deferred streaming (no renderer), then reopen with renderer — pending cleared, new file loads |
| `testStaleStreamingTask_doesNotPublishState` | Wait for streaming progress, then open new file — old task must not overwrite triangle count or state |

## Files Changed

| File | Change |
|------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | Add `streamingTask` field; rewrite `startStreamingUpload` with gen guard; cancel in `parseFile`, `freeCurrentDocument`, `deinit`; clear `pendingStreamingDTO` |
| `macos/MMForgeTests/AsyncParseTests.swift` | 3 lifecycle tests |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 272 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 278 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| `xcodebuild ... test` | **92 tests pass** (89 → 92, +3 lifecycle) |

| Suite | Prev | Current |
|-------|------|---------|
| AsyncParse | 12 | **15** |
| Annotation | 44 | 44 |
| Picking | 22 | 22 |
| Transform | 11 | 11 |
| **Total** | 89 | **92** |
