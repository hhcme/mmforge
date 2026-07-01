//! IGES/IGS file format detection.
//!
//! IGES (Initial Graphics Exchange Specification) files use the extension
//! `.igs` or `.iges`.  The format has a fixed-width 80-character record
//! structure where the first section (Start Section) has `S      1` in
//! columns 73-80 of the first line.
//!
//! Detection is conservative: extension must be `.igs` or `.iges`.
//! An optional header heuristic checks for the Start Section marker.

use std::path::Path;

/// Known IGES file extensions.
const IGES_EXTENSIONS: &[&str] = &["igs", "iges"];

/// Detect if a file is IGES based on extension and optional header marker.
pub fn detect_iges(header: &[u8], path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if !IGES_EXTENSIONS.contains(&ext.as_str()) {
        return false;
    }

    // Extension matches.  If we have enough header bytes, optionally verify
    // the Start Section marker (columns 73-80 = "S      1").
    if header.len() >= 80 {
        let marker = &header[72..80];
        // The marker is "S      1" (S + 6 spaces + 1) for the first record.
        // Be lenient: just check for 'S' at column 73.
        if marker[0] == b'S' && marker[7] == b'1' {
            return true;
        }
        // Extension matches but header doesn't have the marker — still accept
        // (some IGES variants have different Start Section formatting).
        return true;
    }

    // Extension matches, header too short to verify — accept.
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_iges_igs_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model.igs")));
    }

    #[test]
    fn detect_iges_iges_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model.iges")));
    }

    #[test]
    fn detect_iges_uppercase_extension() {
        let header = [0u8; 80];
        assert!(detect_iges(&header, &p("model.IGS")));
        assert!(detect_iges(&header, &p("model.IGES")));
    }

    #[test]
    fn detect_iges_with_header_marker() {
        let mut header = [0u8; 80];
        // IGES Start Section: columns 73-80 = "S      1"
        header[72] = b'S';
        header[79] = b'1';
        assert!(detect_iges(&header, &p("model.igs")));
    }

    #[test]
    fn reject_non_iges_extension() {
        let header = [0u8; 80];
        assert!(!detect_iges(&header, &p("model.step")));
        assert!(!detect_iges(&header, &p("model.stl")));
        assert!(!detect_iges(&header, &p("model.gltf")));
    }

    #[test]
    fn reject_iges_with_no_extension() {
        let header = [0u8; 80];
        assert!(!detect_iges(&header, &p("model")));
    }

    #[test]
    fn detect_iges_short_header() {
        let header = [0u8; 40]; // Too short for marker check
        assert!(detect_iges(&header, &p("model.iges")));
    }
}
