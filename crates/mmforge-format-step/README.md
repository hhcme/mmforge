# mmforge-format-step

STEP (ISO 10303-21) file parser for MMForge.

## Role

Parses STEP AP203/AP214 files into the LSM runtime model. Delegates to OCCT's `STEPControl_Reader` for actual B-Rep parsing.

## Feature Flags

| Feature | Default | Description |
|---------|---------|-------------|
| `occt`  | off     | Enable OCCT-backed STEP parsing. Without it, `detect()` works but `parse()` returns an error. |

CI runs without the `occt` feature, so no OCCT installation is required for standard development.

## Architecture

- `detect.rs` — format detection via header magic (`ISO-10303-21;`)
- `parser.rs` — `FormatParser` trait implementation
- OCCT details are hidden in `mmforge-geometry::occt`

## Usage

```rust
use mmforge_format_step::StepParser;
use mmforge_core::parser::FormatParser;
use std::path::Path;

let parser = StepParser::new();

// Format detection (always works)
let header = std::fs::read(Path::new("model.step")).unwrap();
let detection = parser.detect(&header[..4096.min(header.len())], Path::new("model.step"));

// Parsing (requires occt feature)
let result = parser.parse(Path::new("model.step"));
```
