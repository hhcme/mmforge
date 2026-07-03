# mmforge-cli

Command-line interface for MMForge model inspection and conversion.

## Commands

### `mmforge version`
Display version and build information.

### `mmforge info <file> [--format json]`
Detect format, parse, and print model metadata and statistics.
Supports `.stl` (ASCII/binary), `.lsm`, `.lsmc`, `.step` (stub), `.iges` (stub), `.dxf` (stub).
Exit code 0 on success, 1 on parse error.

### `mmforge validate <file> [--format json]`
Parse, validate references, and report issues.
Exit code 0 if valid, 1 if issues or parse error.

### `mmforge convert <file> [-o output] [--compress zstd]`
Convert a source file to `.lsm` (or `.lsmc` with `--compress zstd`).
Default output: `<file>.lsm`.  `--compress` requires `.lsmc` output extension.

### `mmforge benchmark <file> [-i N] [--format json]`
Benchmark parse times over N iterations (default 5).
Reports min, max, median, avg in milliseconds.

### `mmforge batch-convert -o <dir> [--compress zstd] [--format json] [--continue-on-error] <files...>`
Batch-convert multiple files into a single output directory.

| Option | Description |
|--------|-------------|
| `-o <dir>` | Output directory (created automatically) |
| `--compress zstd` | Produce compressed `.lsmc` output |
| `--format json` | Machine-readable JSON summary |
| `--continue-on-error` | Continue processing after individual failures |

Output naming: `input.stl` -> `<dir>/input.lsm` (uses file stem).

**Exit codes**: 0 = all converted, 1 = errors or conflicts.

**Conflict detection**: If two different input files map to the same output
name (e.g., `a/d.stl` and `b/d.stl`), the command detects the conflict before
any conversion and exits with an error.  Use `--continue-on-error` to skip
conflicting pairs and continue with non-conflicting files.

**JSON summary fields**:

```json
{
  "results": [
    {"file": "...", "output": "...", "status": "ok|error|conflict|skipped", "size_bytes": N, "error": null}
  ],
  "total": 3,
  "converted": 1,
  "failed": 0,
  "conflicts": 1,
  "skipped": 1
}
```

**Status values**:
- `ok` — converted successfully
- `error` — parse/convert failed
- `conflict` — output path collision or existing file
- `skipped` — not converted because another input in the batch had a conflict (only without `--continue-on-error`)

## Usage

```bash
cargo run --bin mmforge -- info model.stl
cargo run --bin mmforge -- batch-convert -o out/ model1.stl model2.stl
```
