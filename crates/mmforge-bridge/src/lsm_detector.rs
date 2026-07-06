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
/// Reads the file into memory, then delegates to `parse_lsm_data`.
pub fn parse_lsm(
    path: &Path,
) -> mmforge_core::Result<(mmforge_core::model::ParseOutput, TessellationRegistry)> {
    let data = std::fs::read(path)
        .map_err(|e| mmforge_core::Error::parse("LSM", format!("cannot read: {e}")))?;
    parse_lsm_data(&data, path)
}

/// Parse raw LSM/LSMC bytes and build a `TessellationRegistry`.
///
/// Magic bytes in `data` determine the routing:
/// - `b"LSMC"` → decompress with zstd, then read as LSM
/// - `b"LSMD"` → read directly
/// - otherwise → fall back to extension-based detection using `path`
///
/// After deserialising the `LsmModel`, extracts `Geometry::Mesh`
/// entries into the registry.  `BRepHandleRef` entries are skipped
/// (require OCCT).  `Drawing2D` entries are skipped.
pub fn parse_lsm_data(
    data: &[u8],
    path: &Path,
) -> mmforge_core::Result<(mmforge_core::model::ParseOutput, TessellationRegistry)> {
    let tag = to_format_tag(data, path);

    let model = if tag == FormatTag::Lsmc {
        let decompressed =
            mmforge_core::lsm::lsmc::read_lsmc_decompressed(&mut std::io::Cursor::new(data))
                .map_err(|e| mmforge_core::Error::parse("LSMC", format!("decompress: {e}")))?;
        mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(&decompressed))
            .map_err(|e| mmforge_core::Error::parse("LSMC", format!("{e}")))?
    } else {
        mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(data))
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
            Geometry::Drawing2D { .. } => {}
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

/// Internal routing: which format the bytes represent.
#[derive(Debug, PartialEq, Eq)]
enum FormatTag {
    Lsm,
    Lsmc,
}

