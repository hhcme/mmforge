# Phase 7 Round 4: `.lsmc` Compressed LSM Format

**Date**: 2026-07-03
**Scope**: Implement `.lsmc` compressed LSM format using zstd, with CLI support
for transparent read and `--compress zstd` write.

## Format Design

```
┌──────────────────────────────┐
│ Magic: "LSMC" (4 bytes)      │
│ Version: u16 (1)             │
│ Flags: u16 (0)               │
│ Compression method: u8        │ 1 = zstd
│ Reserved: [u8; 7]            │
│ Uncompressed size: u64       │
│ Compressed payload: [u8; N]  │  zstd-compressed `.lsm` v1 byte stream
└──────────────────────────────┘
```

Header: 24 bytes.  Payload is a complete `.lsm` v1 byte stream compressed
with zstd (compression level 0 = default).

## Implementation

### `crates/mmforge-core/src/lsm/lsmc.rs`

| Function | Purpose |
|----------|---------|
| `write_lsmc(model, w)` | Serialize model to `.lsm` bytes, zstd-compress, write header + payload |
| `read_lsmc_decompressed(r)` | Read header (validate magic/version/method), decompress, return `.lsm` bytes |

Error variants: `BadMagic`, `BadVersion`, `UnknownMethod`, `SizeMismatch`,
`DecompressError`.  Uncompressed size is capped at 1 GiB (plausibility check).

### CLI integration

**`convert`**: `--compress zstd` flag or `.lsmc` output extension auto-selects
compressed output.

```console
$ mmforge convert test.stl --compress zstd -o test.lsmc
wrote test.lsmc (198 bytes)
```

**`info/validate/benchmark`**: Transparent `.lsmc` reading — `detect_and_parse`
detects `LSMC` magic at file start, decompresses, then feeds to `.lsm` reader.

### Dependencies

**zstd 0.13** (MIT OR Apache-2.0) — compatible with `mmforge-core`'s license.
Added to workspace `Cargo.toml` and `mmforge-core/Cargo.toml`.

## Tests

### Unit tests (6 new in `lsmc.rs`)

| Test | Category |
|------|----------|
| `round_trip_compressed` | Write → decompress → read → assert fields |
| `bad_magic_rejected` | `XXXX` → "bad lsmc magic" |
| `unknown_method_rejected` | Method byte 99 → "unknown compression method" |
| `truncated_payload_error` | Short payload with inflated expected size |
| `size_mismatch_error` | Corrupted `uncompressed_size` field |
| `compressed_smaller_than_uncompressed` | Verify zstd actually compressed |

### CLI integration tests (4 new)

| Test | Purpose |
|------|---------|
| `convert_to_lsmc_then_info_exit_zero` | STL → LSMC → info (format=STL, tris=1) |
| `convert_to_lsmc_then_validate_json` | LSMC → validate JSON → "valid": true |
| `lsmc_bad_magic_exit_nonzero` | `XXXX.lsmc` → non-zero exit with error |
| `source_to_lsmc_to_info_json_round_trip` | STL(2 tris) → LSMC → info JSON (triangle_count=2, bounds present) |

## Files Changed

| File | Action |
|------|--------|
| `Cargo.toml` (root) | Add `zstd = "0.13"` workspace dep |
| `crates/mmforge-core/Cargo.toml` | Add `zstd` dep |
| `crates/mmforge-core/src/lsm/lsmc.rs` | New — writer, reader, 6 tests |
| `crates/mmforge-core/src/lsm/mod.rs` | Add `pub mod lsmc;` |
| `crates/mmforge-cli/src/main.rs` | `--compress zstd`, `.lsmc` detection, LSMC-aware `parse_lsm` |
| `crates/mmforge-cli/tests/integration.rs` | 4 LSMC integration tests |
| `docs/progress/2026-07-03-phase7-lsm-golden-compat.md` | Fix outdated limitation |

## Verification

| Command | Result |
|---------|--------|
| `cargo fmt --all --check` | Pass |
| `cargo test --workspace --locked` | 319 tests pass (50+8+13+97+39+6+12+5+89) |
| `cargo clippy --workspace -- -D warnings` | 0 warnings |
| `cargo clippy --workspace --tests -- -D warnings` | 0 warnings |
| `OCCT_INCLUDE_DIR=... cargo test --workspace --features occt` | 325 tests pass |
| `cargo bench -p mmforge-format-dxf --no-run` | Compiles + links |
| Working tree | Clean |

| Test Delta | Prev | Current | Δ |
|------------|------|---------|---|
| Core (incl LSM) | 91 | **97** | +6 LSMC |
| CLI integration | 9 | **13** | +4 LSMC |
| Total locked | 309 | **319** | +10 |

## Known Limitations

- Only zstd compression method (method=1) is implemented.  LZ4 (method=2) not yet.
- No streaming decompression — entire payload is loaded into memory.
- No incremental compressed write; entire `.lsm` is serialized before compression.
- Existing `.lsm` files remain fully backward compatible.

## Next Steps

- LZ4 compression codec as alternative for speed-oriented workflows.
- Streaming `.lsmc` writer for large models (compress sections as they are written).
- Docker/CI `.lsmc` fixture generation and comparison.
