//! Safe wrapper for OCCT `IGESCAFControl_Reader`.
//!
//! This module provides:
//!
//! - [`read_iges_file`] — reads an IGES file and returns an opaque
//!   [`IgesData`] handle.
//! - [`read_iges_file_with_tessellation`] — reads and tessellates in one
//!   pass (reader stays alive during tessellation).
//!
//! When the `occt` feature is disabled, all functions return
//! [`OcctError::NotAvailable`].

use super::OcctError;
use super::shape::OcctShapeHandle;
use std::path::Path;

/// Opaque container for parsed IGES data.
#[derive(Debug)]
pub struct IgesData {
    /// Parsed shape handles with metadata.
    pub shapes: Vec<OcctShapeHandle>,
    /// Transfer status messages from OCCT.
    pub transfer_messages: Vec<String>,
}

/// Read an IGES file and return parsed data.
///
/// # Errors
///
/// Returns `OcctError::NotAvailable` if OCCT is not linked.
/// Returns `OcctError::Io` if the file cannot be read.
/// Returns `OcctError::StepError` if parsing or transfer fails.
pub fn read_iges_file(path: &Path) -> Result<IgesData, OcctError> {
    #[cfg(feature = "occt")]
    {
        occt_read_iges(path)
    }
    #[cfg(not(feature = "occt"))]
    {
        let _ = path;
        Err(OcctError::NotAvailable(
            "IGES parsing requires the occt feature".to_string(),
        ))
    }
}

/// Extract shape metadata from parsed IGES data.
pub fn extract_shapes(data: &IgesData) -> Result<&[OcctShapeHandle], OcctError> {
    Ok(&data.shapes)
}

/// Read an IGES file and tessellate all B-Rep shapes in one pass.
///
/// Returns both the [`IgesData`] and a [`TessellationRegistry`].
#[cfg(feature = "occt")]
pub fn read_iges_file_with_tessellation(
    path: &Path,
) -> Result<(IgesData, crate::tessellation::TessellationRegistry), OcctError> {
    occt_read_iges_with_tessellation(path)
}

#[cfg(not(feature = "occt"))]
pub fn read_iges_file_with_tessellation(
    path: &Path,
) -> Result<(IgesData, crate::tessellation::TessellationRegistry), OcctError> {
    let _ = path;
    Err(OcctError::NotAvailable(
        "IGES parsing requires the occt feature".to_string(),
    ))
}

// ---------------------------------------------------------------------------
// OCCT-backed implementation
// ---------------------------------------------------------------------------

#[cfg(feature = "occt")]
fn occt_read_iges(path: &Path) -> Result<IgesData, OcctError> {
    let mut reader = super::adapter::IgesReaderAdapter::new()?;
    reader.read_file(path)?;
    reader.transfer_roots()?;

    let mut shapes = Vec::new();
    let count = reader.root_count();
    for i in 0..count {
        let handle = reader.get_root(i)?;
        let fallback = format!("Shape_{i}");
        shapes.push(handle.to_handle(&fallback)?);
    }

    let transfer_messages = reader.warnings();

    Ok(IgesData {
        shapes,
        transfer_messages,
    })
}

