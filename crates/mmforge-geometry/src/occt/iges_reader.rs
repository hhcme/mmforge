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
// OCCT-backed implementation (only when real shim is linked)
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
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

#[cfg(occt_found)]
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

// ---------------------------------------------------------------------------
// Stub implementation (occt feature requested, but no verified shim found)
// ---------------------------------------------------------------------------

#[cfg(all(feature = "occt", not(occt_found)))]
fn occt_read_iges(_path: &Path) -> Result<IgesData, OcctError> {
    Err(OcctError::NotAvailable(
        "OCCT shim not linked — set MMFORGE_SHIM_DIR to the pre-built shim \
         library, with OCCT_INCLUDE_DIR + OCCT_LIB_DIR for OCCT headers/libs"
            .to_string(),
    ))
}

#[cfg(all(feature = "occt", not(occt_found)))]
fn occt_read_iges_with_tessellation(
    _path: &Path,
) -> Result<(IgesData, crate::tessellation::TessellationRegistry), OcctError> {
    Err(OcctError::NotAvailable(
        "OCCT shim not linked — set MMFORGE_SHIM_DIR to the pre-built shim \
         library, with OCCT_INCLUDE_DIR + OCCT_LIB_DIR for OCCT headers/libs"
            .to_string(),
    ))
}

#[cfg(test)]
mod tests {
    // `read_iges_file` is only used by tests that run with OCCT available.
    // Gate the import so it does not trigger an unused-import warning in the
    // `feature = "occt"` but `occt_found` not set configuration.
    #[cfg(any(not(feature = "occt"), occt_found))]
    use super::read_iges_file;

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

    /// E2E: read the IGES face fixture and verify shapes are extracted.
    ///
    /// The fixture (`face.igs`) contains a single trimmed surface (entity 144)
    /// — a flat unit square in the XY plane.  OCCT should transfer it into
    /// at least one B-Rep shape with valid bounds.
    #[cfg(occt_found)]
    #[test]
    fn read_iges_file_e2e_real_occt() {
        let _lock = crate::occt::OCCT_TEST_MUTEX
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("box.igs");

        assert!(
            fixture.exists(),
            "IGES fixture missing at {}",
            fixture.display()
        );

        let data = read_iges_file(&fixture).expect("read_iges_file should succeed");
        assert!(
            !data.shapes.is_empty(),
            "expected at least one shape from the IGES face fixture"
        );

        // Verify shape metadata.
        for (i, shape) in data.shapes.iter().enumerate() {
            eprintln!(
                "  shape[{i}]: label={:?}, type={:?}, bounds={:?}",
                shape.label, shape.shape_type, shape.bounds
            );
            // Bounds should be valid and within a reasonable range
            // (the face is a unit square at the origin).
            assert!(shape.bounds.is_valid(), "shape {i} bounds should be valid");
        }
    }

    /// E2E: read + tessellate the IGES face fixture and verify mesh data.
    #[cfg(occt_found)]
    #[test]
    fn read_iges_with_tessellation_e2e_real_occt() {
        let _lock = crate::occt::OCCT_TEST_MUTEX
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("box.igs");

        assert!(fixture.exists(), "IGES fixture missing");

        let (data, registry) = read_iges_file_with_tessellation(&fixture)
            .expect("read_iges_file_with_tessellation should succeed");

        assert!(
            !data.shapes.is_empty(),
            "expected at least one shape from the IGES face fixture"
        );
        assert!(
            !registry.is_empty(),
            "expected at least one tessellated mesh in the registry"
        );

        // Verify tessellation data.
        for (geom_id, mesh) in registry.iter() {
            eprintln!(
                "  registry[{geom_id:?}]: {} vertices, {} triangles",
                mesh.positions.len(),
                mesh.indices.len() / 3
            );
            assert!(!mesh.positions.is_empty(), "mesh should have vertices");
            assert!(
                mesh.indices.len() >= 3,
                "mesh should have at least one triangle"
            );
            assert!(mesh.bounds.is_valid(), "mesh bounds should be valid");
            // Verify positions are finite.
            for pos in &mesh.positions {
                assert!(
                    pos[0].is_finite() && pos[1].is_finite() && pos[2].is_finite(),
                    "non-finite position: {pos:?}"
                );
            }
            // Verify indices are in range.
            let vc = mesh.positions.len() as u32;
            for tri in mesh.indices.chunks(3) {
                assert!(
                    tri[0] < vc && tri[1] < vc && tri[2] < vc,
                    "index out of range: {tri:?} (vertex_count={vc})"
                );
            }
        }
    }
}
