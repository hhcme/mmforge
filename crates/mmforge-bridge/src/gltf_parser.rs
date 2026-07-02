//! glTF/GLB parser using the `gltf` crate.
//!
//! Produces an `LsmModel` with scene tree from glTF nodes, and a
//! `TessellationRegistry` with mesh data (already triangulated).

use std::path::Path;

use base64::Engine;

use glam::{Mat4, Quat, Vec3};
use mmforge_core::cancel::CancellationToken;
use mmforge_core::error::{Error, Result};
use mmforge_core::ids::{GeometryId, MaterialId, NodeId};
use mmforge_core::math::BoundingBox;
use mmforge_core::model::{
    Geometry, LsmModel, Material as LsmMaterial, MeshGeometry, Node as LsmNode, ParseOutput,
    ParseStats, ParseWarning,
};
use mmforge_core::progress::{ParseProgress, ProgressCallback};
use mmforge_geometry::tessellation::{TessellatedMeshData, TessellationRegistry};

/// Detect if a file is glTF/GLB.
pub fn detect_gltf(header: &[u8], path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // GLB: magic "glTF" (0x46546C67).
    if header.len() >= 4 && &header[..4] == b"glTF" {
        return true;
    }

    // glTF JSON: starts with '{' and extension is gltf.
    if header.first() == Some(&b'{') && (ext == "gltf" || ext == "glb") {
        return true;
    }

    false
}

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

fn check_cancel(cancel: Option<&CancellationToken>) -> Result<()> {
    if cancel.is_some_and(|c| c.is_cancelled()) {
        return Err(Error::Cancelled);
    }
    Ok(())
}

/// Parse a glTF/GLB file into a model + tessellation registry.
pub fn parse_gltf(path: &Path) -> Result<(ParseOutput, TessellationRegistry)> {
    parse_gltf_with_progress(path, None, None)
}

