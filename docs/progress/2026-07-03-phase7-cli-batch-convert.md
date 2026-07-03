# Phase 7: CLI Batch Conversion

**Date**: 2026-07-03
**Commit**: package

## New Command

```
mmforge batch-convert -o <output_dir> [--compress zstd] [--format json] [--continue-on-error] <files...>
```

Converts multiple input files into `.lsm` (or `.lsmc` with `--compress zstd`)
in a single output directory.

### Features

- **Multiple inputs**: accepts a list of files as positional arguments.
- **Output directory**: created automatically if missing.
- **Output naming**: `input.stl` → `output_dir/input.lsm` (uses file stem).
- **`--compress zstd`**: produces `.lsmc` compressed output.
- **`--format json`**: machine-readable JSON summary with per-file status,
  size, and error messages.
- **`--continue-on-error`**: process all files even if some fail; always
  exits 1 if any file failed.
- **Exit codes**: 0 = all converted, 1 = errors (partial or total).

### Text summary

```
OK    /tmp/a.stl → /tmp/out/a.lsm (561 bytes)
FAIL  /tmp/missing.stl → /tmp/out/missing.lsm (cannot read: ...)
---
1/2 converted (1 failed)
```

### JSON summary

```json
{
  "results": [
    {"file":"a.stl","output":"out/a.lsm","status":"ok","size_bytes":561,"error":null},
    {"file":"b.stl","output":"out/b.lsm","status":"error","size_bytes":null,"error":"not a valid STL"}
  ],
  "total": 2,
  "converted": 1,
  "failed": 1
}
```

## Implementation

`cmd_batch_convert` loops over input files, calling `convert_one(file, output, compress)`
per file.  Results are collected into `Vec<BatchResult>` and printed in text
or JSON format.  On error without `--continue-on-error`, the loop breaks
after the first failure.

Reuses existing `detect_and_parse` (all source formats + .lsm/.lsmc) and
`write_lsm`/`write_lsmc` paths.

## Tests (4 new integration)

| Test | Scenario | Expected |
|------|----------|----------|
| `batch_convert_two_files_succeeds` | 2 STL files | exit 0, both .lsm created |
| `batch_convert_compressed` | 1 STL + `--compress zstd` | exit 0, .lsmc created |
| `batch_convert_json_summary` | 1 STL + `--format json` | valid JSON, "converted":1 |
| `batch_convert_partial_failure_json` | 1 good + 1 bad + `--continue-on-error` | exit 1, JSON shows "converted":1, "failed":1 |

## Files Changed

| File | Change |
|------|--------|
| `crates/mmforge-cli/src/main.rs` | `BatchConvert` command + `cmd_batch_convert` + `convert_one` (94 lines) |
| `crates/mmforge-cli/Cargo.toml` | Add `serde` dependency (for `Serialize` on `BatchResult`) |
| `crates/mmforge-cli/tests/integration.rs` | 4 batch convert integration tests |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 329 tests (23 CLI integration) |
| `cargo clippy --workspace -- -D warnings` | 0 |
| `cargo clippy --workspace --tests -- -D warnings` | 0 |
| OCCT features | 335 tests |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles |
| `git diff --check` | Clean |

| CLI integration tests | Prev | Current | Δ |
|------------------------|------|---------|---|
| Total | 19 | **23** | +4 batch |
| Total locked | 325 | **329** | +4 |