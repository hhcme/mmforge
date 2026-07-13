# Generated Test Models

## License
MIT OR Apache-2.0 (same as MMForge core). No unlicensed binaries. All models
generated deterministically from source; no external data incorporated.

## Generator
`mmforge generate-large-model` — deterministic procedural geometry generator.
Source: `crates/mmforge-cli/src/gen_large_model.rs`
PRNG: PCG-style LCG + xorshift-multiply (zero external dependencies).

## Models
| File | Triangles | Seed | Levels | Date | Hash (SHA-256) |
|------|-----------|------|--------|------|-----------------|
| (to be generated) | ~370,000 (default) | 42 | 5 | 2026-07-13 | (run `mmforge generate-large-model` to produce) |

Note: Generated models are NOT committed to the repository. The generator is
deterministic — identical seed + levels produce identical output on any machine.
Run `docs/scripts/perf-baseline.sh` to reproduce.

## Reproducibility
```bash
cargo build --release -p mmforge-cli
./target/release/mmforge generate-large-model \
    --output /tmp/mmforge_model.lsm \
    --triangles 100000 --seed 42 --levels 5
sha256sum /tmp/mmforge_model.lsm  # identical hash every time with same params
```
