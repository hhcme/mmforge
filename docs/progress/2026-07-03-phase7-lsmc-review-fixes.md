# Phase 7: LSMC Review Fixes

**Date**: 2026-07-03
**Commit**: package

## Fixes

### 1. Cargo.lock committed

The `zstd` dependency addition from Round 4 was not committed in `Cargo.lock`.
Committed now.

### 2. Unknown `--compress` value rejected

Previously `mmforge convert --compress lz4` silently produced uncompressed `.lsm`
(the `_ => "lsm"` fallback).  Now unknown values exit with:

```
error: unknown compression method 'lz4' (supported: zstd)
```

### 3. `.lsmc` extension AND LSMC magic detection

- **Extension-based**: `.lsmc` files are routed to `parse_lsm`, which checks
  for `LSMC` magic.  If magic is wrong (`LSMD` in `.lsmc` file), the file
  fails with a clear error.
- **Magic-based**: a `.lsm` file containing `LSMC` magic is correctly
  decompressed and read as `.lsmc`.
- Both paths tested in integration tests.

### 4. Format documentation updated

`docs/lsm/format-spec.md` now reflects actual implementation:
- `.lsmc` uses **zstd** compression (v1, implemented), not LZ4 (v2.0+ draft)
- Section 9 "实现状态" documents current reader/writer/CLI coverage

### 5. New integration tests (3)

| Test | Purpose |
|------|---------|
| `unknown_compress_method_rejected` | `--compress lz4` → non-zero exit + error message |
| `lsmc_extension_corrupt_lsmc_rejected` | `.lsmc` file with `LSMD` magic → error |
| `lsmc_magic_in_any_extension_reads` | `.lsm` file with `LSMC` magic → decompress → info OK |

## Files Changed

| File | Change |
|------|--------|
| `Cargo.lock` | Commit zstd dependency |
| `crates/mmforge-cli/src/main.rs` | Reject unknown `--compress`, fix fmt |
| `crates/mmforge-core/src/lsm/lsmc.rs` | Fix fmt |
| `crates/mmforge-cli/tests/integration.rs` | +3 tests (unknown compress, extension detection, magic detection) |
| `docs/lsm/format-spec.md` | Update .lsmc description to zstd/v1 |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 322 tests (8 CLI unit + 16 CLI integration + 97 core + 89 render + ...) |
| `cargo clippy --workspace -- -D warnings` | 0 |
| `cargo clippy --workspace --tests -- -D warnings` | 0 |
| `OCCT features` | 328 tests |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles |
| `git diff --check` | Clean |