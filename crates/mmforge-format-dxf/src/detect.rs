//! DXF format detection.

use mmforge_core::parser::DetectionConfidence;
use std::path::Path;

/// Known DXF file extensions.
const DXF_EXTENSIONS: &[&str] = &["dxf"];

/// Detect whether a file is DXF based on header bytes and extension.
pub fn detect_dxf(header: &[u8], path: &Path) -> Option<mmforge_core::parser::DetectionResult> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if !DXF_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }

    // DXF files typically start with "0\nSECTION" or "  0\n  SECTION".
    // Check if the header contains the SECTION marker.
    let header_str = String::from_utf8_lossy(header);
    if header_str.contains("SECTION") {
        return Some(mmforge_core::parser::DetectionResult {
            format_tag: "DXF",
            confidence: DetectionConfidence::High,
        });
    }

    // Extension matches but no SECTION marker — low confidence.
    Some(mmforge_core::parser::DetectionResult {
        format_tag: "DXF",
        confidence: DetectionConfidence::Low,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_dxf_with_section_marker() {
        let header = b"0\nSECTION\n2\nHEADER\n";
        let result = detect_dxf(header, &p("test.dxf")).unwrap();
        assert_eq!(result.format_tag, "DXF");
        assert_eq!(result.confidence, DetectionConfidence::High);
    }

    #[test]
    fn detect_dxf_extension_only() {
        let header = b"some random bytes";
        let result = detect_dxf(header, &p("test.dxf")).unwrap();
        assert_eq!(result.confidence, DetectionConfidence::Low);
    }

    #[test]
    fn reject_non_dxf_extension() {
        let header = b"0\nSECTION\n";
        assert!(detect_dxf(header, &p("test.step")).is_none());
    }

    #[test]
    fn reject_no_extension() {
        let header = b"0\nSECTION\n";
        assert!(detect_dxf(header, &p("test")).is_none());
    }
}
