//! IGES/IGS file format detection.
//!
//! IGES files use the extension `.igs` or `.iges`.  The format has a
//! fixed-width 80-character record structure where the Start Section
//! has `S      1` in columns 73-80.

use mmforge_core::parser::DetectionConfidence;
use std::path::Path;

/// Known IGES file extensions.
const IGES_EXTENSIONS: &[&str] = &["igs", "iges"];

/// Detect whether a file is IGES based on header bytes and extension.
///
/// Returns `Some(DetectionResult)` if detected, `None` otherwise.
pub fn detect_iges(header: &[u8], path: &Path) -> Option<mmforge_core::parser::DetectionResult> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if !IGES_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }

    // Extension matches.  If we have enough header bytes, check for
    // the Start Section marker (columns 73-80 = "S      1").
    if header.len() >= 80 {
        let marker = &header[72..80];
        if marker[0] == b'S' && marker[7] == b'1' {
            return Some(mmforge_core::parser::DetectionResult {
                format_tag: "IGES",
                confidence: DetectionConfidence::High,
            });
        }
    }

    // Extension matches but no header marker — low confidence.
    Some(mmforge_core::parser::DetectionResult {
        format_tag: "IGES",
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
    fn detect_igs_extension() {
        let header = [0u8; 80];
        let result = detect_iges(&header, &p("model.igs")).unwrap();
        assert_eq!(result.format_tag, "IGES");
        assert_eq!(result.confidence, DetectionConfidence::Low);
    }

    #[test]
    fn detect_iges_extension() {
        let header = [0u8; 80];
        let result = detect_iges(&header, &p("model.iges")).unwrap();
        assert_eq!(result.format_tag, "IGES");
    }

    #[test]
    fn detect_uppercase_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model.IGS")).is_some());
        assert!(detect_iges(&header, &p("model.IGES")).is_some());
    }

    #[test]
    fn detect_with_header_marker() {
        let mut header = [0u8; 80];
        header[72] = b'S';
        header[79] = b'1';
        let result = detect_iges(&header, &p("model.igs")).unwrap();
        assert_eq!(result.confidence, DetectionConfidence::High);
    }

    #[test]
    fn reject_non_iges_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model.step")).is_none());
        assert!(detect_iges(&header, &p("model.stl")).is_none());
        assert!(detect_iges(&header, &p("model.gltf")).is_none());
    }

    #[test]
    fn reject_no_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model")).is_none());
    }
}
