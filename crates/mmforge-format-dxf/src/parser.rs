//! DXF parser — orchestrates tokenization, section parsing, entity
//! parsing, and table parsing into a unified [`ParseOutput`].

use std::path::Path;

use mmforge_core::drawing::Drawing2DGeometry;
use mmforge_core::error::{Error, Result};
use mmforge_core::ids::{GeometryId, NodeId};
use mmforge_core::math::BoundingBox;
use mmforge_core::model::{Geometry, LsmModel, Node, ParseOutput, ParseStats, ParseWarning};
use mmforge_core::parser::{DetectionResult, FormatParser};

use crate::detect::detect_dxf;
use crate::entity_parser::parse_entities;
use crate::section_parser::parse_sections;
use crate::tables_parser::parse_layers;
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

    // Step 3: Parse TABLES → layers.
    let mut layers = Vec::new();
    for section in &sections {
        if section.name == "TABLES" {
            layers = parse_layers(&section.pairs);
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

    // Step 4: Parse ENTITIES.
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

    // Build Drawing2DGeometry.
    let drawing = Drawing2DGeometry {
        entities,
        layers: layers.clone(),
        blocks: Vec::new(), // BLOCK/INSERT not yet supported.
    };

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
