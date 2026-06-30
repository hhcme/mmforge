//! MMForge Render — platform-neutral RenderPacket generation.
//!
//! This crate converts the LSM runtime model into a `RenderPacket` that
//! any GPU backend (Metal, D3D12, Vulkan) can consume.

pub mod builder;
pub mod camera;
pub mod packet;

pub use builder::build_render_packet;
pub use camera::OrbitCamera;
pub use packet::{RenderBatch, RenderMaterial, RenderMesh, RenderPacket, RenderStats};
