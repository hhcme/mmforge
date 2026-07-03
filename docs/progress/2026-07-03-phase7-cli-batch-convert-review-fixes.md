# Phase 7: CLI Batch Convert Review Fixes

**Date**: 2026-07-03
**Commit**: package

## Fixes

### 1. Output conflict detection

Two inputs mapping to the same output path (same file stem, e.g.,
`a/d.stl` and `b/d.stl` both → `out/d.lsm`) now produce a pre-conversion
error:

```
CONFLICT /tmp/a/d.stl → /tmp/out/d.lsm (already mapped from /tmp/b/d.stl)
error: output file conflicts detected — resolve before continuing
```

Conflicts are detected before any I/O — output directory is not created
if conflicts exist.

### 2. Zero inputs non-zero exit

`mmforge batch-convert -o out/` with no files now exits 1 with
`error: no input files specified` and does not create the output directory.

### 3. Docs updated

`crates/mmforge-cli/README.md` now documents all current commands including
`batch-convert` with conflict detection, exit codes, and JSON fields.

### 4. New tests (2)

| Test | Scenario |
|------|----------|
| `batch_convert_output_conflict_detected` | Same-stem STL in two directories → CONFLICT, exit ≠ 0 |
| `batch_convert_zero_inputs_exits_nonzero` | No files → exit ≠ 0, no output dir |