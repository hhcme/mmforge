# Structure Sidebar/Inspector — Review Fixes

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix C ABI return type contract, error state, and doc date

---

## Fixes

### 1. C ABI return type contract unified

`mmf_node_has_geometry` and `mmf_node_bounds` now return `c_int`
(1/0) instead of `bool`.  This matches the C header's `int`
declaration and avoids Rust `bool` → C ABI portability issues.

**Before**: Rust returned `bool`, C header declared `int`, Swift used
`!= 0` to convert `Int32` to `Bool`.

**After**: Rust returns `c_int` (1 = true, 0 = false).  C header
declares `int`.  Swift still uses `!= 0` for `Bool` conversion —
now consistent across all three layers.

### 2. StructureSidebar error state

`.error` case now shows a real error view with warning icon and
message, instead of falling through to `sidebarEmptyState` which
displayed "No structure".

### 3. Progress doc date corrected

Renamed `2026-07-01-macos-structure-sidebar-inspector.md` →
`2026-06-30-macos-structure-sidebar-inspector.md` and updated the
Date field inside.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 84 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `crates/mmforge-bridge/src/lib.rs` | `mmf_node_has_geometry`/`mmf_node_bounds` return `c_int` 1/0 |
| `macos/MMForge/Views/StructureSidebar.swift` | Added `sidebarErrorState` for `.error` case |
| `docs/progress/2026-06-30-macos-structure-sidebar-inspector.md` | Renamed from 2026-07-01, date fixed |
