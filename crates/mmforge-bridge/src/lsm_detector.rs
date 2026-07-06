//! LSM / LSMC format detection and parsing for the bridge.
//!
//! Detects `.lsm` and `.lsmc` files by extension and magic bytes.
//! Delegates parsing to `mmforge_core::lsm`.

use std::path::Path;

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

/// Parse an LSM or LSMC file and produce a `MmfDocument`.
///
/// Reads the file into memory, decompresses if LSMC, then calls
/// `lsm::read_lsm`.  The resulting `LsmModel` is converted to a
/// `MmfDocument` via the normal build pipeline.
pub fn parse_lsm(
    path: &Path,
) -> mmforge_core::Result<(
    mmforge_core::model::ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
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

    let stats = mmforge_core::model::ParseStats {
        node_count: model.scene.nodes.len(),
        geometry_count: model.geometries.len(),
        material_count: model.materials.len(),
        triangle_count: 0,
        parse_duration_ms: 0,
    };

    let output = mmforge_core::model::ParseOutput {
        model,
        warnings: vec![],
        stats,
    };

    Ok((
        output,
        mmforge_geometry::tessellation::TessellationRegistry::new(),
    ))
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
