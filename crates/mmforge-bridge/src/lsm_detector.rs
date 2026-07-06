//! LSM / LSMC format detection and parsing for the bridge.
//!
//! Detects `.lsm` and `.lsmc` files by extension and magic bytes.
//! Delegates parsing to `mmforge_core::lsm`.  Extracts Mesh geometry
//! from the LSM model and builds a `TessellationRegistry` so the
//! resulting `RenderPacket` contains renderable triangles.

use std::path::Path;

use mmforge_core::model::Geometry;
use mmforge_geometry::tessellation::{TessellatedMeshData, TessellationRegistry};

/// Check whether a file is a `.lsm` or `.lsmc` document.
pub fn detect_lsm(header: &[u8], path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if ext == "lsm" || ext == "lsmc" {
        return true;
    }

    if header.len() >= 4
        && (header[..4] == mmforge_core::lsm::constants::MAGIC
            || header[..4] == mmforge_core::lsm::lsmc::MAGIC)
    {
        return true;
    }

    false
}

/// Parse an LSM or LSMC file and produce parse output with a
/// `TessellationRegistry` containing all Mesh geometries from the model.
///
/// Reads the file, decompresses if LSMC, deserialises the LSM model,
/// then extracts each `Geometry::Mesh` into a `TessellatedMeshData`
/// entry.  `Geometry::BRepHandleRef` entries are skipped (require OCCT
/// for tessellation).  The resulting registry is consumed by
/// `mmforge_render::build_render_packet` to produce GPU-ready data.
pub fn parse_lsm(
    path: &Path,
) -> mmforge_core::Result<(mmforge_core::model::ParseOutput, TessellationRegistry)> {
    let data = std::fs::read(path)
        .map_err(|e| mmforge_core::Error::parse("LSM", format!("cannot read: {e}")))?;

    let is_lsmc = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("lsmc"))
        .unwrap_or(false);

    let model = if is_lsmc {
        let decompressed =
            mmforge_core::lsm::lsmc::read_lsmc_decompressed(&mut std::io::Cursor::new(&data))
                .map_err(|e| mmforge_core::Error::parse("LSMC", format!("decompress: {e}")))?;
        mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(&decompressed))
            .map_err(|e| mmforge_core::Error::parse("LSMC", format!("{e}")))?
    } else {
        mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(&data))
            .map_err(|e| mmforge_core::Error::parse("LSM", format!("{e}")))?
    };

    // Build TessellationRegistry from Mesh geometries.
    let mut registry = TessellationRegistry::new();
    let mut tri_count = 0usize;
    let mut warnings: Vec<mmforge_core::model::ParseWarning> = Vec::new();

    for geom in &model.geometries {
        match geom {
            Geometry::Mesh(mesh) => {
                tri_count += mesh.indices.len() / 3;
                registry.insert(
                    mesh.id,
                    TessellatedMeshData {
                        positions: mesh.positions.clone(),
                        normals: mesh.normals.clone(),
                        indices: mesh.indices.clone(),
                        bounds: mesh.bounds,
                    },
                );
            }
            Geometry::BRepHandleRef { id, label, .. } => {
                warnings.push(mmforge_core::model::ParseWarning::UnsupportedEntity {
                    entity_type: format!("BRepHandleRef({label})"),
                    count: 1,
                });
                let _ = id;
            }
            Geometry::Drawing2D { .. } => {
                // 2D drawings are not rendered via RenderPacket.
            }
        }
    }

    let stats = mmforge_core::model::ParseStats {
        node_count: model.scene.nodes.len(),
        geometry_count: model.geometries.len(),
        material_count: model.materials.len(),
        triangle_count: tri_count,
        parse_duration_ms: 0,
    };

    let output = mmforge_core::model::ParseOutput {
        model,
        warnings,
        stats,
    };

    Ok((output, registry))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_lsm_by_extension() {
        assert!(detect_lsm(b"", &p("model.lsm")));
        assert!(detect_lsm(b"", &p("model.lsmc")));
    }

    #[test]
    fn detect_lsm_by_magic() {
        assert!(detect_lsm(b"LSMD", &p("unknown.bin")));
        assert!(detect_lsm(b"LSMC", &p("unknown.bin")));
    }

    #[test]
    fn reject_non_lsm() {
        assert!(!detect_lsm(b"ISO-10303-21;", &p("model.step")));
        assert!(!detect_lsm(b"solid", &p("model.stl")));
    }
}
