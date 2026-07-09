//! STEP parser implementation.
//!
//! When the `occt` feature is enabled, parsing delegates to OCCT's
//! `STEPControl_Reader` via [`mmforge_geometry::occt::step_reader`].
//! Without OCCT, `parse()` returns an error indicating the feature
//! is not available.

use crate::detect::detect_step;
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
            occt_parse_with_progress(path, progress, cancel)
        }

        #[cfg(not(feature = "occt"))]
        {
            let _ = (progress, cancel);
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

/// OCCT-backed parsing with progress and cancellation.
///
/// Cancellation is checked before the expensive OCCT read/tessellation
/// operation.  OCCT itself does not support mid-operation cancellation, so
/// this is a best-effort boundary check.
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
    let step_data = mmforge_geometry::occt::step_reader::read_step_file(path)
        .map_err(|e| Error::parse("STEP", format!("OCCT read failed: {e}")))?;

    check_cancel(Some(cancel))?;
    report_progress(progress, "building", 0, 1);
    let mut warnings: Vec<ParseWarning> = step_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("STEP");
    model.header.source_path = Some(path.display().to_string());

    // Tree-based build when XDE assembly tree is available.
    let tree = &step_data.tree_nodes;
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
                } else { None };
                let (geom_id, label) = if tn.is_assembly {
                    (None, tn.name.clone())
                } else {
                    let gid = GeometryId::new(geom_counter);
                    geom_counter += 1;
                    let lbl = if tn.name.is_empty() { format!("Part_{}", gid.get()) }
                              else { format!("{} [{:?}]", tn.name, tn.shape_type) };
                    (Some(gid), lbl)
                };
                let name = if tn.name.is_empty() {
                    if tn.is_assembly { format!("Assembly_{i}") } else { format!("Part_{i}") }
                } else { tn.name.clone() };
                model.scene.add_node(Node {
                    id: nid, name, parent: parent_id, children: Vec::new(),
                    geometry: geom_id, material: None, visible: true,
                    local_transform: tn.transform, bounds: tn.bounds,
                });
                if let Some(gid) = geom_id {
                    model.geometries.push(Geometry::BRepHandleRef { id: gid, bounds: tn.bounds, label });
                }
                if let Some(pid) = parent_id {
                    if let Some(pn) = model.scene.find_node_mut(pid) { pn.children.push(nid); }
                }
            }
            if !node_ids.is_empty() { model.scene.root = node_ids[0]; }
            let stats = model.stats();
            return Ok(ParseOutput { model, warnings, stats });
        }

    // Fallback: flat shapes (backward compat or no occt_found).
    let shapes = mmforge_geometry::occt::step_reader::extract_shapes(&step_data)
        .map_err(|e| Error::parse("STEP", format!("OCCT shape extraction failed: {e}")))?;

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
                message: format!("shape {i} has no STEP product name, using fallback"),
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

/// Parse a STEP file and tessellate all B-Rep shapes in one pass.
///
/// Returns both the [`ParseOutput`] (model + warnings + stats) and a
/// [`TessellationRegistry`] mapping `GeometryId` → tessellated mesh data.
///
/// The tessellation happens while the OCCT reader is still alive, so
/// the mesh data is fully populated and ready for `RenderPacket` building.
///
/// # Errors
///
/// Returns an error if OCCT is not available, the file cannot be read,
/// or tessellation fails.
pub fn parse_step_with_tessellation(
    path: &Path,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    parse_step_with_tessellation_with_progress(path, None, &CancellationToken::new())
}

/// Parse a STEP file with optional progress reporting and cancellation.
///
/// Cancellation is checked before the expensive OCCT read/tessellation
/// and between shapes.  OCCT does not support mid-operation cancellation,
/// so this is a best-effort boundary check.
pub fn parse_step_with_tessellation_with_progress(
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
        // Read STEP + tessellate in one pass (reader alive during tessellation).
        let (step_data, registry) =
            mmforge_geometry::occt::step_reader::read_step_file_with_tessellation(path)
                .map_err(|e| Error::parse("STEP", format!("OCCT read/tessellate failed: {e}")))?;

        check_cancel(Some(cancel))?;
        report_progress(progress, "building", 0, 1);
        build_step_model_from_data(path, step_data, registry, cancel)
    }

    #[cfg(not(feature = "occt"))]
    {
        let _ = (progress, cancel);
        let _path = path;
        Err(Error::parse(
            "STEP",
            "OCCT feature not enabled — compile with --features occt to enable STEP parsing",
        ))
    }
}

