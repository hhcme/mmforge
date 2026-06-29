# mmforge-render

Platform-neutral `RenderPacket` generation, batching, camera model, and material mapping for MMForge.

## Role

This crate converts the LSM runtime model into a `RenderPacket` that any GPU backend (Metal, D3D12, Vulkan) can consume. It contains no platform-specific types.

## Modules

| Module | Purpose |
|--------|---------|
| `packet` | `RenderPacket`, `RenderMesh`, `RenderMaterial`, `RenderInstance`, `RenderBatch`, `RenderStats` |
| `camera` | `OrbitCamera` with rotate/zoom/pan/fit operations |

## Key Design

- `RenderPacket` is the single handoff between Rust and any platform renderer.
- It contains meshes, materials, instances, batches, bounds, and stats.
- The macOS Metal adapter consumes `RenderPacket` — it does not build it.
- `RenderPacket::to_debug_json()` produces inspectable JSON output for CLI debugging.
