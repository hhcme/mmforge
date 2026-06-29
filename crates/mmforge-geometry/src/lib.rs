//! MMForge Geometry — B-Rep handles, tessellation adapter, and OCCT FFI.
//!
//! This crate bridges the core model to heavy geometry operations.
//! OCCT integration is feature-gated: compile with `--features occt`
//! to enable real STEP/IGES parsing via OpenCASCADE.
//!
//! # Safety
//!
//! All `unsafe` OCCT FFI is confined to the [`occt`] module.  The rest
//! of the crate is safe Rust.

pub mod brep;
pub mod occt;
pub mod tessellation;

// Re-export core geometry types for convenience.
pub use mmforge_core::ids::GeometryId;
pub use mmforge_core::math::BoundingBox;
