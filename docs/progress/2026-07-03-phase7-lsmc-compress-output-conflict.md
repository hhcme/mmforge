# Phase 7: LSMC Compress/Output Conflict Fix

**Date**: 2026-07-03
**Commit**: package

## Issue

`mmforge convert --compress zstd -o explicit.lsm` silently produced a plain
LSMD file because the output extension check (`out.extension() == "lsmc"`)
determined the write path, overriding the `--compress` flag.

## Fix

`cmd_convert` now explicitly validates:

1. When `--compress` is set, the output extension **must** be `.lsmc`
   (case-insensitive check).
2. If the extension is not `.lsmc`, the command exits with:
   ```
   error: --compress requires .lsmc output extension (got explicit.lsm)
   ```
3. No silent fallback — the user must either rename the output or drop
   `--compress`.

The check happens before any I/O — template extension defaults are applied
first, then the extension-compress conflict is validated.

## Test

`compress_zstd_rejects_non_lsmc_output` — creates a `.lsm` output path with
`--compress zstd`, asserts non-zero exit and error message containing `.lsmc`.

## Additional cleanups

- Renamed `lsmc_magic_in_any_extension_reads` test to
  `lsmc_magic_in_unknown_extension_reads` to match actual semantics
  (uses `.data` extension, not `.lsm`).
- Fixed duplicate `#[test]` annotations and orphan code in integration tests.
- Updated strict routing report: "any extension" → "unknown/no extension".

## Files Changed

| File | Change |
|------|--------|
| `crates/mmforge-cli/src/main.rs` | Compress-extension conflict check before I/O |
| `crates/mmforge-cli/tests/integration.rs` | +1 test, rename test, fix duplicate annotation |
| `docs/progress/2026-07-03-phase7-lsmc-strict-routing-fix.md` | Fix phrasing |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 325 tests (19 CLI integration) |
| `cargo clippy --workspace -- -D warnings` | 0 |
| `cargo clippy --workspace --tests -- -D warnings` | 0 |
| OCCT features | 331 tests |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles |
| `git diff --check` | Clean |