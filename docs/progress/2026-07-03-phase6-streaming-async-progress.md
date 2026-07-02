# Phase 6 Round 10: Streaming Async Progress & Pending Deferral

**Date**: 2026-07-03
**Scope**: Make `uploadStreaming` truly asynchronous with inter-chunk yield,
add pending-streaming deferral for late renderer binding, and add comprehensive
streaming-path tests.

## Changes

### 1. Async chunk upload with `Task` + `await Task.yield()`

`uploadStreaming(dto:)` now delegates to `startStreamingUpload(dto:)` which
runs inside a `Task { @MainActor [weak self] in ... }`.  After each chunk is
uploaded, `await Task.yield()` yields to the actor run loop, allowing SwiftUI
bindings (`parseStage`, `parseProgress`) and Metal draw calls to refresh between
chunks.

Before (synchronous for-loop, blocked UI):
```swift
for ci in 0..<totalChunks {
    parseStage = ... ; parseProgress = ...
    RustBridge.shared.uploadChunk(...)
}
parseStage = ""; parseProgress = 1; state = .loaded(...)
```

After (async, UI can refresh):
```swift
Task { @MainActor [weak self] in
    for ci in 0..<totalChunks {
        parseStage = ... ; parseProgress = ...
        RustBridge.shared.uploadChunk(...)
        await Task.yield()  // ← yield to run loop
    }
    parseStage = ""; parseProgress = 1; state = .loaded(...)
}
```

### 2. Pending streaming DTO for late renderer binding

Added `pendingStreamingDTO: RenderPacketDTO?` field.  When `uploadStreaming`
is called before the renderer is bound (e.g., async parse completes faster than
view creation), the DTO is stored and `setRenderer` resumes the upload:

```swift
func uploadStreaming(dto: RenderPacketDTO) {
    guard renderer != nil else {
        pendingStreamingDTO = dto  // defer
        return
    }
    startStreamingUpload(dto: dto)
}
```

`setRenderer` checks both `pendingDTO` (full-upload) and `pendingStreamingDTO`
(streaming), resuming the appropriate path:

```swift
if let dto = pendingDTO { ... uploadToRenderer(dto:) }
if let dto = pendingStreamingDTO { ... startStreamingUpload(dto:) }
```

`freeCurrentDocument()` clears both pending fields.

### 3. `_testForceStreaming` flag

Added `var _testForceStreaming = false` to force streaming mode on small
models for testing.  `shouldStream` checks:

```swift
return _testForceStreaming || dto.triangleCount > Self.streamingTriangleThreshold
```

### 4. Tests (6 new, 89 total Xcode)

| Test | Purpose |
|------|---------|
| `testShouldStream_falseForSmallModel` | 1 tri → false |
| `testShouldStream_trueForLargeModel` | 200k tri → true |
| `testSmallModelUsesFullUploadPath` | E2E: small STL → full upload → .loaded |
| `testForceStreaming_reachesLoaded` | Force streaming on small model → .loaded |
| `testStreaming_reportsUploadProgress` | Streaming emits parseStage updates during chunk loop |
| `testDeferredStreaming_rendererBoundLater` | Parse completes before renderer bound → streaming resumes after `setRenderer` → .loaded |

## Files Changed

| File | Change |
|------|--------|
| `macos/MMForge/Document/MMForgeDocument.swift` | Add `pendingStreamingDTO`, `_testForceStreaming`; rewrite `uploadStreaming` as async `Task` + `startStreamingUpload`; update `setRenderer` and `freeCurrentDocument` |
| `macos/MMForgeTests/AsyncParseTests.swift` | 6 new tests; `makeVMWithRenderer` helper; import Metal + MetalKit |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 272 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 278 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| `xcodebuild ... test` | **89 tests pass** (83 → 89, +6 streaming) |

| Suite | Prev | Current |
|-------|------|---------|
| AsyncParse | 6 | **12** |
| Annotation | 44 | 44 |
| Picking | 22 | 22 |
| Transform | 11 | 11 |
| **Total** | 83 | **89** |
