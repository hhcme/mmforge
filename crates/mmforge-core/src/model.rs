//! LSM runtime model — the platform-agnostic scene representation.
//!
//! This module defines the in-memory model that every parser produces and
//! every renderer consumes.  There is **no** stable file format yet; the
//! model lives only for the duration of a session.

use crate::ids::{GeometryId, MaterialId, NodeId};
use crate::math::BoundingBox;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Top-level model
// ---------------------------------------------------------------------------

/// The root container returned by every parser.
#[derive(Debug, Clone)]
pub struct LsmModel {
    pub header: ModelHeader,
    pub scene: SceneTree,
    pub geometries: Vec<Geometry>,
    pub materials: Vec<Material>,
    pub metadata: Metadata,
}

/// Version / origin information stored in the model header.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelHeader {
    pub source_format: String,
    pub source_path: Option<String>,
    pub parser_version: String,
}

// ---------------------------------------------------------------------------
// Scene tree
// ---------------------------------------------------------------------------

/// Flat-storage scene tree.
///
/// Children are stored in a contiguous `Vec<Node>`.  Each node carries a
/// `parent` index and a `children_range` that slices into the same vector.
/// This avoids recursive structures and keeps iteration cache-friendly.
#[derive(Debug, Clone, Default)]
pub struct SceneTree {
    pub nodes: Vec<Node>,
    pub root: NodeId,
}

/// A single node in the scene tree.
#[derive(Debug, Clone)]
pub struct Node {
    pub id: NodeId,
    pub name: String,
    pub parent: Option<NodeId>,
    pub children: Vec<NodeId>,
    pub geometry: Option<GeometryId>,
    pub material: Option<MaterialId>,
    pub visible: bool,
    pub local_transform: glam::Mat4,
    pub bounds: BoundingBox,
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// A geometry entry in the model.
///
/// The first variant (`BRepHandleRef`) is a placeholder for the future OCCT
/// integration where the heavy B-Rep data lives in the geometry crate and
/// only an opaque handle is stored here.
#[derive(Debug, Clone)]
pub enum Geometry {
    /// Opaque handle to a B-Rep shape managed by `mmforge-geometry`.
    BRepHandleRef {
        id: GeometryId,
        bounds: BoundingBox,
        label: String,
    },
    /// Explicit triangle mesh.
    Mesh(MeshGeometry),
    /// Placeholder for 2D drawing geometry (Phase 4).
    Drawing2D,
}

/// Explicit triangle mesh stored directly in the model.
#[derive(Debug, Clone)]
pub struct MeshGeometry {
    pub id: GeometryId,
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub indices: Vec<u32>,
    pub bounds: BoundingBox,
}

// ---------------------------------------------------------------------------
// Material
// ---------------------------------------------------------------------------

/// A platform-neutral material definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Material {
    pub id: MaterialId,
    pub name: String,
    pub base_color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
}

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

/// Free-form metadata attached to the model.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Metadata {
    pub units: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub custom: std::collections::HashMap<String, String>,
}

// ---------------------------------------------------------------------------
// Parse output / warnings
// ---------------------------------------------------------------------------

/// The canonical output of every parser.
#[derive(Debug)]
pub struct ParseOutput {
    pub model: LsmModel,
    pub warnings: Vec<ParseWarning>,
    pub stats: ParseStats,
}

/// A non-fatal issue discovered during parsing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ParseWarning {
    UnsupportedEntity { entity_type: String, count: usize },
    MissingMaterial { node_id: NodeId },
    PrecisionLoss { message: String },
    RecoveredFromInvalidTopology { message: String },
}

/// Aggregate statistics from a parse run.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ParseStats {
    pub node_count: usize,
    pub geometry_count: usize,
    pub material_count: usize,
    pub triangle_count: usize,
    pub parse_duration_ms: u64,
}

// ---------------------------------------------------------------------------
// Builder helpers (convenience for tests and CLI)
// ---------------------------------------------------------------------------

impl LsmModel {
    /// Create an empty model with the given source format tag.
    pub fn empty(source_format: impl Into<String>) -> Self {
        Self {
            header: ModelHeader {
                source_format: source_format.into(),
                source_path: None,
                parser_version: env!("CARGO_PKG_VERSION").to_string(),
            },
            scene: SceneTree::default(),
            geometries: Vec::new(),
            materials: Vec::new(),
            metadata: Metadata::default(),
        }
    }

    /// Count total triangles across all mesh geometries.
    pub fn total_triangle_count(&self) -> usize {
        self.geometries
            .iter()
            .map(|g| match g {
                Geometry::Mesh(m) => m.indices.len() / 3,
                _ => 0,
            })
            .sum()
    }

    /// Aggregate bounding box across all geometries.
    pub fn bounds(&self) -> BoundingBox {
        let mut bb = BoundingBox::EMPTY;
        for node in &self.scene.nodes {
            if node.bounds.is_valid() {
                bb.extend(node.bounds);
            }
        }
        bb
    }
}

impl SceneTree {
    /// Find a node by id.
    pub fn find_node(&self, id: NodeId) -> Option<&Node> {
        self.nodes.iter().find(|n| n.id == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    fn sample_model() -> LsmModel {
        let mut model = LsmModel::empty("TEST");
        model.geometries.push(Geometry::Mesh(MeshGeometry {
            id: GeometryId::new(0),
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![],
            indices: vec![0, 1, 2],
            bounds: BoundingBox::new(Vec3::ZERO, Vec3::new(1.0, 1.0, 0.0)),
        }));
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: vec![NodeId::new(1)],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::new(Vec3::ZERO, Vec3::new(1.0, 1.0, 0.0)),
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: Some(GeometryId::new(0)),
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::new(Vec3::ZERO, Vec3::new(1.0, 1.0, 0.0)),
        });
        model
    }

    #[test]
    fn empty_model_creation() {
        let model = LsmModel::empty("STEP");
        assert_eq!(model.header.source_format, "STEP");
        assert_eq!(model.scene.nodes.len(), 0);
    }

    #[test]
    fn triangle_count() {
        let model = sample_model();
        assert_eq!(model.total_triangle_count(), 1);
    }

    #[test]
    fn bounds_aggregation() {
        let model = sample_model();
        let bb = model.bounds();
        assert!(bb.is_valid());
        assert_eq!(bb.center(), Vec3::new(0.5, 0.5, 0.0));
    }

    #[test]
    fn find_node() {
        let model = sample_model();
        assert!(model.scene.find_node(NodeId::new(1)).is_some());
        assert!(model.scene.find_node(NodeId::new(99)).is_none());
    }
}
