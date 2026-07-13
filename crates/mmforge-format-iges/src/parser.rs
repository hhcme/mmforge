//! IGES parser implementation.
//!
//! When the `occt` feature is enabled, parsing delegates to OCCT's
//! `IGESCAFControl_Reader` via [`mmforge_geometry::occt::iges_reader`].
//! Without OCCT, `parse()` returns an error indicating the feature
//! is not available.

use crate::detect::detect_iges;
use mmforge_core::cancel::CancellationToken;
use mmforge_core::error::Error;
use mmforge_core::model::ParseOutput;
use mmforge_core::parser::{DetectionResult, FormatParser};
use mmforge_core::progress::{ParseProgress, ProgressCallback};
use std::path::Path;

fn report_progress(
    progress: Option<&ProgressCallback>,
    stage: &'static str,
    current: u32,
    total: u32,
) {
    if let Some(cb) = progress {
        cb(&ParseProgress::new(stage, current, total));
    }
}

fn check_cancel(cancel: Option<&CancellationToken>) -> mmforge_core::error::Result<()> {
    if cancel.is_some_and(|c| c.is_cancelled()) {
        return Err(Error::Cancelled);
    }
    Ok(())
}

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
        let never_cancel = CancellationToken::new();
        self.parse_with_progress(path, None, &never_cancel)
    }

    fn parse_with_progress(
        &self,
        path: &Path,
        progress: Option<&ProgressCallback>,
        cancel: &CancellationToken,
    ) -> mmforge_core::error::Result<ParseOutput> {
        check_cancel(Some(cancel))?;
        report_progress(progress, "reading", 0, 0);
        let _path = path;

        #[cfg(feature = "occt")]
        {
            occt_parse_with_progress(path, progress, cancel)
        }

        #[cfg(not(feature = "occt"))]
        {
            let _ = (progress, cancel);
            Err(Error::parse(
                "IGES",
                "OCCT feature not enabled — compile with --features occt to enable IGES parsing",
            ))
        }
    }
}

