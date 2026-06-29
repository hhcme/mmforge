//! STEP parser implementation.
//!
//! When the `occt` feature is enabled, parsing delegates to OCCT's
//! `STEPControl_Reader` via [`mmforge_geometry::occt::step_reader`].
//! Without OCCT, `parse()` returns an error indicating the feature
//! is not available.

use crate::detect::detect_step;
use mmforge_core::error::Error;
use mmforge_core::model::ParseOutput;
use mmforge_core::parser::{DetectionResult, FormatParser};
use std::path::Path;

/// STEP file parser.
///
/// Implements [`FormatParser`] for ISO 10303-21 (STEP AP203/AP214).
pub struct StepParser;

impl StepParser {
    pub fn new() -> Self {
        Self
    }
}

impl Default for StepParser {
    fn default() -> Self {
        Self::new()
    }
}

impl FormatParser for StepParser {
    fn format_tag(&self) -> &'static str {
        "STEP"
    }

    fn detect(&self, header: &[u8], path: &Path) -> Option<DetectionResult> {
        detect_step(header, path)
    }

    fn supports_extension(&self, ext: &str) -> bool {
        matches!(ext.to_ascii_lowercase().as_str(), "stp" | "step" | "p21")
    }

    fn parse(&self, path: &Path) -> mmforge_core::error::Result<ParseOutput> {
        // Read the file header for detection validation.
        let header_bytes = read_header(path)?;

        // Verify this is actually a STEP file.
        if !header_bytes.starts_with(b"ISO-10303-21;")
            && !String::from_utf8_lossy(&header_bytes).contains("ISO-10303")
        {
            return Err(Error::parse(
                "STEP",
                "file does not start with ISO-10303-21 header",
            ));
        }

        // Delegate to OCCT if available.
        #[cfg(feature = "occt")]
        {
            occt_parse(path)
        }

        #[cfg(not(feature = "occt"))]
        {
            Err(Error::parse(
                "STEP",
                "OCCT feature not enabled — compile with --features occt to enable STEP parsing",
            ))
        }
    }
}

/// Read the first 4 KB of a file for format detection.
fn read_header(path: &Path) -> mmforge_core::error::Result<Vec<u8>> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut buf = vec![0u8; 4096];
    let n = file.read(&mut buf)?;
    buf.truncate(n);
    Ok(buf)
}

/// OCCT-backed parsing.  Only compiled when `occt` feature is enabled.
#[cfg(feature = "occt")]
fn occt_parse(path: &Path) -> mmforge_core::error::Result<ParseOutput> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{LsmModel, Node};

    let step_data = mmforge_geometry::occt::step_reader::read_step_file(path)
        .map_err(|e| Error::parse("STEP", format!("OCCT read failed: {e}")))?;

    // Convert OCCT output to LSM model.
    let mut model = LsmModel::empty("STEP");
    model.header.source_path = Some(path.display().to_string());

    let shapes = mmforge_geometry::occt::step_reader::extract_shapes(&step_data)
        .map_err(|e| Error::parse("STEP", format!("OCCT shape extraction failed: {e}")))?;

    // Create a root assembly node that parents all shapes.
    // This prevents orphan nodes when the file contains multiple shapes.
    let root_id = NodeId::new(0);
    model.scene.add_node(Node {
        id: root_id,
        name: "STEP_Assembly".to_string(),
        parent: None,
        children: Vec::new(),
        geometry: None,
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds: mmforge_core::math::BoundingBox::EMPTY,
    });

    // Add each shape as a child of the root assembly node.
    for (i, shape) in shapes.iter().enumerate() {
        let child_id = NodeId::new(i as u32 + 1); // +1 because root is 0
        let geom_id = GeometryId::new(i as u32);
        let bounds = shape.bounds;

        model.scene.add_node(Node {
            id: child_id,
            name: shape.label.clone(),
            parent: Some(root_id),
            children: Vec::new(),
            geometry: Some(geom_id),
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds,
        });
        model
            .geometries
            .push(mmforge_core::model::Geometry::BRepHandleRef {
                id: geom_id,
                bounds,
                label: shape.label.clone(),
            });
    }

    // Update root bounds from children.
    if !shapes.is_empty() {
        let mut root_bounds = mmforge_core::math::BoundingBox::EMPTY;
        for node in &model.scene.nodes {
            if node.id != root_id && node.bounds.is_valid() {
                root_bounds.extend(node.bounds);
            }
        }
        if let Some(root_node) = model.scene.find_node_mut(root_id) {
            root_node.bounds = root_bounds;
        }
    }

    let warnings = Vec::new();
    let stats = model.stats();

    Ok(ParseOutput {
        model,
        warnings,
        stats,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_metadata() {
        let parser = StepParser::new();
        assert_eq!(parser.format_tag(), "STEP");
    }

    #[test]
    fn supports_step_extensions() {
        let parser = StepParser::new();
        assert!(parser.supports_extension("stp"));
        assert!(parser.supports_extension("step"));
        assert!(parser.supports_extension("STEP"));
        assert!(parser.supports_extension("p21"));
        assert!(!parser.supports_extension("stl"));
        assert!(!parser.supports_extension("gltf"));
    }

    #[test]
    fn detect_works() {
        let parser = StepParser::new();
        let header = b"ISO-10303-21;\nHEADER;\n";
        let path = Path::new("test.step");
        let result = parser.detect(header, path);
        assert!(result.is_some());
        assert_eq!(result.unwrap().format_tag, "STEP");
    }

    #[test]
    fn parse_nonexistent_file_errors() {
        let parser = StepParser::new();
        let result = parser.parse(Path::new("/nonexistent/file.step"));
        assert!(result.is_err());
    }

    #[test]
    fn parse_non_step_file_errors() {
        // Create a temporary file with non-STEP content.
        let dir = std::env::temp_dir().join("mmforge_test_parse");
        std::fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("fake.step");
        std::fs::write(&file_path, "this is not a STEP file").unwrap();

        let parser = StepParser::new();
        let result = parser.parse(&file_path);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("ISO-10303"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(not(feature = "occt"))]
    #[test]
    fn parse_without_occt_errors() {
        // Create a valid STEP header file.
        let dir = std::env::temp_dir().join("mmforge_test_no_occt");
        std::fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("test.step");
        std::fs::write(
            &file_path,
            "ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;",
        )
        .unwrap();

        let parser = StepParser::new();
        let result = parser.parse(&file_path);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("OCCT feature not enabled"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
