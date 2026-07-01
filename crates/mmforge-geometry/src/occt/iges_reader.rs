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
