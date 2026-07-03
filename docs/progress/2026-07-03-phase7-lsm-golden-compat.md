# Phase 7 Round 3: LSM Golden Fixtures, Metadata Output, Reader Hardening

**Date**: 2026-07-03
**Scope**: Commit a golden `.lsm` v1 fixture with regression test, add
CLI `--format json` metadata output, strengthen reader against malformed files.

## Changes

### 1. Committed golden fixture

`testdata/lsm/model_golden_v1.lsm` (741 bytes) — a deterministic binary
produced by `ModelBuilder`: 1 triangle mesh, 1 material ("Steel"), 2 nodes,
metadata with units = "mm", author, description, and custom key.

`golden_fixture_model_golden_v1` test asserts exact field values after
reading back, ensuring binary output is stable across code changes.

### 2. CLI JSON metadata output

`mmforge info --format json` now includes:

```json
{
  "source_path": "fixture/sample.stl",
  "parser_version": "mmforge-cli 0.1.0",
  "metadata": {
    "units": "mm",
    "author": "MMForge golden test suite",
    "description": "Golden LSM v1 fixture for regression testing"
  },
  "custom": { "generator": "mmforge-golden-gen" }
}
```

Previously these fields were only in the text output or absent entirely.

### 3. Reader hardening

New `ReadError::CorruptToc` variant. Added validation:

- **TOC offset** must be ≥ 64 (past the file header).
- **TOC count** capped at 1024 to reject ridiculous/malformed values.
- **Section offset** must be ≥ 64 (not inside the file header).

New error-path tests:

| Test | Input | Expected error |
|------|-------|---------------|
| `toc_offset_inside_header_is_rejected` | TOC offset = 32 | "inside the file header" |
| `implausible_toc_count_is_rejected` | TOC count = 9999 | "implausible TOC count" |
| `section_offset_overlapping_toc_is_rejected` | Section at offset 32 | "inside the file header" |
| `missing_core_section_is_error` | Only extension section, no core sections | "missing core section" |
| `duplicate_core_section_last_wins` | Source format patched → "IGES", verified last-wins |

Unknown extension sections (≥0x10) continue to be silently skipped.

### Test counts

| Crate | Prev | Current | Δ |
|-------|------|---------|---|
| mmforge-core | 80 | **86** | +6 (golden + malformed tests) |
| Total locked | 298 | **304** |

## Files Changed

| File | Action |
|------|--------|
| `testdata/lsm/model_golden_v1.lsm` | New — committed golden fixture (741 bytes) |
| `crates/mmforge-core/src/lsm/reader.rs` | Add `CorruptToc` error, TOC/section bound checks |
| `crates/mmforge-core/src/lsm/tests.rs` | +6 tests (golden, malformed, duplicate) |
| `crates/mmforge-cli/src/main.rs` | JSON output includes source_path, parser_version, metadata, custom |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 304 tests pass |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `cargo clippy --workspace --tests -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 310 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| Working tree | Clean |

## Format Compatibility Strategy

- `.lsm` v1 format is backward-compatible by design: unknown section types are
  skipped, schema version is checked, TOC structure is versioned.
- A committed golden fixture (`testdata/lsm/model_golden_v1.lsm`) provides
  regression detection for any writer change that would alter binary output.
- Breaking changes must bump `SCHEMA_VERSION` and reject older files with
  `UnsupportedVersion`.

## Known Limitations

- **No section length bound check** — a section claiming 1 TB of data would
  OOM on read.  A streaming reader with length-capped read would address this.
- **No CRC or checksum** — bit flips in the TOC or section data are not detected.
- **Drawing2D geometry** is still opaque in v1 (stub serialization).
- **Compressed `.lsmc`** is still trait-only; no LZ4/ZSTD codec shipped.

## Next Steps

- Add section SHA-256 or CRC32 to file header for integrity
- Implement LZ4 `.lsmc` compression codec
- Streaming section reader with length-capped read (prevent OOM from malformed
  length fields)
- Add committed `.lsm` fixtures from IGES/DXF/STEP source files
