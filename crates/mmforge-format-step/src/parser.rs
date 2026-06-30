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
    use mmforge_core::model::{LsmModel, Node, ParseWarning};

    let step_data = mmforge_geometry::occt::step_reader::read_step_file(path)
        .map_err(|e| Error::parse("STEP", format!("OCCT read failed: {e}")))?;

    // Convert OCCT transfer messages to parse warnings.
    let mut warnings: Vec<ParseWarning> = step_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

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

        // Include shape type in the display label for richer metadata.
        let display_label = format!("{} [{:?}]", shape.label, shape.shape_type);

        model.scene.add_node(Node {
            id: child_id,
            name: display_label.clone(),
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
                label: display_label,
            });

        // Warn about shapes with no product name (fallback label).
        if shape.label.starts_with("Shape_") {
            warnings.push(ParseWarning::PrecisionLoss {
                message: format!("shape {i} has no STEP product name, using fallback"),
            });
        }
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

    /// E2E test: STEP fixture → read_step_file → Model.
    ///
    /// Verifies the full pipeline: OCCT reads the STEP file, transfers
    /// roots, extracts bbox/label/type, and the parser converts them
    /// into LsmModel with BRepHandleRef geometry.
    ///
    /// Only runs when both `occt` feature and `occt_found` cfg are set.
    #[cfg(occt_found)]
    #[test]
    fn e2e_step_fixture_to_model() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("mmforge-geometry")
            .join("testdata")
            .join("PQ-04909-A.STEP");

        assert!(
            fixture.exists(),
            "STEP fixture missing at {}",
            fixture.display(),
        );

        let parser = StepParser::new();
        let output = parser
            .parse(&fixture)
            .expect("parse should succeed with real OCCT");

        let model = &output.model;

        // Header metadata.
        assert_eq!(model.header.source_format, "STEP");
        assert!(model.header.source_path.is_some());

        // Root assembly node.
        let root = model
            .scene
            .find_node(model.scene.root)
            .expect("root node must exist");
        assert_eq!(root.name, "STEP_Assembly");
        assert!(root.bounds.is_valid(), "root bounds must be valid");

        // Must have at least one child (shape).
        assert!(
            !root.children.is_empty(),
            "expected at least one child node under STEP_Assembly"
        );

        // Every child must have geometry and valid bounds.
        for &child_id in &root.children {
            let child = model
                .scene
                .find_node(child_id)
                .expect("child node must exist");
            assert!(
                child.geometry.is_some(),
                "child '{}' must have geometry",
                child.name
            );
            assert!(
                child.bounds.is_valid(),
                "child '{}' must have valid bounds",
                child.name
            );
            // Label should include shape type annotation.
            assert!(
                child.name.contains('['),
                "child label '{}' should contain shape type",
                child.name
            );
        }

        // Every geometry must be BRepHandleRef.
        for geom in &model.geometries {
            match geom {
                mmforge_core::model::Geometry::BRepHandleRef { id, bounds, label } => {
                    assert!(bounds.is_valid(), "BRepHandleRef {id:?} bounds invalid");
                    assert!(!label.is_empty(), "BRepHandleRef {id:?} label empty");
                }
                other => panic!("expected BRepHandleRef, got {other:?}"),
            }
        }

        // Stats must be consistent.
        assert_eq!(output.stats.node_count, model.scene.nodes.len());
        assert_eq!(output.stats.geometry_count, model.geometries.len());

        // Print summary for diagnostics.
        eprintln!(
            "E2E: {} nodes, {} geometries, {} warnings",
            output.stats.node_count,
            output.stats.geometry_count,
            output.warnings.len(),
        );
        for node in &model.scene.nodes {
            eprintln!("  node '{}' bounds={:?}", node.name, node.bounds);
        }
        for w in &output.warnings {
            eprintln!("  warning: {w:?}");
        }
    }
}
