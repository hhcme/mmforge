# Parse Generation Race Fix

Date: 2026-07-01
Agent: ZCode (mimo-v2.5-pro)
Target: Fix async parse race: increment generation before any cleanup

---

## Problem

`parseGeneration` was incremented after `freeCurrentDocument()` and
the `isEmpty` guard.  This meant:

1. Call `parseFile(dataA)` → generation=1, starts async parse
2. Call `parseFile(Data())` → `freeCurrentDocument()` runs, but
   generation stays 1, `state = .empty`, returns
3. Async parse from step 1 completes → generation matches (1) →
   stale result is accepted, overwriting the empty state

---

## Fix

Increment `parseGeneration` as the **very first operation** in
`parseFile(data:)`, before `freeCurrentDocument()` or any other logic.

```swift
func parseFile(data: Data) {
    parseGeneration += 1      // FIRST: invalidate any in-flight parse
    let generation = parseGeneration

    freeCurrentDocument()     // THEN: clean up previous state

    guard !data.isEmpty else {
        state = .empty
        return
    }
    // ... rest of parse
}
```

This ensures:
- Empty data path invalidates any in-flight async parse
- Temp file write failure invalidates any in-flight async parse
- All old async results are discarded regardless of code path

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `MMForgeDocument.swift` | `parseGeneration += 1` moved to function entry |
| `ContentView.swift` | Fixed onAppear indentation |
