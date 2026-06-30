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

/// Read a STEP file and tessellate all root shapes in one pass.
///
/// Returns both the parsed data and a [`TessellationRegistry`] mapping
/// `GeometryId` → `TessellatedMeshData`.  The tessellation happens
/// while the OCCT reader and shapes are still alive, so no shape
/// pointers escape.
///
/// Uses [`TessellationQuality::Standard`] deflection.
pub fn read_step_file_with_tessellation(
    path: &Path,
) -> Result<(StepData, crate::tessellation::TessellationRegistry), OcctError> {
    #[cfg(occt_found)]
    {
        occt_read_step_with_tessellation(path)
    }

    #[cfg(not(occt_found))]
    {
        let _ = path;
        Err(OcctError::NotAvailable(
            "tessellation requires the occt feature and a linked shim".to_string(),
        ))
    }
}

/// Real OCCT read + tessellate.  Only when `occt_found`.
#[cfg(occt_found)]
fn occt_read_step_with_tessellation(
    path: &Path,
) -> Result<(StepData, crate::tessellation::TessellationRegistry), OcctError> {
    use crate::occt::adapter::{StepReaderAdapter, TessellatedMesh};
    use crate::tessellation::{TessellationQuality, TessellationRegistry};
    use mmforge_core::ids::GeometryId;

    let mut reader = StepReaderAdapter::new()?;
    reader.read_file(path)?;
    reader.transfer_roots()?;

    let count = reader.root_count();
    let mut shapes = Vec::with_capacity(count);
    let mut registry = TessellationRegistry::new();

    for i in 0..count {
        let handle = reader.get_root(i)?;
        let fallback = format!("Shape_{i}");
        let shape_handle = handle.to_handle(&fallback)?;

        // Tessellate while the reader and shape are still alive.
        let quality = TessellationQuality::Standard;
        let deflection = quality.linear_deflection(&shape_handle.bounds) as f64;
        let mesh = TessellatedMesh::tessellate(&reader, &handle, deflection)?;

        let geom_id = GeometryId::new(i as u32);
        registry.insert(
            geom_id,
            crate::tessellation::TessellatedMeshData {
                positions: mesh.positions().to_vec(),
                normals: mesh.normals().to_vec(),
                indices: mesh
                    .indices()
                    .iter()
                    .flat_map(|t| [t[0] as u32, t[1] as u32, t[2] as u32])
                    .collect(),
                bounds: mesh.bounds(),
            },
        );

        shapes.push(shape_handle);
    }

    let messages = reader.warnings();

    Ok((
        StepData {
            shapes,
            transfer_messages: messages,
        },
        registry,
    ))
}

/// Real OCCT parsing.  Only compiled when `occt_found` is set (real shim linked).
///
/// Uses `StepReaderAdapter` to read a STEP file via STEPCAFControl_Reader,
/// transfer roots, and extract shape metadata (bbox, label, type).
#[cfg(occt_found)]
fn occt_read_step(path: &Path) -> Result<StepData, OcctError> {
    use super::adapter::StepReaderAdapter;

    let mut reader = StepReaderAdapter::new()?;
    reader.read_file(path)?;
    reader.transfer_roots()?;

    let count = reader.root_count();
    let mut shapes = Vec::with_capacity(count);
    for i in 0..count {
        let handle = reader.get_root(i)?;
        let fallback = format!("Shape_{i}");
        shapes.push(handle.to_handle(&fallback)?);
    }

    let messages = reader.warnings();

    Ok(StepData {
        shapes,
        transfer_messages: messages,
    })
}

/// Stub when `occt` feature is on but shim is not linked.
#[cfg(all(feature = "occt", not(occt_found)))]
fn occt_read_step(_path: &Path) -> Result<StepData, OcctError> {
    Err(OcctError::NotAvailable(
        "OCCT shim not linked — set MMFORGE_SHIM_DIR to the pre-built shim \
         library, with OCCT_INCLUDE_DIR + OCCT_LIB_DIR for OCCT headers/libs"
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

    /// With the `occt` feature but no shim (`occt_found` not set),
    /// read_step_file returns `NotAvailable` because the adapter is a stub.
    #[cfg(feature = "occt")]
    #[cfg(not(occt_found))]
    #[test]
    fn read_step_file_occt_stub_returns_not_available() {
        let path = Path::new("/tmp/test.step");
        let result = read_step_file(path);
        assert!(result.is_err());
        match result.unwrap_err() {
            OcctError::NotAvailable(msg) => {
                assert!(
                    msg.contains("shim") || msg.contains("OCCT"),
                    "unexpected NotAvailable message: {msg}"
                );
            }
            other => panic!("expected NotAvailable, got: {other}"),
        }
    }

    /// E2E test with a real STEP fixture — only runs when `occt_found`
    /// is set (real shim linked).  Reads a 37KB STEP file, transfers
    /// roots, and verifies bbox/label extraction.
    ///
    /// Uses `testdata/PQ-04909-A.STEP` (committed to the repo).
    /// Fails if the fixture is missing — this is not a skip.
    #[cfg(occt_found)]
    #[test]
    fn read_step_file_e2e_real_occt() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("PQ-04909-A.STEP");

        assert!(
            fixture.exists(),
            "STEP fixture missing at {}. Run: cp testfile/PQ-04909-A.STEP \
             crates/mmforge-geometry/testdata/",
            fixture.display(),
        );

        let data = read_step_file(&fixture).expect("read_step_file should succeed with real OCCT");

        // Must have at least one root shape.
        assert!(
            !data.shapes.is_empty(),
            "expected at least one root shape from STEP file"
        );

        // Every shape must have a valid bounding box.
        for (i, shape) in data.shapes.iter().enumerate() {
            assert!(
                shape.bounds.is_valid(),
                "shape {i} ('{}') has invalid bbox: {:?}",
                shape.label,
                shape.bounds,
            );
        }

        // At least one shape should have a non-default label.
        let has_label = data
            .shapes
            .iter()
            .any(|s| !s.label.is_empty() && !s.label.starts_with("Shape_"));
        // Labels may be empty if the STEP file has no product names,
        // so this is a soft check.
        if !has_label {
            eprintln!(
                "NOTE: no product-name labels found in STEP file \
                 ({} shapes, all use fallback labels)",
                data.shapes.len()
            );
        }

        eprintln!(
            "E2E: read {} shapes from STEP file, {} transfer messages",
            data.shapes.len(),
            data.transfer_messages.len(),
        );
        for (i, shape) in data.shapes.iter().enumerate() {
            eprintln!(
                "  [{i}] type={:?} label='{}' bbox={:?}",
                shape.shape_type, shape.label, shape.bounds,
            );
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
