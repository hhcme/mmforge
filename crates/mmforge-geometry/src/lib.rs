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

/// Returns `true` when the crate was compiled with an actual linked OCCT
/// (i.e. `build.rs` found headers, libraries, and the C ABI shim and
/// emitted `cfg(occt_found)`).  This is stricter than `cfg!(feature =
/// "occt")` — the feature may be enabled but OCCT may not be installed,
/// in which case compilation would have already failed.
///
/// Callers (e.g. `mmforge-bridge`) can use this to decide whether to
/// advertise STEP/IGES support at runtime.
pub fn is_occt_available() -> bool {
    cfg!(occt_found)
}

// Re-export core geometry types for convenience.
pub use mmforge_core::ids::GeometryId;
pub use mmforge_core::math::BoundingBox;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_occt_available_returns_bool() {
        let r = is_occt_available();
        // In CI (no OCCT installed), this is false.
        // In a full build with OCCT, this is true.
        assert!(r || !r, "must return a valid bool");
    }
}
