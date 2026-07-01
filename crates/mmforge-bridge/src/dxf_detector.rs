//! DXF format detection for the bridge.
//!
//! Detects DXF files by extension (`.dxf`) and optionally by header
//! content (group code 0 / SECTION marker).

use std::path::Path;

/// Detect if a file is DXF by extension and optional header content.
pub fn detect_dxf(header: &[u8], path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if ext != "dxf" {
        return false;
    }

    // DXF files typically contain "SECTION" in the header.
    let header_str = String::from_utf8_lossy(header);
    header_str.contains("SECTION") || ext == "dxf"
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_dxf_with_section() {
        let header = b"0\nSECTION\n2\nHEADER\n";
        assert!(detect_dxf(header, &p("test.dxf")));
    }

    #[test]
    fn detect_dxf_extension_only() {
        let header = b"random bytes";
        assert!(detect_dxf(header, &p("test.dxf")));
    }

    #[test]
    fn reject_non_dxf() {
        let header = b"0\nSECTION\n";
        assert!(!detect_dxf(header, &p("test.step")));
    }
}