/// Parse a glTF/GLB file with optional progress reporting and cancellation.
///
/// Cancellation is checked at file read, during buffer loading, during
/// scene/material processing, and inside `extract_primitive` for large
/// meshes.
pub fn parse_gltf_with_progress(
    path: &Path,
    progress: Option<&ProgressCallback>,
    cancel: Option<&CancellationToken>,
) -> Result<(ParseOutput, TessellationRegistry)> {
    check_cancel(cancel)?;
    report_progress(progress, "reading", 0, 0);
    let gltf_data = std::fs::read(path).map_err(Error::Io)?;

    check_cancel(cancel)?;
    report_progress(progress, "parsing", 0, 1);
    let gltf = gltf::Gltf::from_slice(&gltf_data)
        .map_err(|e| Error::parse("glTF", format!("failed to parse: {e}")))?;

    // Load blob data (GLB embedded or external .bin).
    let blob = gltf.blob.as_deref().unwrap_or(&[]);
    let mut buffers: Vec<Vec<u8>> = Vec::new();

    // For GLB, the first buffer is the blob.
    if !blob.is_empty() {
        buffers.push(blob.to_vec());
    }

    // Load external buffers.
    let mut warnings: Vec<ParseWarning> = Vec::new();
    let base_dir = path.parent().unwrap_or(Path::new("."));
    for buf in gltf.buffers() {
        check_cancel(cancel)?;
        match buf.source() {
            gltf::buffer::Source::Uri(uri) => {
                if uri.starts_with("data:") {
                    // Data URI: data:<mediatype>;base64,<data>
                    match decode_data_uri(uri) {
                        Ok(data) => buffers.push(data),
                        Err(e) => {
                            warnings.push(ParseWarning::PrecisionLoss {
                                message: format!(
                                    "buffer {}: data URI decode failed: {e}",
                                    buf.index()
                                ),
                            });
                            buffers.push(Vec::new());
                        }
                    }
                } else {
                    let buf_path = base_dir.join(uri);
                    match std::fs::read(&buf_path) {
                        Ok(data) => buffers.push(data),
                        Err(e) => {
                            warnings.push(ParseWarning::PrecisionLoss {
                                message: format!(
                                    "buffer {}: cannot read '{}': {e}",
                                    buf.index(),
                                    uri
                                ),
                            });
                            buffers.push(Vec::new());
                        }
                    }
                }
            }
            gltf::buffer::Source::Bin => {
                // Already handled via blob.
                if buffers.len() < buf.index() + 1 {
                    buffers.push(blob.to_vec());
                }
            }
        }
    }

    let mut model = LsmModel::empty("glTF");
    model.header.source_path = Some(path.display().to_string());

    let mut registry = TessellationRegistry::new();
    let mut next_node_id = 0u32;
    let mut next_geom_id = 0u32;
    let mut total_triangles = 0usize;

    // Collect materials.
    let mut materials = Vec::new();
    for mat in gltf.materials() {
        check_cancel(cancel)?;
        let pbr = mat.pbr_metallic_roughness();
        let base = pbr.base_color_factor();
        let name = mat.name().unwrap_or("Material").to_string();
        let id = MaterialId::new(materials.len() as u32);
        materials.push(LsmMaterial {
            id,
            name,
            base_color: base,
            metallic: pbr.metallic_factor(),
            roughness: pbr.roughness_factor(),
        });
    }
    model.materials = materials;

    // Process scenes.
    let mut scene_bounds = BoundingBox::EMPTY;

    for scene in gltf.scenes() {
        for node in scene.nodes() {
            check_cancel(cancel)?;
            process_gltf_node(
                &node,
                Mat4::IDENTITY,
                &buffers,
                &mut model,
                &mut registry,
                &mut next_node_id,
                &mut next_geom_id,
                &mut scene_bounds,
                &mut total_triangles,
                &mut warnings,
                None,
                cancel,
            );
        }
    }

    check_cancel(cancel)?;
    report_progress(progress, "building", 0, 1);

    // --- Fix multi-root: create synthetic assembly root if needed ---
    let orphan_root_ids: Vec<NodeId> = model
        .scene
        .nodes
        .iter()
        .filter(|n| n.parent.is_none())
        .map(|n| n.id)
        .collect();

    if orphan_root_ids.len() > 1 {
        let assembly_id = NodeId::new(next_node_id);
        #[allow(unused_assignments)]
        {
            next_node_id += 1;
        }
        model.scene.add_node(LsmNode {
            id: assembly_id,
            name: "glTF_Assembly".to_string(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: Mat4::IDENTITY,
            bounds: scene_bounds,
        });
        // Make the assembly the scene root.
        model.scene.root = assembly_id;
        // Re-parent each orphan root under the assembly.
        for root_id in &orphan_root_ids {
            if let Some(node) = model.scene.find_node_mut(*root_id) {
                node.parent = Some(assembly_id);
            }
            if let Some(assembly) = model.scene.find_node_mut(assembly_id) {
                assembly.children.push(*root_id);
            }
        }
    } else if orphan_root_ids.len() == 1 {
        // Single root — propagate scene bounds to it.
        if let Some(node) = model.scene.find_node_mut(orphan_root_ids[0]) {
            node.bounds = scene_bounds;
        }
    }

    // --- Validate structural integrity ---
    let issues = model.validate_references();
    for issue in &issues {
        warnings.push(ParseWarning::PrecisionLoss {
            message: format!("validation: {}: {}", issue.context, issue.detail),
        });
    }

    let stats = ParseStats {
        node_count: model.scene.nodes.len(),
        geometry_count: model.geometries.len(),
        material_count: model.materials.len(),
        triangle_count: total_triangles,
        parse_duration_ms: 0,
    };

    Ok((
        ParseOutput {
            model,
            warnings,
            stats,
        },
        registry,
    ))
}

#[allow(clippy::too_many_arguments)]
fn process_gltf_node(
    node: &gltf::Node,
    parent_transform: Mat4,
    buffers: &[Vec<u8>],
    model: &mut LsmModel,
    registry: &mut TessellationRegistry,
    next_node_id: &mut u32,
    next_geom_id: &mut u32,
    scene_bounds: &mut BoundingBox,
    total_triangles: &mut usize,
    warnings: &mut Vec<ParseWarning>,
    parent_id: Option<NodeId>,
    cancel: Option<&CancellationToken>,
) {
    let node_id = NodeId::new(*next_node_id);
    *next_node_id += 1;

    // Compute local transform.
    let local_transform = gltf_transform_to_mat4(&node.transform());
    let world_transform = parent_transform * local_transform;

    let node_name = node
        .name()
        .unwrap_or(&format!("Node_{}", node_id.get()))
        .to_string();

    let mut node_bounds = BoundingBox::EMPTY;
    let mut geometry_id = None;

    // Process meshes on this node.
    // Count primitives first to decide single vs multi-primitive strategy.
    let prim_count = node.mesh().map(|m| m.primitives().count()).unwrap_or(0);

    // Collect primitive data first.  For multi-primitive meshes we defer
    // child-node creation until after the parent node exists in the tree.
    struct PrimData {
        geom_id: GeometryId,
        bounds: BoundingBox,
        prim_idx: usize,
    }
    let mut prim_results: Vec<PrimData> = Vec::new();

    if let Some(mesh) = node.mesh() {
        for (prim_idx, primitive) in mesh.primitives().enumerate() {
            let geom_id = GeometryId::new(*next_geom_id);
            *next_geom_id += 1;

            match extract_primitive(&primitive, buffers, world_transform, cancel) {
                Ok((positions, normals, indices, bounds)) => {
                    let tri_count = indices.len() / 3;
                    *total_triangles += tri_count;
                    scene_bounds.extend(bounds);
                    node_bounds.extend(bounds);

                    // Convert flat Vec<f32> → Vec<[f32; 3]>.
                    let positions3: Vec<[f32; 3]> =
                        positions.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
                    let normals3: Vec<[f32; 3]> =
                        normals.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();

                    let mesh_geom = MeshGeometry {
                        id: geom_id,
                        positions: positions3.clone(),
                        normals: normals3.clone(),
                        uvs: Vec::new(),
                        indices: indices.clone(),
                        bounds,
                    };

                    model.geometries.push(Geometry::Mesh(mesh_geom));
                    registry.insert(
                        geom_id,
                        TessellatedMeshData {
                            positions: positions3,
                            normals: normals3,
                            indices,
                            bounds,
                        },
                    );

                    if prim_count == 1 {
                        geometry_id = Some(geom_id);
                    }
                    prim_results.push(PrimData {
                        geom_id,
                        bounds,
                        prim_idx,
                    });
                }
                Err(e) => {
                    warnings.push(ParseWarning::PrecisionLoss {
                        message: format!("mesh primitive {prim_idx}: {e}"),
                    });
                }
            }
        }
    }

    // Create model node.  For multi-primitive meshes the parent node
    // has no geometry — each primitive becomes a child node.
    let lsm_node = LsmNode {
        id: node_id,
        name: node_name.clone(),
        parent: parent_id,
        children: Vec::new(),
        geometry: if prim_count <= 1 { geometry_id } else { None },
        material: None,
        visible: true,
        local_transform: world_transform,
        bounds: node_bounds,
    };
    model.scene.add_node(lsm_node);

    // Now add primitive child nodes (parent exists in tree, so add_node
    // will correctly link parent↔child).
    if prim_count > 1 {
        for pd in &prim_results {
            let child_id = NodeId::new(*next_node_id);
            *next_node_id += 1;
            let child_name = format!("{}_prim{}", node_name, pd.prim_idx);
            model.scene.add_node(LsmNode {
                id: child_id,
                name: child_name,
                parent: Some(node_id),
                children: Vec::new(),
                geometry: Some(pd.geom_id),
                material: None,
                visible: true,
                local_transform: Mat4::IDENTITY,
                bounds: pd.bounds,
            });
        }
    }

    // Process children.
    for child in node.children() {
        process_gltf_node(
            &child,
            world_transform,
            buffers,
            model,
            registry,
            next_node_id,
            next_geom_id,
            scene_bounds,
            total_triangles,
            warnings,
            Some(node_id),
            cancel,
        );
    }
}

fn gltf_transform_to_mat4(transform: &gltf::scene::Transform) -> Mat4 {
    match transform {
        gltf::scene::Transform::Matrix { matrix } => {
            // gltf matrix is [[f32; 4]; 4] (row-major), glam expects [f32; 16] (column-major).
            // Transpose: row-major m[row][col] → column-major flat[col*4 + row].
            let m = *matrix;
            let mut flat = [0.0f32; 16];
            for row in 0..4 {
                for col in 0..4 {
                    flat[col * 4 + row] = m[row][col];
                }
            }
            Mat4::from_cols_array(&flat)
        }
        gltf::scene::Transform::Decomposed {
            translation,
            rotation,
            scale,
        } => {
            let t = Vec3::new(translation[0], translation[1], translation[2]);
            let r = Quat::from_xyzw(rotation[0], rotation[1], rotation[2], rotation[3]);
            let s = Vec3::new(scale[0], scale[1], scale[2]);
            Mat4::from_scale_rotation_translation(s, r, t)
        }
    }
}

#[allow(clippy::type_complexity)]
fn extract_primitive(
    primitive: &gltf::Primitive,
    buffers: &[Vec<u8>],
    transform: Mat4,
    cancel: Option<&CancellationToken>,
) -> Result<(Vec<f32>, Vec<f32>, Vec<u32>, BoundingBox)> {
    let reader = primitive.reader(|buffer| buffers.get(buffer.index()).map(|b| b.as_slice()));

    // Read positions.
    let positions_iter = reader
        .read_positions()
        .ok_or_else(|| Error::parse("glTF", "primitive has no positions"))?;
    let raw_positions: Vec<[f32; 3]> = positions_iter.collect();

    // Transform positions.
    let mut positions = Vec::with_capacity(raw_positions.len() * 3);
    let mut bounds = BoundingBox::EMPTY;
    for (idx, p) in raw_positions.iter().enumerate() {
        // Check cancellation every 1024 vertices to keep overhead low.
        if idx % 1024 == 0 {
            check_cancel(cancel)?;
        }
        let v = transform.transform_point3(Vec3::new(p[0], p[1], p[2]));
        positions.extend_from_slice(&[v.x, v.y, v.z]);
        bounds.extend_point(v);
    }

    // Read normals (optional).
    let normals = if let Some(normals_iter) = reader.read_normals() {
        let mut norms = Vec::with_capacity(raw_positions.len() * 3);
        for (idx, n) in normals_iter.enumerate() {
            if idx % 1024 == 0 {
                check_cancel(cancel)?;
            }
            let v = transform.transform_vector3(Vec3::new(n[0], n[1], n[2]));
            norms.extend_from_slice(&[v.x, v.y, v.z]);
        }
        norms
    } else {
        // Generate default up normals.
        let mut norms = Vec::with_capacity(raw_positions.len() * 3);
        for _ in 0..raw_positions.len() {
            norms.extend_from_slice(&[0.0, 1.0, 0.0]);
        }
        norms
    };

    // Read indices.
    let indices: Vec<u32> = if let Some(indices_iter) = reader.read_indices() {
        indices_iter.into_u32().collect()
    } else {
        // Non-indexed: generate sequential indices.
        (0..raw_positions.len() as u32).collect()
    };

    Ok((positions, normals, indices, bounds))
}

/// Decode a `data:` URI (e.g. `data:application/octet-stream;base64,...`).
fn decode_data_uri(uri: &str) -> Result<Vec<u8>> {
    let b64_start = uri
        .find(";base64,")
        .ok_or_else(|| Error::parse("glTF", "data URI missing ';base64,' marker"))?;
    let b64_data = &uri[b64_start + 8..];
    base64::engine::general_purpose::STANDARD
        .decode(b64_data)
        .map_err(|e| Error::parse("glTF", format!("base64 decode: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_glb_magic() {
        let header = b"glTF\x02\x00\x00\x00";
        assert!(detect_gltf(header, &p("model.glb")));
    }

    #[test]
    fn detect_gltf_json_header() {
        let header = b"{\"asset\":{\"version\":\"2.0\"}";
        assert!(detect_gltf(header, &p("model.gltf")));
    }

    #[test]
    fn reject_gltf_json_with_wrong_extension() {
        let header = b"{\"asset\":{\"version\":\"2.0\"}";
        assert!(!detect_gltf(header, &p("model.json")));
    }

    #[test]
    fn reject_glb_with_wrong_magic() {
        let header = b"NOT_GLTF_DATA";
        assert!(!detect_gltf(header, &p("model.glb")));
    }

    #[test]
    fn reject_non_gltf_data() {
        let header = b"ISO-10303-21;\nHEADER;\n";
        assert!(!detect_gltf(header, &p("model.gltf")));
    }

    // --- Fixture tests ---

    /// Write a glTF JSON to a temp file and return the path.
    fn write_temp_gltf(json: &str) -> tempfile::NamedTempFile {
        use std::io::Write;
        let mut f = tempfile::Builder::new().suffix(".gltf").tempfile().unwrap();
        f.write_all(json.as_bytes()).unwrap();
        f
    }

    /// Build a minimal glTF JSON with a single triangle using a data URI buffer.
    /// The triangle has vertices at (0,0,0), (1,0,0), (0,1,0) and indices [0,1,2].
    fn minimal_triangle_gltf() -> String {
        // Positions: 3 vertices * 3 floats * 4 bytes = 36 bytes
        // Indices: 3 indices * 2 bytes (uint16) = 6 bytes
        // Total buffer: 42 bytes (pad to 4-byte alignment → 44 bytes)
        let mut buf = Vec::new();
        // Vertex 0: (0, 0, 0)
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        // Vertex 1: (1, 0, 0)
        buf.extend_from_slice(&1.0f32.to_le_bytes());
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        // Vertex 2: (0, 1, 0)
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        buf.extend_from_slice(&1.0f32.to_le_bytes());
        buf.extend_from_slice(&0.0f32.to_le_bytes());
        // Indices (uint16): 0, 1, 2
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&2u16.to_le_bytes());
        // Pad to 4-byte alignment
        while buf.len() % 4 != 0 {
            buf.push(0);
        }

        let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);

        format!(
            r#"{{
  "asset": {{"version": "2.0"}},
  "scene": 0,
  "scenes": [{{"nodes": [0]}}],
  "nodes": [{{"mesh": 0, "name": "Triangle"}}],
  "meshes": [{{
    "primitives": [{{
      "attributes": {{"POSITION": 0}},
      "indices": 1
    }}]
  }}],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
      "min": [0.0, 0.0, 0.0], "max": [1.0, 1.0, 0.0]}},
    {{"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}}
  ],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": 36}},
    {{"buffer": 0, "byteOffset": 36, "byteLength": 6}}
  ],
  "buffers": [{{
    "uri": "data:application/octet-stream;base64,{b64}",
    "byteLength": {}
  }}]
}}"#,
            buf.len()
        )
    }

    #[test]
    fn parse_minimal_gltf_with_data_uri() {
        let json = minimal_triangle_gltf();
        let tmp = write_temp_gltf(&json);
        let (output, registry) = parse_gltf(tmp.path()).unwrap();

        // Should have: root node + mesh node (or assembly + root + mesh)
        assert!(!output.model.scene.nodes.is_empty());
        assert_eq!(output.model.geometries.len(), 1);
        assert_eq!(output.stats.triangle_count, 1);

        // Verify tessellation data.
        let geom_id = output.model.geometries[0].id();
        let mesh_data = registry.get(&geom_id).unwrap();
        assert_eq!(mesh_data.indices.len(), 3); // 1 triangle
        assert_eq!(mesh_data.positions.len(), 3); // 3 vertices
    }

    #[test]
    fn parse_gltf_cancellation_returns_error() {
        let token = CancellationToken::new();
        token.cancel();
        let json = minimal_triangle_gltf();
        let tmp = write_temp_gltf(&json);
        let result = parse_gltf_with_progress(tmp.path(), None, Some(&token));
        assert!(matches!(result, Err(Error::Cancelled)));
    }

    #[test]
    fn gltf_multi_root_gets_synthetic_assembly() {
        // glTF with 2 scenes, each with 1 node → 2 root nodes → synthetic assembly.
        let json = format!(
            r#"{{
  "asset": {{"version": "2.0"}},
  "scenes": [{{"nodes": [0]}}, {{"nodes": [1]}}],
  "nodes": [
    {{"name": "A"}},
    {{"name": "B"}}
  ]
}}"#
        );
        let tmp = write_temp_gltf(&json);
        let (output, _) = parse_gltf(tmp.path()).unwrap();

        // Should have synthetic assembly + A + B = 3 nodes.
        assert_eq!(output.model.scene.nodes.len(), 3);
        // The root should be the assembly.
        let root = output
            .model
            .scene
            .find_node(output.model.scene.root)
            .unwrap();
        assert_eq!(root.name, "glTF_Assembly");
        assert_eq!(root.children.len(), 2);
    }

    #[test]
    fn gltf_single_root_no_assembly() {
        let json = format!(
            r#"{{
  "asset": {{"version": "2.0"}},
  "scene": 0,
  "scenes": [{{"nodes": [0]}}],
  "nodes": [{{"name": "Solo"}}]
}}"#
        );
        let tmp = write_temp_gltf(&json);
        let (output, _) = parse_gltf(tmp.path()).unwrap();

        // Should NOT have synthetic assembly — just the single root.
        let root = output
            .model
            .scene
            .find_node(output.model.scene.root)
            .unwrap();
        assert_ne!(root.name, "glTF_Assembly");
        assert_eq!(root.name, "Solo");
    }

    #[test]
    fn decode_data_uri_valid() {
        let data = b"hello world";
        let b64 = base64::engine::general_purpose::STANDARD.encode(data);
        let uri = format!("data:application/octet-stream;base64,{b64}");
        let decoded = decode_data_uri(&uri).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn decode_data_uri_missing_marker() {
        let uri = "data:application/octet-stream,somedata";
        assert!(decode_data_uri(uri).is_err());
    }

    #[test]
    fn decode_data_uri_invalid_base64() {
        let uri = "data:application/octet-stream;base64,!!!invalid!!!";
        assert!(decode_data_uri(uri).is_err());
    }
}