/// OCCT-backed parsing with progress and cancellation.
///
/// Cancellation is checked before the expensive OCCT read and between
/// shape creation.  OCCT itself does not support mid-operation cancellation,
/// so this is a best-effort boundary check.
#[cfg(feature = "occt")]
fn occt_parse_with_progress(
    path: &Path,
    progress: Option<&ProgressCallback>,
    cancel: &CancellationToken,
) -> mmforge_core::error::Result<ParseOutput> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{Geometry, LsmModel, Node, ParseWarning};

    check_cancel(Some(cancel))?;
    report_progress(progress, "parsing", 0, 1);
    let iges_data = mmforge_geometry::occt::iges_reader::read_iges_file(path)
        .map_err(|e| Error::parse("IGES", format!("OCCT read failed: {e}")))?;

    check_cancel(Some(cancel))?;
    report_progress(progress, "building", 0, 1);
    let mut warnings: Vec<ParseWarning> = iges_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("IGES");
    model.header.source_path = Some(path.display().to_string());

    // Tree-based build when XDE assembly tree is available.
    let tree = &iges_data.tree_nodes;
    if !tree.is_empty() {
        let node_count = tree.len();
        let mut node_ids: Vec<NodeId> = Vec::with_capacity(node_count);
        let mut geom_counter: u32 = 0;
        for (i, tn) in tree.iter().enumerate() {
            check_cancel(Some(cancel))?;
            let nid = NodeId::new(i as u32);
            node_ids.push(nid);
            let parent_id = if tn.parent_index >= 0 {
                Some(node_ids[tn.parent_index as usize])
            } else {
                None
            };
            let (geom_id, label) = if tn.is_assembly {
                (None, tn.name.clone())
            } else {
                let gid = GeometryId::new(geom_counter);
                geom_counter += 1;
                let lbl = if tn.name.is_empty() {
                    format!("Part_{}", gid.get())
                } else {
                    format!("{} [{:?}]", tn.name, tn.shape_type)
                };
                (Some(gid), lbl)
            };
            let name = if tn.name.is_empty() {
                if tn.is_assembly {
                    format!("Assembly_{i}")
                } else {
                    format!("Part_{i}")
                }
            } else {
                tn.name.clone()
            };
            model.scene.add_node(Node {
                id: nid,
                name,
                parent: parent_id,
                children: Vec::new(),
                geometry: geom_id,
                material: None,
                visible: true,
                local_transform: tn.transform,
                bounds: tn.bounds,
            });
            if let Some(gid) = geom_id {
                model.geometries.push(Geometry::BRepHandleRef {
                    id: gid,
                    bounds: tn.bounds,
                    label,
                });
            }
            if let Some(pid) = parent_id {
                if let Some(pn) = model.scene.find_node_mut(pid) {
                    pn.children.push(nid);
                }
            }
        }
        if !node_ids.is_empty() {
            model.scene.root = node_ids[0];
        }
        let stats = model.stats();
        return Ok(ParseOutput {
            model,
            warnings,
            stats,
        });
    }

    // Fallback: flat shapes.
    let shapes = mmforge_geometry::occt::iges_reader::extract_shapes(&iges_data)
        .map_err(|e| Error::parse("IGES", format!("OCCT shape extraction failed: {e}")))?;

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
        check_cancel(Some(cancel))?;
        let child_id = NodeId::new(i as u32 + 1);
        let geom_id = GeometryId::new(i as u32);
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
            bounds: shape.bounds,
        });
        model.geometries.push(Geometry::BRepHandleRef {
            id: geom_id,
            bounds: shape.bounds,
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
    parse_iges_with_tessellation_with_progress(path, None, &CancellationToken::new())
}

/// Parse an IGES file with optional progress reporting and cancellation.
///
/// Cancellation is checked before the expensive OCCT read/tessellation
/// and between shapes.  OCCT does not support mid-operation cancellation,
/// so this is a best-effort boundary check.
pub fn parse_iges_with_tessellation_with_progress(
    path: &Path,
    progress: Option<&ProgressCallback>,
    cancel: &CancellationToken,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    #[cfg(feature = "occt")]
    {
        check_cancel(Some(cancel))?;
        report_progress(progress, "parsing", 0, 1);
        let (iges_data, registry) =
            mmforge_geometry::occt::iges_reader::read_iges_file_with_tessellation(path)
                .map_err(|e| Error::parse("IGES", format!("OCCT read/tessellate failed: {e}")))?;

        check_cancel(Some(cancel))?;
        report_progress(progress, "building", 0, 1);
        build_iges_model_from_data(path, iges_data, registry, cancel)
    }

    #[cfg(not(feature = "occt"))]
    {
        let _ = (progress, cancel);
        let _path = path;
        Err(Error::parse(
            "IGES",
            "OCCT feature not enabled — compile with --features occt to enable IGES parsing",
        ))
    }
}

#[cfg(feature = "occt")]
pub(crate) fn build_iges_model_from_data(
    path: &Path,
    iges_data: mmforge_geometry::occt::iges_reader::IgesData,
    registry: mmforge_geometry::tessellation::TessellationRegistry,
    cancel: &CancellationToken,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{Geometry, LsmModel, Node, ParseWarning};

    let warnings: Vec<ParseWarning> = iges_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("IGES");
    model.header.source_path = Some(path.display().to_string());

    // Tree-based build when XDE assembly tree is available.
    let tree = &iges_data.tree_nodes;
    if !tree.is_empty() {
        let node_count = tree.len();
        let mut node_ids: Vec<NodeId> = Vec::with_capacity(node_count);
        let mut geom_counter: u32 = 0;
        for (i, tn) in tree.iter().enumerate() {
            check_cancel(Some(cancel))?;
            let nid = NodeId::new(i as u32);
            node_ids.push(nid);
            let parent_id = if tn.parent_index >= 0 {
                Some(node_ids[tn.parent_index as usize])
            } else {
                None
            };
            let (geom_id, label) = if tn.is_assembly {
                (None, tn.name.clone())
            } else {
                let gid = GeometryId::new(geom_counter);
                geom_counter += 1;
                let lbl = if tn.name.is_empty() {
                    format!("Part_{}", gid.get())
                } else {
                    format!("{} [{:?}]", tn.name, tn.shape_type)
                };
                (Some(gid), lbl)
            };
            let name = if tn.name.is_empty() {
                if tn.is_assembly {
                    format!("Assembly_{i}")
                } else {
                    format!("Part_{i}")
                }
            } else {
                tn.name.clone()
            };
            model.scene.add_node(Node {
                id: nid,
                name,
                parent: parent_id,
                children: Vec::new(),
                geometry: geom_id,
                material: None,
                visible: true,
                local_transform: tn.transform,
                bounds: geom_id.map_or(tn.bounds, |gid| {
                    registry.get(&gid).map_or(tn.bounds, |m| m.bounds)
                }),
            });
            if let Some(gid) = geom_id {
                model.geometries.push(Geometry::BRepHandleRef {
                    id: gid,
                    bounds: registry.get(&gid).map_or(tn.bounds, |m| m.bounds),
                    label,
                });
            }
            if let Some(pid) = parent_id {
                if let Some(pn) = model.scene.find_node_mut(pid) {
                    pn.children.push(nid);
                }
            }
        }
        if !node_ids.is_empty() {
            model.scene.root = node_ids[0];
        }
        let stats = model.stats();
        return Ok((
            ParseOutput {
                model,
                warnings,
                stats,
            },
            registry,
        ));
    }

    // Fallback: flat shapes (backward compat or no occt_found).
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
        check_cancel(Some(cancel))?;
        let child_id = NodeId::new(i as u32 + 1);
        let geom_id = GeometryId::new(i as u32);
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
            bounds: shape.bounds,
        });
        model.geometries.push(Geometry::BRepHandleRef {
            id: geom_id,
            bounds: shape.bounds,
            label: display_label,
        });
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

