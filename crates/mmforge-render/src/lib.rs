//! MMForge Render — platform-neutral RenderPacket generation.
//!
//! This crate converts the LSM runtime model into a `RenderPacket` that
//! any GPU backend (Metal, D3D12, Vulkan) can consume.

pub mod builder;
pub mod camera;
pub mod draw2d;
pub mod frustum;
pub mod lod;
pub mod memory;
pub mod packet;
pub mod spatial2d;
pub mod streaming;

pub use builder::build_render_packet;
pub use camera::OrbitCamera;
pub use frustum::Frustum;
pub use lod::{LodLevel, LodSelection, LodSelector};
pub use memory::{MemoryBudget, gpu_mesh_memory_bytes};
pub use packet::{RenderBatch, RenderMaterial, RenderMesh, RenderPacket, RenderStats};
pub use streaming::{RenderChunk, StreamingPacket};
