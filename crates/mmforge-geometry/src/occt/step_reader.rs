//! Safe wrapper for OCCT `STEPControl_Reader`.
//!
//! This module provides:
//!
//! - [`read_step_file`] — reads a STEP file and returns an opaque
//!   [`StepData`] handle.
//! - [`extract_shapes`] — extracts shape metadata from the parsed data.
//!
//! When the `occt` feature is disabled, all functions return
//! [`OcctError::NotAvailable`].

use super::OcctError;
use super::shape::OcctShapeHandle;
use std::path::Path;

/// Opaque container for parsed STEP data.
///
/// When OCCT is enabled, this holds the `STEPControl_Reader` and
/// the transferred `TopoDS_Shape` roots.  Without OCCT, it's a stub.
#[derive(Debug)]
pub struct StepData {
    /// Parsed shape handles with metadata.
    pub shapes: Vec<OcctShapeHandle>,
    /// Transfer status messages from OCCT.
    pub transfer_messages: Vec<String>,
}

/// Read a STEP file and return parsed data.
///
/// # Errors
///
/// Returns [`OcctError::NotAvailable`] if the `occt` feature is not enabled.
/// Returns [`OcctError::StepError`] if OCCT cannot read the file.
pub fn read_step_file(path: &Path) -> Result<StepData, OcctError> {
    #[cfg(feature = "occt")]
    {
        occt_read_step(path)
    }

    #[cfg(not(feature = "occt"))]
    {
        let _ = path;
        Err(OcctError::NotAvailable(
            "STEP parsing requires the occt feature — \
             compile with --features occt"
                .to_string(),
        ))
    }
}

/// Extract shape metadata from parsed STEP data.
pub fn extract_shapes(data: &StepData) -> Result<&[OcctShapeHandle], OcctError> {
    Ok(&data.shapes)
}

/// Real OCCT parsing.  Only compiled when `occt` feature is enabled.
#[cfg(feature = "occt")]
fn occt_read_step(path: &Path) -> Result<StepData, OcctError> {
    // ------------------------------------------------------------------
    // Phase 1 implementation: this is where the real OCCT FFI calls go.
    //
    // The flow (per development plan §4.2):
    //
    // 1. Create STEPControl_Reader.
    // 2. Read file → collect transfer status.
    // 3. Transfer roots → get TopoDS_Shape.
    // 4. If XDE enabled, read assembly/product/color/layer.
    // 5. Traverse TopoDS_Shape tree:
    //    - TopAbs_SOLID → Solid node
    //    - TopAbs_SHELL → Shell metadata
    //    - TopAbs_FACE  → Face/BRep info
    // 6. Compute bounding box.
    // 7. Return StepData with shape handles.
    //
    // For now this is a placeholder that returns an empty result.
    // The actual FFI will be implemented in a subsequent goal.
    // ------------------------------------------------------------------

    let _ = path;
    Err(OcctError::NotAvailable(
        "OCCT FFI not yet implemented — this is a placeholder for the \
         STEPControl_Reader integration (see docs/geometry/occt-binding.md)"
            .to_string(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::occt::shape::ShapeType;
    use mmforge_core::math::BoundingBox;

    /// Without the `occt` feature, `read_step_file` returns `NotAvailable`
    /// with a message about the missing feature.
    #[cfg(not(feature = "occt"))]
    #[test]
    fn read_step_file_without_occt_errors() {
        let path = Path::new("/tmp/test.step");
        let result = read_step_file(path);
        assert!(result.is_err());
        match result.unwrap_err() {
            OcctError::NotAvailable(msg) => assert!(msg.contains("occt feature")),
            other => panic!("expected NotAvailable, got: {other}"),
        }
    }

    /// With the `occt` feature enabled, the placeholder still returns
    /// `NotAvailable` because the real FFI is not yet implemented.
    /// The message must indicate this is a placeholder.
    #[cfg(feature = "occt")]
    #[test]
    fn read_step_file_occt_placeholder_returns_not_available() {
        let path = Path::new("/tmp/test.step");
        let result = read_step_file(path);
        assert!(result.is_err());
        match result.unwrap_err() {
            OcctError::NotAvailable(msg) => {
                assert!(
                    msg.contains("OCCT FFI not yet implemented")
                        || msg.contains("STEPControl_Reader"),
                    "unexpected NotAvailable message: {msg}"
                );
            }
            other => panic!("expected NotAvailable, got: {other}"),
        }
    }

    #[test]
    fn shape_handle_stub() {
        let handle = OcctShapeHandle::stub(
            "test_box",
            BoundingBox::new(glam::Vec3::ZERO, glam::Vec3::new(1.0, 1.0, 1.0)),
            ShapeType::Solid,
        );
        assert_eq!(handle.label, "test_box");
        assert_eq!(handle.shape_type, ShapeType::Solid);
        assert!(handle.bounds.is_valid());
    }
}
