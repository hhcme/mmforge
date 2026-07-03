# Phase 7 Round 1: LSM Binary Format v1 + CLI Foundation

**Date**: 2026-07-03
**Scope**: Design and implement `.lsm` v1 versioned section binary format
(magic/schema version/feature flags/section table/unknown-section skip),
`.lsmc` compression trait interface, core reader/writer with golden &
compatibility tests, and CLI `info/validate/convert/benchmark` commands
with text/JSON output.

## 1. LSM Binary Format (`.lsm` v1)

### Module: `crates/mmforge-core/src/lsm/`

| File | Purpose |
|------|---------|
| `constants.rs` | Magic `LSMD`, schema version 1, section type IDs, feature flags, compression method IDs, source format IDs |
| `binary.rs` | Little-endian IO primitives: `write_u32/u64/u16/u8/f32/string/vec3/mat4/padding` + matching readers |
| `writer.rs` | `write_lsm(model, &mut Write+Seek)` — header (64B) → 5 sections → TOC → patch TOC offset |
| `reader.rs` | `read_lsm(&mut Read+Seek) → Result<LsmModel>` — validates magic, checks version, seeks to TOC, reads sections, skips unknown types (≥0x10) |
| `compress.rs` | `LsmCompressor` trait (method_id, compress, decompress) + `NoCompression` pass-through |
| `tests.rs` | 8 tests: round_trip, golden magic, scene tree, geometry mesh, bad magic, version rejection, unknown section skip |
| `mod.rs` | Module root + re-exports |

### File layout

```
┌──────────────────────────────┐
│ File header (64 bytes)        │ magic(4) + version(2) + flags(2) + toc_offset(8) + toc_count(4) + source_format(4) + padding(40)
├──────────────────────────────┤
│ Sections (variable)           │ header → scene_tree → geometry → materials → metadata
├──────────────────────────────┤
│ TOC (4 + N×20 bytes)         │ count(u32) + N×(section_type:u32 + offset:u64 + length:u64)
└──────────────────────────────┘
```

### Forward compatibility

- Reader skips unknown section types (both unrecognised core types ≤0x0F and extensions ≥0x10).
- Schema version check rejects files with version > 1.
- Missing core sections (Header, SceneTree, Geometry, Materials, Metadata) raise `MissingCoreSection`.

### Compression interface

`LsmCompressor` trait with `method_id()`, `compress()`, `decompress()`.  `NoCompression` pass-through provided.  Ready for LZ4/ZSTD via `compression::ZSTD` / `compression::LZ4` method IDs.

## 2. CLI Commands

All commands in `crates/mmforge-cli/src/main.rs`:

| Command | Output | Description |
|---------|--------|-------------|
| `version` | text | Build version |
| `info <file>` | text/json | Format, nodes, geometries, materials, triangle count, bounds, warnings |
| `validate <file>` | text/json | Parse + structural validation; exit 1 on issues |
| `convert <file> [-o out.lsm]` | text | Parse → write `.lsm` binary |
| `benchmark <file> [-i N]` | text/json | Parse timings over N iterations (min/max/median/avg) |

Supports ASCII STL, binary STL, IGES (stub), DXF (stub), STEP (stub).
`--format json` for info/validate/benchmark.

### Smoke test

```console
$ mmforge info test.stl
file    : test.stl
format  : STL
nodes   : 2
geoms   : 1
triangles: 1
bounds  : [0.000,0.000,0.000] – [1.000,1.000,0.000]

$ mmforge convert test.stl -o test.lsm
wrote test.lsm (561 bytes)
```

## 3. Tests

| Test | Category |
|------|----------|
| `round_trip_bytes` | Write → read → assert header/source/scene/geometry/material match |
| `golden_header_magic` | First 4 bytes = `LSMD`, version = 1 |
| `scene_tree_preserved` | Node names + parent relationship round-trip |
| `geometry_mesh_preserved` | Positions, normals, indices survive round-trip |
| `bad_magic_rejected` | `XXXX` magic → `BadMagic` error |
| `high_version_rejected` | Version 99 → `UnsupportedVersion` error |
| `unknown_section_skipped` | Inject 0x10 extension entry in TOC → reader skips, model intact |

