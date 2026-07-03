# Phase 7: LSMC Strict Routing Fix

**Date**: 2026-07-03
**Commit**: package

## Issue

`parse_lsm` was a unified function that handled both `.lsm` and `.lsmc` by
checking magic bytes at the top.  This allowed:

1. A valid `.lsm` file renamed to `.lsmc` to silently succeed (magic was `LSMD`,
   which fell through to the `.lsm` reader).
2. No clear separation between extension-based and magic-based detection.

## Fix

Split `parse_lsm` into two dedicated functions:

- `parse_lsm_file(path)` — only for `.lsm` extension or `LSMD` magic
- `parse_lsmc_file(path)` — only for `.lsmc` extension or `LSMC` magic

Detection routing in `detect_and_parse`:

| Input | Route |
|-------|-------|
| `.lsm` extension | → `parse_lsm_file` (must be `LSMD` magic) |
| `.lsmc` extension | → `parse_lsmc_file` (must be `LSMC` magic) |
| `LSMD` magic (any extension) | → `parse_lsm_file` |
| `LSMC` magic (unknown/no extension) | → `parse_lsmc_file` |

A `.lsm` file renamed to `.lsmc` is now correctly rejected with "bad lsmc magic".
A `.lsmc` file with a non-standard extension (or no extension) is correctly
detected by magic.

## Tests (2 new)

| Test | Scenario | Expected |
|------|----------|----------|
| `lsmc_extension_rejects_plain_lsm_data` | `.lsm` → rename to `.lsmc` | non-zero exit |
| `no_extension_lsmc_magic_reads` | `.lsmc` → remove extension | reads correctly |

Also fixed `lsmc_magic_in_any_extension_reads` to use `.data` extension instead
of `.lsm` (`.lsm` now strictly expects `LSMD` magic).

## Files Changed

| File | Change |
|------|--------|
| `crates/mmforge-cli/src/main.rs` | Split `parse_lsm` into `parse_lsm_file` + `parse_lsmc_file`; add `LSMC` magic detection for extension-less files |
| `crates/mmforge-cli/tests/integration.rs` | +2 tests, fix 1 existing test |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 324 tests (18 CLI integration) |
| `cargo clippy --workspace -- -D warnings` | 0 |
| `cargo clippy --workspace --tests -- -D warnings` | 0 |
| OCCT features | 330 tests |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles |
| `git diff --check` | Clean |