/// Decide by magic bytes, then fall back to extension.
fn to_format_tag(data: &[u8], path: &Path) -> FormatTag {
    if data.len() >= 4 {
        if data[..4] == mmforge_core::lsm::lsmc::MAGIC {
            return FormatTag::Lsmc;
        }
        if data[..4] == mmforge_core::lsm::constants::MAGIC {
            return FormatTag::Lsm;
        }
    }
    // No magic — use extension as fallback.
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext == "lsmc" {
        FormatTag::Lsmc
    } else {
        FormatTag::Lsm
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mmforge_core::model::ModelBuilder;
    use std::io::Cursor;
    use std::path::PathBuf;
    use tempfile::Builder as TmpBuilder;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    // ── Detection tests ─────────────────────────────────────────

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

    // ── Helper: build a minimal model ───────────────────────────

    fn make_test_model() -> mmforge_core::model::LsmModel {
        let mut b = ModelBuilder::new("test");
        let positions: Vec<[f32; 3]> = vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]];
        let normals: Vec<[f32; 3]> = vec![[0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0]];
        let indices: Vec<u32> = vec![0, 1, 2];
        b.add_mesh(positions, normals, indices);
        b.add_root("Root");
        b.build()
    }

    fn write_temp_file(ext: &str, data: &[u8]) -> tempfile::NamedTempFile {
        let f = TmpBuilder::new()
            .suffix(&format!(".{ext}"))
            .tempfile()
            .unwrap();
        std::fs::write(f.path(), data).unwrap();
        f
    }

    fn write_lsm_bytes(model: &mmforge_core::model::LsmModel) -> Vec<u8> {
        let mut buf = Cursor::new(Vec::new());
        mmforge_core::lsm::write_lsm(model, &mut buf).unwrap();
        buf.into_inner()
    }

    fn write_lsmc_bytes(model: &mmforge_core::model::LsmModel) -> Vec<u8> {
        let mut buf = Cursor::new(Vec::new());
        mmforge_core::lsm::lsmc::write_lsmc(model, &mut buf).unwrap();
        buf.into_inner()
    }

    /// Parse .lsm data via `parse_lsm_data` and return (registry_len, tri_count, first_mesh_tri_count).
    fn parse_and_extract(data: &[u8], path: &Path) -> (usize, usize, usize) {
        let (output, reg) = parse_lsm_data(data, path).expect("parse must succeed");
        let tri_count = output.stats.triangle_count;
        let mesh_tris = reg
            .values()
            .next()
            .map(|m| m.indices.len() / 3)
            .unwrap_or(0);
        (reg.len(), tri_count, mesh_tris)
    }

    // ── parse_lsm_data routing tests ────────────────────────────

    #[test]
    fn parse_dot_lsm_file() {
        let model = make_test_model();
        let data = write_lsm_bytes(&model);
        let f = write_temp_file("lsm", &data);
        let (meshes, tris, mesh_tris) = parse_and_extract(&data, f.path());
        assert_eq!(meshes, 1, "registry must have 1 mesh");
        assert_eq!(tris, 1, "must have 1 triangle");
        assert_eq!(mesh_tris, 1, "first mesh must have 1 triangle");
        // round-trip via file path
        let (output2, reg2) = parse_lsm(f.path()).expect("parse_lsm on .lsm file");
        assert_eq!(reg2.len(), 1);
        assert_eq!(output2.stats.triangle_count, 1);
    }

    #[test]
    fn parse_dot_lsmc_file() {
        let model = make_test_model();
        let data = write_lsmc_bytes(&model);
        let f = write_temp_file("lsmc", &data);
        let (meshes, tris, mesh_tris) = parse_and_extract(&data, f.path());
        assert_eq!(meshes, 1);
        assert_eq!(tris, 1);
        assert_eq!(mesh_tris, 1);
        assert_eq!(&data[..4], mmforge_core::lsm::lsmc::MAGIC);
        let (output2, reg2) = parse_lsm(f.path()).expect("parse_lsm on .lsmc file");
        assert_eq!(reg2.len(), 1);
        assert_eq!(output2.stats.triangle_count, 1);
    }

    #[test]
    fn parse_lsmc_magic_no_extension() {
        let model = make_test_model();
        let data = write_lsmc_bytes(&model);
        let f = TmpBuilder::new().tempfile().unwrap();
        std::fs::write(f.path(), &data).unwrap();
        let (meshes, tris, mesh_tris) = parse_and_extract(&data, f.path());
        assert_eq!(meshes, 1);
        assert_eq!(tris, 1);
        assert_eq!(mesh_tris, 1);
    }

    #[test]
    fn parse_lsmc_magic_wrong_extension() {
        let model = make_test_model();
        let data = write_lsmc_bytes(&model);
        let f = write_temp_file("lsm", &data);
        let (meshes, tris, mesh_tris) = parse_and_extract(&data, f.path());
        assert_eq!(meshes, 1);
        assert_eq!(tris, 1);
        assert_eq!(mesh_tris, 1);
        let (output2, reg2) = parse_lsm(f.path()).expect("parse_lsm on .lsm with LSMC magic");
        assert_eq!(reg2.len(), 1);
        assert_eq!(output2.stats.triangle_count, 1);
    }

    #[test]
    fn parse_lsmd_magic_no_extension() {
        let model = make_test_model();
        let data = write_lsm_bytes(&model);
        let f = TmpBuilder::new().tempfile().unwrap();
        std::fs::write(f.path(), &data).unwrap();
        let (meshes, tris, mesh_tris) = parse_and_extract(&data, f.path());
        assert_eq!(meshes, 1);
        assert_eq!(tris, 1);
        assert_eq!(mesh_tris, 1);
    }

    #[test]
    fn parse_corrupted_lsmc_returns_error() {
        let mut data = vec![b'L', b'S', b'M', b'C'];
        data.extend_from_slice(&[0xFF; 100]); // invalid compressed data
        let f = TmpBuilder::new().suffix(".lsmc").tempfile().unwrap();
        std::fs::write(f.path(), &data).unwrap();
        let result = parse_lsm(f.path());
        assert!(result.is_err(), "corrupted LSMC must error");
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("decompress") || err.contains("LSMC"),
            "error must mention decompress or LSMC, got: {err}"
        );
    }

    #[test]
    fn parse_empty_file_errors() {
        let f = TmpBuilder::new().suffix(".lsm").tempfile().unwrap();
        std::fs::write(f.path(), b"").unwrap();
        assert!(parse_lsm(f.path()).is_err());
    }
}
