# mmforge-core

Core types, error model, parser traits, and the LSM runtime model for MMForge.

## Role

This is the bottom of the dependency graph. Every other MMForge crate depends on `mmforge-core`. It contains no platform, GPU, or OCCT code.

## Modules

| Module | Purpose |
|--------|---------|
| `version` | `Version` type and `VERSION` constant |
| `error` | Unified `Error` enum and `Result` alias |
| `ids` | Typed identifiers: `NodeId`, `GeometryId`, `MaterialId`, `TextureId`, `EntityId` |
| `math` | `BoundingBox` and `Vec3A` re-export from glam |
| `model` | LSM runtime model: `LsmModel`, `SceneTree`, `Node`, `Geometry`, `Material`, `ParseOutput`, `ParseWarning`, `ParseStats` |
| `parser` | `FormatParser` trait, `DetectionResult`, `DetectionConfidence` |

## Usage

```rust
use mmforge_core::{Version, VERSION};
use mmforge_core::model::LsmModel;

let model = LsmModel::empty("STEP");
println!("version: {VERSION}");
```
