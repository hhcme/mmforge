# Phase 7: Batch Convert Conflict Semantics

**Date**: 2026-07-03
**Commit**: package

## Fixes

### 1. Conflicts as first-class results (status=conflict)

Conflicts (same stem from different directories, existing output files) are
now included in the text/JSON summary with `status: "conflict"` instead of
being printed to stderr and aborting immediately.

Text output:
```
CONFLICT /tmp/d1/dup.stl → out/dup.lsm (output path conflicts with /tmp/d2/dup.stl)
```

JSON output includes `"conflicts"` count alongside `"converted"` and `"failed"`.

### 2. --continue-on-error semantics

- **Without `--continue-on-error`**: conflicts are reported in the summary,
  no conversions are performed, exit 1.
- **With `--continue-on-error`**: conflict items are skipped, non-conflicting
  files are converted normally, exit 1 if any conflicts or errors.

### 3. Existing output file detection

An output file that already exists on disk is treated as a conflict:
`status: "conflict", error: "output file already exists"`.  This prevents
silent overwrite.

### 4. Both sides of a conflict are tagged

When two inputs map to the same output path, BOTH entries receive
`status: "conflict"` with reciprocal error messages, not just the second one.

## Tests (5 new/updated)

| Test | Scenario |
|------|----------|
| `batch_convert_output_conflict_detected` | Same-stem files → CONFLICT in stdout, exit ≠ 0 |
| `batch_convert_continue_on_error_skips_conflicts` | 2 conflicts + 1 normal with `--continue-on-error` → conflicts=2, converted=1, exit 1 |
| `batch_convert_rejects_existing_output` | Pre-existing output file → conflict |
| `batch_convert_default_conflict_reports_json` | No `--continue-on-error` with conflict → converted=0, conflicts=2, exit 1 |
| `batch_convert_zero_inputs_exits_nonzero` | No inputs → exit 1, no output dir |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 334 tests (28 CLI integration) |
| `cargo clippy --workspace -- -D warnings` | 0 |
| `cargo clippy --workspace --tests -- -D warnings` | 0 |
| OCCT features | 340 tests |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles |
| `git diff --check` | Clean |