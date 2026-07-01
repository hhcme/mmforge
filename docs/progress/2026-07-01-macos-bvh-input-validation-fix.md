# BVH Input Validation Fix — filtered triInfos.count

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix buildMeshBVH to use filtered triangle count for BVH
        construction, not the original unfiltered count

---

## Bug

After filtering invalid triangles (OOB indices), `buildMeshBVH` used
the original `triCount` (= `indices.count / 3`) for:
- `reserveCapacity(triCount * 2)` — oversized allocation
- `reserveCapacity(triCount)` — oversized allocation
- `build(begin: 0, end: triCount)` — **accesses beyond triInfos**

The `build` function indexes into `triInfos[begin..<end]`.  If
`triCount > triInfos.count`, this causes an out-of-bounds crash.

## Fix

```swift
// After filtering invalid triangles:
let validTriCount = triInfos.count

var nodes: [BVHNode] = []
nodes.reserveCapacity(validTriCount * 2)
var sortedIndices: [Int] = []
sortedIndices.reserveCapacity(validTriCount)

// ...
_ = build(begin: 0, end: validTriCount)  // not triCount
```

The `sortedTriIndices` mapping is correct: each entry is the
`originalIndex` from `TriInfo`, which maps back to the original
`indices` array position.

---

## Commands Run

| Command | Result |
|---------|--------|
| `swift BVHPickingTests.swift` | ✅ 12/12 pass |
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild test-without-building` | ✅ 22/22 pass |
| `xcodebuild build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Metal/Picking.swift` | `validTriCount = triInfos.count`; `reserveCapacity` and `build` use `validTriCount` |
