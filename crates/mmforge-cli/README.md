# mmforge-cli

Command-line interface for MMForge model inspection and conversion.

## Current Commands

```
mmforge version    Display version and build information
```

## Planned Commands (Phase 7)

```
mmforge info       Detect format and print model metadata/stats
mmforge validate   Parse and validate references, topology, warnings
mmforge convert    Convert between formats via LSM runtime model
mmforge benchmark  Measure parse/tessellate/render-packet timings
```

## Usage

```bash
cargo run --bin mmforge -- version
```