#[cfg(feature = "occt")]
fn build_step_model_from_data(
    path: &Path,
    step_data: mmforge_geometry::occt::step_reader::StepData,
    registry: mmforge_geometry::tessellation::TessellationRegistry,
    cancel: &CancellationToken,
) -> mmforge_core::error::Result<(
    ParseOutput,
    mmforge_geometry::tessellation::TessellationRegistry,
)> {
    use mmforge_core::ids::{GeometryId, NodeId};
    use mmforge_core::model::{Geometry, LsmModel, Node, ParseWarning};

    // Convert transfer messages to warnings.
    let mut warnings: Vec<ParseWarning> = step_data
        .transfer_messages
        .iter()
        .map(|msg| ParseWarning::PrecisionLoss {
            message: format!("OCCT: {msg}"),
        })
        .collect();

    let mut model = LsmModel::empty("STEP");
    model.header.source_path = Some(path.display().to_string());

    // Tree-based build when XDE assembly tree is available.
    let tree = &step_data.tree_nodes;
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
                    if tn.is_assembly { format!("Assembly_{i}") } else { format!("Part_{i}") }
                } else { tn.name.clone() };
                model.scene.add_node(Node {
                    id: nid, name, parent: parent_id, children: Vec::new(),
                    geometry: geom_id, material: None, visible: true,
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

            if !node_ids.is_empty() { model.scene.root = node_ids[0]; }

            for (i, tn) in tree.iter().enumerate() {
                if tn.name.is_empty() {
                    warnings.push(ParseWarning::PrecisionLoss {
                        message: format!(
                            "tree node {i} ({}) has no product name",
                            if tn.is_assembly { "assembly" } else { "part" }
                        ),
                    });
                }
            }

            let stats = model.stats();
            return Ok((ParseOutput { model, warnings, stats }, registry));
        }

    // Fallback: flat shapes (backward compat or no occt_found).
    let shapes = mmforge_geometry::occt::step_reader::extract_shapes(&step_data)
        .map_err(|e| Error::parse("STEP", format!("shape extraction failed: {e}")))?;

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

        // Root node must exist with valid bounds.
        let root = model
            .scene
            .find_node(model.scene.root)
            .expect("root node must exist");
        assert!(
            root.bounds.is_valid() || !root.children.is_empty(),
            "root must have valid bounds or children"
        );

        // Must have at least one leaf node with geometry.
        let leaf_count = model
            .scene
            .nodes
            .iter()
            .filter(|n| n.geometry.is_some())
            .count();
        assert!(leaf_count > 0, "expected at least one leaf node with geometry");

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

    /// Full pipeline E2E: STEP → parse+tessellate → RenderPacket → debug JSON.
    ///
    /// Verifies the complete data flow from STEP file through tessellation
    /// to platform-neutral RenderPacket output.
    #[cfg(occt_found)]
    #[test]
    fn e2e_step_tessellation_to_renderpacket() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("mmforge-geometry")
            .join("testdata")
            .join("PQ-04909-A.STEP");

        assert!(
            fixture.exists(),
            "STEP fixture missing at {}",
            fixture.display()
        );

        // Parse + tessellate in one pass.
        let (output, registry) = crate::parse_step_with_tessellation(&fixture)
            .expect("parse_step_with_tessellation should succeed");

        let model = &output.model;

        // Registry must have mesh data for each geometry.
        assert!(
            !registry.is_empty(),
            "tessellation registry should not be empty"
        );
        assert_eq!(
            registry.len(),
            model.geometries.len(),
            "registry size should match geometry count"
        );

        // Every BRepHandleRef must have corresponding mesh data.
        for geom in &model.geometries {
            if let mmforge_core::model::Geometry::BRepHandleRef { id, .. } = geom {
                let mesh = registry.get(id).expect("geometry should be in registry");
                assert!(mesh.vertex_count() > 0, "mesh should have vertices");
                assert!(mesh.triangle_count() > 0, "mesh should have triangles");
                assert!(mesh.bounds.is_valid(), "mesh bounds should be valid");
            }
        }

        // Build RenderPacket from registry.
        let packet = mmforge_render::build_render_packet(&registry);

        // Verify RenderPacket structure.
        assert!(!packet.is_empty(), "RenderPacket should not be empty");
        assert_eq!(packet.meshes.len(), registry.len());
        assert_eq!(packet.instances.len(), registry.len());
        assert_eq!(packet.materials.len(), 1); // default material
        assert!(packet.stats.triangle_count > 0);
        assert!(packet.scene_bounds.is_valid());

        // Verify debug JSON is valid and contains expected fields.
        let json = packet.to_debug_json();
        assert!(json.contains("stats"));
        assert!(json.contains("mesh_count"));
        assert!(json.contains("triangle_count"));

        // Print diagnostics.
        eprintln!(
            "E2E pipeline: {} nodes, {} geometries, {} meshes, {} triangles",
            output.stats.node_count,
            output.stats.geometry_count,
            packet.meshes.len(),
            packet.stats.triangle_count,
        );
        eprintln!("  scene_bounds={:?}", packet.scene_bounds);
        eprintln!("  debug_json={}", json);
    }
}
