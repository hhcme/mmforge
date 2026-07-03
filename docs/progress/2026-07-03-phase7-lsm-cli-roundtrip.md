# Phase 7 Round 2: LSM CLI Round-Trip

**Date**: 2026-07-03
**Scope**: Make `.lsm` a first-class CLI input format, complete the
`convert → .lsm → info/validate/benchmark` round-trip, add 8 CLI integration
tests covering binary STL→LSM, LSM reading, error handling, and JSON stability.

## Changes

### 1. `.lsm` as first-class CLI input

`detect_and_parse` now recognises `.lsm` files by:
- Extension `.lsm` → parse as LSM
- Magic bytes `LSMD` (for extension-less files)

New `parse_lsm()` function:
```rust
fn parse_lsm(path) -> Result<Parsed, String> {
    let model = mmforge_core::lsm::read_lsm(&mut reader)?;
    Ok(Parsed { model, warnings: vec![] })
}
```

No new subcommands — `info`, `validate`, `benchmark` all work transparently
with `.lsm` files through the same `detect_and_parse` dispatch.

### 2. Complete round-trip

```text
binary STL ──convert──► .lsm ──info──► source_format=STL, nodes=2, tris=3
                            ──validate──► PASS
                            ──benchmark──► parse timing
```

The `convert` command writes `.lsm` v1, and `info/validate/benchmark`
read it back with identical statistics (triangle count, node count, bounds).

### 3. CLI integration tests (8 new)

| Test | Category |
|------|----------|
| `detect_ascii_stl` | Source file detection |
| `detect_binary_stl` | Binary STL with 2 triangles |
| `binary_stl_to_lsm_round_trip` | STL→convert→.lsm→info→validate→benchmark |
| `lsm_info_json_output` | JSON output stability |
| `lsm_validate_clean` | No validation issues on well-formed LSM |
| `lsm_bad_magic_error` | `XXXX` magic → error message |
| `lsm_high_version_error` | Version 99 → "unsupported version" error |
| `unknown_file_falls_back_to_stl` | Non-STL file without extension → STL parse error |

### 4. Error handling

| Error condition | Result |
|----------------|--------|
| Bad magic in `.lsm` | `error: lsm read: bad magic` + exit 1 |
| Unsupported version | `error: lsm read: unsupported version 99` + exit 1 |
| Missing core section | `error: lsm read: missing core section 0x01 (Header)` + exit 1 |

All error paths return non-zero exit codes through `detect_and_parse`'s
`Err(e) → eprintln!("error: {e}"); exit(1)`.

## Files Changed

| File | Change |
|------|--------|
| `crates/mmforge-cli/src/main.rs` | Add `.lsm` detection + `parse_lsm()` + 8 tests + `Debug` on `Parsed` |
| `crates/mmforge-cli/Cargo.toml` | Add `tempfile` dev-dependency |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 289 tests pass (50+8+80+39+6+12+5+89) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 295 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |

| Crate | Prev | Current | Δ |
|-------|------|---------|---|
| mmforge-cli (tests) | 0 | **8** | +8 |
| Total | 281 | **289** |

### Manual smoke test

```console
$ mmforge convert test_binary.stl -o test.lsm
wrote test.lsm (729 bytes)

$ mmforge info test.lsm
file    : test.lsm
format  : STL
nodes   : 2
geoms   : 1
triangles: 3
bounds  : [0.000,0.000,0.000] – [1.000,1.000,1.000]

$ mmforge validate test.lsm
PASS  test.lsm

$ mmforge benchmark test.lsm -i 3
benchmark: test.lsm
  iterations: 3
  parse (ms): min=0.0  max=0.1  median=0.0  avg=0.0
```

## Known Limitations & Risks

- **IGES/DXF/STEP source parsing** are still stubs — their round-trip
  produces near-empty `.lsm` files.
- **LSM metadata** (units, author, custom keys) not yet surfaced in CLI output.
- **No LSM diff or golden file regression** — a committed `.lsm` fixture would
  help detect format drift.

## Next Steps (Phase 7)

- LSM `lsm-info` `--format json` with full metadata output
- Committed golden `.lsm` fixtures from known source files
- LZ4/ZSTD `.lsmc` compression codec