#[cfg(test)]
#[cfg(feature = "occt")]
mod tests {
    use super::*;
    use mmforge_core::cancel::CancellationToken;
    use mmforge_core::ids::GeometryId;
    use mmforge_core::math::BoundingBox;
    use mmforge_core::model::Geometry;
    use mmforge_geometry::occt::adapter::TreeNode;
    use mmforge_geometry::occt::iges_reader::IgesData;
    use mmforge_geometry::occt::shape::ShapeType;
    use mmforge_geometry::tessellation::{TessellatedMeshData, TessellationRegistry};
    use std::path::Path;

    /// Proves that build_iges_model_from_data uses registry post-transform
    /// mesh bounds, NOT the pre-transform tree-node bounds.
    ///
    /// Constructs mock IgesData with tn.bounds = [0,0,0]–[1,1,1] and a
    /// TessellationRegistry with mesh bounds = [10,0,0]–[20,1,1].  If the
    /// parser incorrectly used tn.bounds, Node.bounds would be the smaller
    /// box; the correct (post-bake) path uses registry bounds.
    #[test]
    fn parser_uses_registry_bounds_not_tree_node_bounds() {
        // --- Mock tree node: pre-transform bounds ---
        let tn = TreeNode {
            parent_index: -1,
            name: "TestPart".into(),
            shape_type: ShapeType::Solid,
            bounds: BoundingBox::new(
                glam::Vec3::new(0.0, 0.0, 0.0),
                glam::Vec3::new(1.0, 1.0, 1.0),
            ),
            is_assembly: false,
            transform: glam::Mat4::IDENTITY,
        };

        // --- Mock registry: post-transform bounds (different!) ---
        let mut registry = TessellationRegistry::new();
        let gid = GeometryId::new(0);
        registry.insert(
            gid,
            TessellatedMeshData {
                positions: vec![[10.0, 0.0, 0.0], [20.0, 0.0, 0.0], [10.0, 1.0, 0.0]],
                normals: vec![[0.0, 0.0, 1.0]; 3],
                indices: vec![0, 1, 2],
                bounds: BoundingBox::new(
                    glam::Vec3::new(10.0, 0.0, 0.0),
                    glam::Vec3::new(20.0, 1.0, 1.0),
                ),
            },
        );

        let iges_data = IgesData {
            shapes: vec![],
            tree_nodes: vec![tn],
            transfer_messages: vec![],
        };

        let cancel = CancellationToken::new();
        let result =
            build_iges_model_from_data(Path::new("test.igs"), iges_data, registry.clone(), &cancel);
        assert!(
            result.is_ok(),
            "build_iges_model_from_data failed: {:?}",
            result.err()
        );
        let (output, _reg) = result.unwrap();
        let model = &output.model;

        // Must have exactly 1 node.
        assert_eq!(model.scene.nodes.len(), 1, "expected 1 node");
        let node = &model.scene.nodes[0];

        // The node must have geometry.
        assert!(node.geometry.is_some(), "node must have geometry");

        // ---- THE KEY ASSERTIONS ----
        // Node.bounds must equal registry mesh bounds (post-transform),
        // NOT tn.bounds (pre-transform [0,0,0]–[1,1,1]).
        let reg_mesh = registry.get(&gid).expect("mesh in registry");
        assert_eq!(
            node.bounds.min, reg_mesh.bounds.min,
            "Node.bounds.min must match registry mesh bounds (post-transform)"
        );
        assert_eq!(
            node.bounds.max, reg_mesh.bounds.max,
            "Node.bounds.max must match registry mesh bounds (post-transform)"
        );

        // Geometry.bounds must also match registry.
        assert_eq!(model.geometries.len(), 1, "expected 1 geometry");
        match &model.geometries[0] {
            Geometry::BRepHandleRef { bounds, .. } => {
                assert_eq!(
                    bounds.min, reg_mesh.bounds.min,
                    "Geometry.bounds.min must match registry"
                );
                assert_eq!(
                    bounds.max, reg_mesh.bounds.max,
                    "Geometry.bounds.max must match registry"
                );
            }
            _ => panic!("expected BRepHandleRef geometry"),
        }

        // Sanity: the bounds should NOT equal the pre-transform tn.bounds.
        assert_ne!(
            node.bounds.min,
            glam::Vec3::new(0.0, 0.0, 0.0),
            "bounds should differ from pre-transform tn.bounds"
        );
    }
}