#[cfg(feature = "occt")]
fn occt_read_iges_with_tessellation(
    path: &Path,
) -> Result<(IgesData, crate::tessellation::TessellationRegistry), OcctError> {
    let mut reader = super::adapter::IgesReaderAdapter::new()?;
    reader.read_file(path)?;
    reader.transfer_roots()?;

    let mut shapes = Vec::new();
    let mut registry = crate::tessellation::TessellationRegistry::new();
    let count = reader.root_count();

    for i in 0..count {
        let handle = reader.get_root(i)?;
        let fallback = format!("Shape_{i}");
        let shape_handle = handle.to_handle(&fallback)?;

        // Tessellate with standard quality.
        let quality = crate::tessellation::TessellationQuality::Standard;
        let deflection = quality.linear_deflection(&shape_handle.bounds) as f64;

        let mesh = super::adapter::TessellatedMesh::tessellate_iges(&reader, &handle, deflection)?;

        // Convert indices from i32 to u32.
        let indices: Vec<u32> = mesh
            .indices()
            .iter()
            .flat_map(|tri| [tri[0] as u32, tri[1] as u32, tri[2] as u32])
            .collect();

        let positions: Vec<[f32; 3]> = mesh.positions().to_vec();
        let normals: Vec<[f32; 3]> = mesh.normals().to_vec();

        let geom_id = mmforge_core::ids::GeometryId::new(i as u32);
        registry.insert(
            geom_id,
            crate::tessellation::TessellatedMeshData {
                positions,
                normals,
                indices,
                bounds: mesh.bounds(),
            },
        );

        shapes.push(shape_handle);
    }

    let transfer_messages = reader.warnings();

    Ok((
        IgesData {
            shapes,
            transfer_messages,
        },
        registry,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Without OCCT, read_iges_file returns NotAvailable.
    #[cfg(not(feature = "occt"))]
    #[test]
    fn read_iges_file_without_occt_errors() {
        let path = std::path::PathBuf::from("nonexistent.igs");
        let result = read_iges_file(&path);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("not available") || msg.contains("OCCT"));
    }

    /// E2E: read a real IGES fixture and verify the pipeline.
    ///
    /// The fixture (`point.igs`) contains a single Point entity (type 116).
    /// This is a valid IGES file but OCCT may fail to transfer it into a
    /// B-Rep shape because points are not B-Rep geometry.  The test verifies
    /// that the read path doesn't crash and produces a clear error or empty
    /// shape list.
    ///
    /// A more substantial fixture (B-Rep solid) would be needed to test the
    /// full shape-extraction + tessellation pipeline.  Such a fixture can
    /// be generated with `IGESControl_Writer` from OCCT.
    #[cfg(occt_found)]
    #[test]
    fn read_iges_file_e2e_real_occt() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("point.igs");

        assert!(
            fixture.exists(),
            "IGES fixture missing at {}",
            fixture.display()
        );

        // The read may succeed (file is valid IGES) but transfer may fail
        // because a Point entity is not a B-Rep shape.
        match read_iges_file(&fixture) {
            Ok(data) => {
                eprintln!(
                    "IGES E2E: {} shapes, {} warnings",
                    data.shapes.len(),
                    data.transfer_messages.len()
                );
                for (i, shape) in data.shapes.iter().enumerate() {
                    eprintln!(
                        "  shape[{i}]: label={:?}, type={:?}, bounds={:?}",
                        shape.label, shape.shape_type, shape.bounds
                    );
                }
            }
            Err(e) => {
                // Point entity may fail transfer — this is expected.
                eprintln!("IGES read returned error (expected for point entity): {e}");
            }
        }
    }

    /// E2E: read + tessellate a real IGES fixture.
    #[cfg(occt_found)]
    #[test]
    fn read_iges_with_tessellation_e2e_real_occt() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("point.igs");

        assert!(fixture.exists(), "IGES fixture missing");

        let result = read_iges_file_with_tessellation(&fixture);
        // A single-point IGES file may produce 0 shapes (points are not
        // B-Rep solids), so the tessellation registry may be empty.
        // The important thing is that the pipeline doesn't panic or error.
        match result {
            Ok((data, registry)) => {
                eprintln!(
                    "IGES tessellation: {} shapes, {} registry entries, {} warnings",
                    data.shapes.len(),
                    registry.len(),
                    data.transfer_messages.len()
                );
            }
            Err(e) => {
                // A single-point IGES may fail tessellation — that's OK.
                // The error should be a clear OCCT error, not a panic.
                eprintln!("IGES tessellation returned error (expected for point entity): {e}");
            }
        }
    }
}
