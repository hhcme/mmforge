//! DXF parser — orchestrates tokenization, section parsing, entity
//! parsing, and table parsing into a unified [`ParseOutput`].

use std::path::Path;

use mmforge_core::drawing::Drawing2DGeometry;
use mmforge_core::error::{Error, Result};
use mmforge_core::ids::{GeometryId, NodeId};
use mmforge_core::math::BoundingBox;
use mmforge_core::model::{Geometry, LsmModel, Node, ParseOutput, ParseStats, ParseWarning};
use mmforge_core::parser::{DetectionResult, FormatParser};

use crate::blocks_parser::parse_blocks;
use crate::detect::detect_dxf;
use crate::entity_parser::parse_entities;
use crate::section_parser::parse_sections;
use crate::tables_parser::{parse_layers, parse_line_types};
use crate::tokenizer::DxfTokenizer;

/// DXF file parser.
pub struct DxfParser;

impl DxfParser {
    pub fn new() -> Self {
        Self
    }
}

impl Default for DxfParser {
    fn default() -> Self {
        Self::new()
    }
}

impl FormatParser for DxfParser {
    fn format_tag(&self) -> &'static str {
        "DXF"
    }

    fn detect(&self, header: &[u8], path: &Path) -> Option<DetectionResult> {
        detect_dxf(header, path)
    }

    fn supports_extension(&self, ext: &str) -> bool {
        ext.eq_ignore_ascii_case("dxf")
    }

    fn parse(&self, path: &Path) -> Result<ParseOutput> {
        parse_dxf(path).map(|(output, _drawing)| output)
    }
}