## 4. Files Changed

| File | Action | Lines |
|------|--------|-------|
| `crates/mmforge-core/src/lsm/constants.rs` | New | ~70 |
| `crates/mmforge-core/src/lsm/binary.rs` | New | ~130 |
| `crates/mmforge-core/src/lsm/writer.rs` | New | ~250 |
| `crates/mmforge-core/src/lsm/reader.rs` | New | ~410 |
| `crates/mmforge-core/src/lsm/compress.rs` | New | ~55 |
| `crates/mmforge-core/src/lsm/tests.rs` | New | ~120 |
| `crates/mmforge-core/src/lsm/mod.rs` | New | ~35 |
| `crates/mmforge-core/src/lib.rs` | +1 line | `pub mod lsm;` |
| `crates/mmforge-cli/src/main.rs` | Rewrite | ~340 |
| `crates/mmforge-cli/Cargo.toml` | +2 deps | serde_json, glam |

## 5. Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 280 tests pass (50+79+39+6+12+5+89) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 286 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| CLI `mmforge info/validate/convert/benchmark` | All smoke-test pass |

| Crate | Prev | Current | Δ |
|-------|------|---------|---|
| mmforge-core | 71 | **79** | +8 LSM |
| mmforge-cli | — | — | full rewrite |

## 6. Known Limitations & Risks

- **IGES/DXF/STEP CLI parsing** are stubs (return empty LSM models).  Real parsing requires linking `mmforge-format-*` crates — deferred until after `.lsm` format stabilises.
- **`.lsm` reading from CLI** does not yet have a `mmforge lsm-info` command.  The `info` command detects source formats only.
- **Compression is trait-only** — no LZ4/ZSTD codec implemented yet.  The `.lsmc` format is a placeholder.
- **Drawing2D geometry** is not serialised in v1 (`Geometry::Drawing2D` writes a zero count; reader reconstructs an empty `Drawing2DGeometry`).
- **No mesh deduplication** — each geometry is stored independently.

## 7. Next Steps (Phase 7)

- Add CLI `lsm-info` and `lsm-validate` for `.lsm` files
- LZ4 or ZSTD compression codec for `.lsmc`
- Golden file regression tests with committed `.lsm` fixtures
- Schema migration path (v1 → v2)

## 8. Round 1 Fixes (2026-07-03) — commit `4d5dbd1`

### Metadata units round-trip

**Bug**: Units were written in the Header section but the reader ignored them,
and the Metadata section didn't carry units at all.

**Fix**: Moved `units` field from Header section to Metadata section as the
first field.  Writer writes it first in metadata, reader restores it to
`Metadata.units`.  Added `metadata_units_preserved` test (core: 79 → 80).

### CLI STL detection

**Bug**: CLI's `parse_stl` used a weak heuristic: `starts_with("solid") &&
!contains("facet")`.  Binary STL files without "solid" header, or with
"facet" bytes in triangle data, were misidentified.

**Fix**: Ported the bridge's robust two-step disambiguation:
- `binary_length_valid()` — checks `file_size == 84 + tri_count * 50 (±80B)`
- `is_probably_ascii()` — case‑insensitive `starts_with("solid")`
- Priority: binary length check first, ASCII fallback second

Verified with a programmatically‑generated binary STL fixture: `info`,
`validate`, `convert`, `benchmark` all pass.

### CLI exit code

**Bug**: `mmforge info` printed error messages but returned exit code 0 on
parse failure (`error: read: No such file ...` + exit 0).

**Fix**: `cmd_info` calls `std::process::exit(1)` on `detect_and_parse` error.

### Cargo.lock

Previously uncommitted; now committed alongside the fixes.
