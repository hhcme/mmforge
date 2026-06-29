//! MMForge Geometry — B-Rep handles, tessellation adapter, and OCCT FFI.
//!
//! This crate bridges the core model to heavy geometry operations.
//! In Phase 0 it only re-exports core math types; OCCT integration
//! will arrive in Phase 1.

pub mod brep;
pub mod tessellation;

// Re-export core geometry types for convenience.
pub use mmforge_core::ids::GeometryId;
pub use mmforge_core::math::BoundingBox;