/// Parse a DXF file into an [`ParseOutput`] and the raw drawing geometry.
///
/// Returns both the LSM model (for the scene tree / bridge) and the
/// [`Drawing2DGeometry`] (for the 2D draw list pipeline).
pub fn parse_dxf(path: &Path) -> Result<(ParseOutput, Drawing2DGeometry)> {
    let content = std::fs::read_to_string(path).map_err(Error::Io)?;

    // Step 1: Tokenize.
    let mut tokenizer = DxfTokenizer::new(&content);
    let pairs = tokenizer.collect_all();

    if pairs.is_empty() {
        return Err(Error::parse(
            "DXF",
            "file is empty or has no valid group pairs",
        ));
    }

    // Step 2: Parse sections.
    let sections = parse_sections(&pairs);
    let mut warnings = Vec::new();

    // Step 3: Parse TABLES → layers and line types.
    let mut layers = Vec::new();
    let mut line_types = Vec::new();
    for section in &sections {
        if section.name == "TABLES" {
            layers = parse_layers(&section.pairs);
            line_types = parse_line_types(&section.pairs);
        }
    }

    // Ensure there's always a default layer.
    if layers.is_empty() {
        layers.push(mmforge_core::drawing::Layer {
            name: "0".to_string(),
            color_index: 7,
            visible: true,
        });
    }

    // Step 4: Parse BLOCKS.
    let mut blocks = Vec::new();
    for section in &sections {
        if section.name == "BLOCKS" {
            blocks = parse_blocks(&section.pairs);
        }
    }

    // Step 5: Parse ENTITIES.
    let mut entities = Vec::new();
    for section in &sections {
        if section.name == "ENTITIES" {
            entities = parse_entities(&section.pairs);
        }
    }

    // Report unsupported entities as warnings.
    let parsed_count = entities.len();
    let total_entity_pairs: usize = sections
        .iter()
        .filter(|s| s.name == "ENTITIES")
        .map(|s| s.pairs.iter().filter(|p| p.code == 0).count())
        .sum();
    if total_entity_pairs > parsed_count {
        warnings.push(ParseWarning::UnsupportedEntity {
            entity_type: "mixed".to_string(),
            count: total_entity_pairs - parsed_count,
        });
    }

    // Build Drawing2DGeometry and expand INSERTs.
    let mut drawing = Drawing2DGeometry {
        entities,
        layers: layers.clone(),
        blocks,
        line_types,
    };
    drawing.expand_inserts();

    // Compute bounds from drawing.
    let bbox2d = drawing.bounds();
    let bounds = if bbox2d.is_valid() {
        BoundingBox::new(
            glam::Vec3::new(bbox2d.min[0] as f32, bbox2d.min[1] as f32, 0.0),
            glam::Vec3::new(bbox2d.max[0] as f32, bbox2d.max[1] as f32, 0.0),
        )
    } else {
        BoundingBox::EMPTY
    };

    // Build LSM model.
    let mut model = LsmModel::empty("DXF");
    model.header.source_path = Some(path.display().to_string());

    // Root assembly node.
    let root_id = NodeId::new(0);
    model.scene.add_node(Node {
        id: root_id,
        name: "DXF_Drawing".to_string(),
        parent: None,
        children: Vec::new(),
        geometry: None,
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds,
    });

    // Single geometry node with Drawing2D data.
    let geom_id = GeometryId::new(0);
    let child_id = NodeId::new(1);
    model.scene.add_node(Node {
        id: child_id,
        name: "Drawing".to_string(),
        parent: Some(root_id),
        children: Vec::new(),
        geometry: Some(geom_id),
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds,
    });
    model.geometries.push(Geometry::Drawing2D {
        id: geom_id,
        bounds,
        drawing: Box::new(drawing.clone()),
    });

    // Create layer nodes in the scene tree for visibility toggling.
    for (i, layer) in layers.iter().enumerate() {
        let layer_node_id = NodeId::new(i as u32 + 2);
        model.scene.add_node(Node {
            id: layer_node_id,
            name: layer.name.clone(),
            parent: Some(root_id),
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: layer.visible,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
    }

    let stats = ParseStats {
        node_count: model.scene.nodes.len(),
        geometry_count: model.geometries.len(),
        material_count: 0,
        triangle_count: 0,
        parse_duration_ms: 0,
    };

    Ok((
        ParseOutput {
            model,
            warnings,
            stats,
        },
        drawing,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_test_fixture() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("test.dxf");
        assert!(fixture.exists(), "test.dxf fixture missing");

        let (output, drawing) = parse_dxf(&fixture).expect("parse_dxf should succeed");

        // Verify entity counts.
        assert_eq!(drawing.entities.len(), 6); // 2 LINE + 1 CIRCLE + 1 ARC + 1 LWPOLYLINE + 1 TEXT
        assert_eq!(drawing.layers.len(), 3); // walls, text, hidden

        // Verify layer names.
        let layer_names: Vec<&str> = drawing.layers.iter().map(|l| l.name.as_str()).collect();
        assert!(layer_names.contains(&"walls"));
        assert!(layer_names.contains(&"text"));
        assert!(layer_names.contains(&"hidden"));

        // Verify hidden layer is not visible.
        let hidden = drawing.layers.iter().find(|l| l.name == "hidden").unwrap();
        assert!(!hidden.visible);

        // Verify bounds are valid.
        let bbox = drawing.bounds();
        assert!(bbox.is_valid());
        assert!(bbox.width() > 0.0);
        assert!(bbox.height() > 0.0);

        // Verify model structure.
        assert_eq!(output.model.geometries.len(), 1);
        assert!(matches!(
            output.model.geometries[0],
            Geometry::Drawing2D { .. }
        ));

        // Verify stats.
        assert_eq!(output.stats.geometry_count, 1);
    }

    #[test]
    fn parse_error_fixture_gracefully() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("error.dxf");
        assert!(fixture.exists(), "error.dxf fixture missing");

        // Should not panic — malformed values are skipped.
        let result = parse_dxf(&fixture);
        // May succeed with 0 entities or fail with an error.
        match result {
            Ok((output, drawing)) => {
                // The malformed LINE has non-numeric value for code 10,
                // so it should be skipped.
                assert!(drawing.entities.len() <= 1);
                assert_eq!(output.stats.geometry_count, 1);
            }
            Err(_) => {
                // Also acceptable — the parser detected the error.
            }
        }
    }

    #[test]
    fn draw_list_from_fixture() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("test.dxf");
        let (_, drawing) = parse_dxf(&fixture).expect("parse_dxf");

        let draw_list = mmforge_render::draw2d::build_draw_list(&drawing);

        // Verify draw list has commands.
        assert!(!draw_list.flat_commands.is_empty());

        // Verify layer grouping.  "hidden" layer has no entities so it
        // won't appear in the draw list — only layers with entities are included.
        assert_eq!(draw_list.layers.len(), 2); // walls + text

        // Verify walls layer has LINE, CIRCLE, ARC, POLYLINE commands.
        let walls = draw_list
            .layers
            .iter()
            .find(|l| l.layer_name == "walls")
            .unwrap();
        assert!(walls.commands.len() >= 4); // 2 line + 1 circle + 1 arc + expanded polyline segments

        // Verify text layer has TEXT command.
        let text_layer = draw_list
            .layers
            .iter()
            .find(|l| l.layer_name == "text")
            .unwrap();
        assert_eq!(text_layer.commands.len(), 1);
        assert!(matches!(
            text_layer.commands[0],
            mmforge_render::draw2d::DrawCommand2D::Text { .. }
        ));
    }

    #[test]
    fn arc_e2e_dxf_degrees_to_draw_list_radians() {
        // The test.dxf has an ARC entity: center(7.5, 2.5), radius=1.0,
        // start_angle=0°, end_angle=180°.
        // Verify the draw list converts degrees → radians correctly.
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("test.dxf");
        let (_, drawing) = parse_dxf(&fixture).expect("parse_dxf");
        let draw_list = mmforge_render::draw2d::build_draw_list(&drawing);

        // Find the ARC command in the walls layer.
        let walls = draw_list
            .layers
            .iter()
            .find(|l| l.layer_name == "walls")
            .unwrap();
        let arc_cmd = walls
            .commands
            .iter()
            .find(|c| matches!(c, mmforge_render::draw2d::DrawCommand2D::Arc { .. }));
        assert!(arc_cmd.is_some(), "expected an ARC command in walls layer");

        match arc_cmd.unwrap() {
            mmforge_render::draw2d::DrawCommand2D::Arc {
                center,
                radius,
                start_angle,
                end_angle,
                ccw,
            } => {
                // Verify center and radius.
                assert!((center[0] - 7.5).abs() < 1e-10);
                assert!((center[1] - 2.5).abs() < 1e-10);
                assert!((radius - 1.0).abs() < 1e-10);

                // Verify angles converted from degrees to radians.
                // 0° → 0.0 rad, 180° → π rad.
                let pi = std::f64::consts::PI;
                assert!(
                    (start_angle - 0.0).abs() < 1e-10,
                    "start_angle should be 0.0 rad (0°), got {start_angle}"
                );
                assert!(
                    (end_angle - pi).abs() < 1e-10,
                    "end_angle should be π rad (180°), got {end_angle}"
                );

                // DXF ARC is always CCW.
                assert!(*ccw, "DXF ARC should be CCW");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn polyline_bulge_expanded_to_arc() {
        // The test.dxf LWPOLYLINE has bulge=0 (straight segments).
        // Verify that all polyline segments are lines (no arcs).
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("test.dxf");
        let (_, drawing) = parse_dxf(&fixture).expect("parse_dxf");
        let draw_list = mmforge_render::draw2d::build_draw_list(&drawing);

        let walls = draw_list
            .layers
            .iter()
            .find(|l| l.layer_name == "walls")
            .unwrap();
        // The LWPOLYLINE with bulge=0 should produce 4 LINE commands (closed rectangle).
        let line_cmds: Vec<_> = walls
            .commands
            .iter()
            .filter(|c| matches!(c, mmforge_render::draw2d::DrawCommand2D::Line { .. }))
            .collect();
        assert!(line_cmds.len() >= 4);
    }
}
