//! IGES parser implementation.
//!
//! When the `occt` feature is enabled, parsing delegates to OCCT's
//! `IGESCAFControl_Reader` via [`mmforge_geometry::occt::iges_reader`].
//! Without OCCT, `parse()` returns an error indicating the feature
//! is not available.

use crate::detect::detect_iges;
use mmforge_core::error::Error;
use mmforge_core::model::ParseOutput;
use mmforge_core::parser::{DetectionResult, FormatParser};
use std::path::Path;

/// IGES file parser.
///
/// Implements [`FormatParser`] for IGES/IGS files via OCCT.
pub struct IgesParser;

impl IgesParser {
    pub fn new() -> Self {
        Self
    }
}

impl Default for IgesParser {
    fn default() -> Self {
        Self::new()
    }
}

impl FormatParser for IgesParser {
    fn format_tag(&self) -> &'static str {
        "IGES"
    }

    fn detect(&self, header: &[u8], path: &Path) -> Option<DetectionResult> {
        detect_iges(header, path)
    }

    fn supports_extension(&self, ext: &str) -> bool {
        matches!(ext.to_ascii_lowercase().as_str(), "igs" | "iges")
    }

    fn parse(&self, path: &Path) -> mmforge_core::error::Result<ParseOutput> {
        #[cfg(feature = "occt")]
        {
            occt_parse(path)
        }

        #[cfg(not(feature = "occt"))]
        {
            let _ = path;
            Err(Error::parse(
                "IGES",
                "OCCT feature not enabled — compile with --features occt to enable IGES parsing",
            ))
        }
    }
}

/// OCCT-backed parsing.  Only compiled when `occt` feature is enabled.
#[cfg(feature = "occt")]
fn occt_parse(path: &Path) -> mmforge_core::error::Result<ParseOutput> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{LsmModel, Node, ParseWarning};

    let iges_data = mmforge_geometry::occt::iges_reader::read_iges_file(path)
        .map_err(|e| Error::parse("IGES", format!("OCCT read failed: {e}")))?;

    let mut warnings: Vec<ParseWarning> = iges_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("IGES");
    model.header.source_path = Some(path.display().to_string());

    let shapes = mmforge_geometry::occt::iges_reader::extract_shapes(&iges_data)
        .map_err(|e| Error::parse("IGES", format!("OCCT shape extraction failed: {e}")))?;

    // Create a root assembly node.
    let root_id = NodeId::new(0);
    model.scene.add_node(Node {
        id: root_id,
        name: "IGES_Assembly".to_string(),
        parent: None,
        children: Vec::new(),
        geometry: None,
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds: mmforge_core::math::BoundingBox::EMPTY,
    });

    for (i, shape) in shapes.iter().enumerate() {
        let child_id = NodeId::new(i as u32 + 1);
        let geom_id = GeometryId::new(i as u32);
        let bounds = shape.bounds;
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

        if shape.label.starts_with("Shape_") {
            warnings.push(ParseWarning::PrecisionLoss {
                message: format!("shape {i} has no IGES product name, using fallback"),
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

/// Parse an IGES file and tessellate all B-Rep shapes in one pass.
///
/// Returns both the [`ParseOutput`] and a [`TessellationRegistry`].
pub fn parse_iges_with_tessellation(
    path: &Path,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    #[cfg(feature = "occt")]
    {
        occt_parse_with_tessellation(path)
    }

    #[cfg(not(feature = "occt"))]
    {
        let _ = path;
        Err(Error::parse(
            "IGES",
            "OCCT feature not enabled — compile with --features occt to enable IGES parsing",
        ))
    }
}

#[cfg(feature = "occt")]
fn occt_parse_with_tessellation(
    path: &Path,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{LsmModel, Node, ParseWarning};

    let (iges_data, registry) =
        mmforge_geometry::occt::iges_reader::read_iges_file_with_tessellation(path)
            .map_err(|e| Error::parse("IGES", format!("OCCT read/tessellate failed: {e}")))?;

    let mut warnings: Vec<ParseWarning> = iges_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("IGES");
    model.header.source_path = Some(path.display().to_string());

    let shapes = &iges_data.shapes;

    let root_id = NodeId::new(0);
    model.scene.add_node(Node {
        id: root_id,
        name: "IGES_Assembly".to_string(),
        parent: None,
        children: Vec::new(),
        geometry: None,
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds: mmforge_core::math::BoundingBox::EMPTY,
    });

    for (i, shape) in shapes.iter().enumerate() {
        let child_id = NodeId::new(i as u32 + 1);
        let geom_id = GeometryId::new(i as u32);
        let bounds = shape.bounds;
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

        if shape.label.starts_with("Shape_") {
            warnings.push(ParseWarning::PrecisionLoss {
                message: format!("shape {i} has no IGES product name, using fallback"),
            });
        }
    }

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

    Ok((
        ParseOutput {
            model,
            warnings,
            stats,
        },
        registry,
    ))
}
