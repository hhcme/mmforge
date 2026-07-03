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

- **Section length bound check** — `offset + length ≤ file_size` with overflow guard; `LimitedReader` enforces per-section read cap; offset must not overlap TOC region. ✅ Fixed in Round 4.
- **No CRC or checksum** — bit flips in the TOC or section data are not detected.
- **Drawing2D geometry** is still opaque in v1 (stub serialization).
- **Compressed `.lsmc`** is still trait-only; no LZ4/ZSTD codec shipped.

## Next Steps

- Add section SHA-256 or CRC32 to file header for integrity
- Implement LZ4 `.lsmc` compression codec
- Streaming section reader with length-capped read (prevent OOM from malformed
  length fields)
- Add committed `.lsm` fixtures from IGES/DXF/STEP source files

## 4. Review Fixes (commit `59367d8`)

### Section length bounds enforcement

`SectionDesc.length` is no longer `#[allow(dead_code)]`.  Every section entry
is validated:
- `offset + length ≤ file_size` (with `checked_add` overflow guard)
- `offset` must not overlap the TOC region (`offset ≥ toc_offset + toc_size`)
- `offset` must be ≥ 64 (past the file header)

New `calculate_toc_size()` computes the precise TOC span for overlap checking.

### `LimitedReader` — bounded section reads

Each section is read through a `LimitedReader` wrapper that caps the total
readable bytes to the declared `length`.  Section parsers that attempt to read
past the declared boundary get an EOF (`Ok(0)`), preventing them from consuming
data from adjacent sections.

### Duplicate core sections rejected

Previously duplicate core sections silently overwrote each other (last-wins).
Now they raise `ReadError::DuplicateSection { section_type, name }`.

### Malformed input tests (+5 new)

| Test | Input | Expected |
|------|-------|----------|
| `section_offset_crossing_into_toc_rejected` | Section at TOC offset | "overlaps TOC" |
| `section_offset_plus_length_exceeds_file` | Section length 99999 in 200B file | "exceeds file size" |
| `section_offset_plus_length_overflow` | `u64::MAX-10 + 20` overflow | "exceeds file size" |
| `duplicate_core_section_rejected` | Two Header sections | "duplicate core section" |
| `section_limited_reader_stops_at_boundary` | Round-trip validates LimitedReader | OK |

### Golden test: byte-for-byte hash

Changed from field-level assertions to stable 64-bit hash comparison:
1. Reconstruct `golden_model()` using `ModelBuilder`
2. `write_lsm` to buffer
3. `hash_bytes(&reconstructed)` vs `hash_bytes(&committed_golden_file)`
4. Any binary format change = hash mismatch

### validate --format json metadata

`mmforge validate --format json` now includes:
```json
{
  "source_format": "STL",
  "source_path": "fixture/sample.stl",
  "metadata": {"units": "mm", "author": "...", "description": "..."},
  "custom": {"generator": "mmforge-golden-gen"},
  "node_count": 2,
  "triangle_count": 1
}
```

### Updated test counts

| Test | Prev | Current | Δ |
|------|------|---------|---|
| LSM (core) | 15 | **19** | +4 |
| Total locked | 304 | **308** |
| Total OCCT | 310 | **314** |
