# macOS Format Closure — LSM Magic Routing Review — 2026-07-07

**Date**: 2026-07-07
**Agent**: Opencode (deepseek-v4-pro)
**Status**: COMPLETE — lsm_detector.rs +199/−17; 10 LSM tests, 350 workspace

---

## 1. Fix: LSM/LSMC Magic-Based Routing

### Problem

`parse_lsm` determined decompression (LSMC vs raw LSM) solely by file
extension.  A `.lsmc` file renamed to `.lsm` would be passed to the LSM
reader as raw bytes, failing.  A `.bin` file with LSMC magic would never
be decompressed.

### Fix

**File**: `crates/mmforge-bridge/src/lsm_detector.rs` (+75/−15)

Extracted `parse_lsm_data(data, path)` and internal `to_format_tag()`:

```rust
fn to_format_tag(data: &[u8], path: &Path) -> FormatTag {
    if data.len() >= 4 {
        if data[..4] == LSMC_MAGIC { return Lsmc; }
        if data[..4] == LSM_MAGIC  { return Lsm;  }
    }
    // Fallback: extension-based routing (backward compatible)
    if ext == "lsmc" { Lsmc } else { Lsm }
}
```

`parse_lsm_data` uses this tag to decide whether to decompress.  The
file extension is only used as a fallback when magic bytes are absent.

### LSM Mesh→TessellationRegistry (unchanged from prior round)

Mesh geometries from deserialised LSM model are extracted into
`TessellatedMeshData` entries and inserted into the registry.

### Test Coverage: 10 LSM tests (was 3)

| # | Test | What It Verifies |
|---|------|-----------------|
| 1 | `detect_lsm_by_extension` | .lsm / .lsmc detection |
| 2 | `detect_lsm_by_magic` | LSMD / LSMC magic (no extension) |
| 3 | `reject_non_lsm` | Non-LSM files rejected |
| 4 | `parse_dot_lsm_file` | .lsm → registry: 1 mesh, 1 triangle |
| 5 | `parse_dot_lsmc_file` | .lsmc → registry: 1 mesh, 1 triangle, magic verified |
| 6 | `parse_lsmc_magic_no_extension` | LSMC magic, no extension → decompresses, 1 mesh |
| 7 | `parse_lsmc_magic_wrong_extension` | LSMC magic, .lsm extension → magic wins, decompresses |
| 8 | `parse_lsmd_magic_no_extension` | LSMD magic, no extension → raw read, 1 mesh |
| 9 | `parse_corrupted_lsmc_returns_error` | Invalid compressed data → Error with "decompress" / "LSMC" |
| 10 | `parse_empty_file_errors` | Empty .lsm → Error |

## 2. Verification

| Command | Result |
|---------|--------|
| `cargo test -p mmforge-bridge -- lsm` | **10/10 pass** (was 3) |
| `cargo test --workspace` | **350 pass** (bridge 63) |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **clean** |
| `xcodebuild test ...` | **155/155 pass** |
| `bash docs/scripts/perf-baseline.sh` | **5/5 pass** (glTF no longer FAILED) |
| `bash macos/scripts/package.sh debug` | **BUILD SUCCEEDED** |
| `bash macos/scripts/package.sh release` | **BUILD SUCCEEDED** |
| `bash macos/scripts/package.sh dmg` | **BUILD SUCCEEDED** |
| `git diff --check` | **clean** |

## 3. Commits (This Round)

| Commit | Files | Δ |
|--------|-------|---|
| `5aee00c` (LSM rendering + GLB) | 4 files | +250/−22 |
| `ffdc230` (magic routing + tests) | 3 files | +244/−100 |

### Key Source Change

| File | Δ | Change |
|------|---|--------|
| `crates/mmforge-bridge/src/lsm_detector.rs` | cumulative across both commits | Magic routing, `parse_lsm_data`, mesh→registry, 10 tests |

## 4. GUI Evidence (Manual)

LSM/LSMC rendering confirmed via `open -a MMForge.app`:

```
$ cargo run -p mmforge-cli -- convert testdata/stl/box.stl -o /tmp/test_box.lsm
$ open -a macos/build/MMForge.app /tmp/test_box.lsm    # renders 12-tri box
$ cargo run -p mmforge-cli -- convert testdata/stl/box.stl -o /tmp/test_box.lsmc --compress zstd
$ open -a macos/build/MMForge.app /tmp/test_box.lsmc    # renders same box (decompressed)
```
