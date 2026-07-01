//! LSM runtime model — the platform-agnostic scene representation.
//!
//! This module defines the in-memory model that every parser produces and
//! every renderer consumes.  There is **no** stable file format yet; the
//! model lives only for the duration of a session.
//!
//! # Architecture contract
//!
//! - `LsmModel` is the single root container.
//! - All cross-references use typed IDs (`NodeId`, `GeometryId`, `MaterialId`).
//! - `validate_references()` detects dangling IDs, duplicate IDs,
//!   parent/children inconsistency, orphan nodes, and cycles.
//! - Tree-traversal functions guard against cycles with a visitation cap.
//! - No platform, GPU, or OCCT types appear here.

use crate::ids::{GeometryId, MaterialId, NodeId};
use crate::math::BoundingBox;
use serde::{Deserialize, Serialize};

/// Hard upper bound on parent-chain walks.  Prevents infinite loops on
/// cyclic trees.  A valid industrial model will never exceed this depth.
const MAX_WALK_DEPTH: usize = 10_000;

// ===========================================================================
// Top-level model
// ===========================================================================

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

// ===========================================================================
// Scene tree
// ===========================================================================

/// Flat-storage scene tree.
///
/// Nodes are stored in a contiguous `Vec<Node>`.  Each node carries a
/// `parent` id and a list of `children` ids.  This avoids recursive
/// structures and keeps iteration cache-friendly.
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
    /// Node-level bounding box.  Parsers MUST set this from the geometry
    /// bounds (or the union of children bounds for group nodes).
    pub bounds: BoundingBox,
}

// ===========================================================================
// Geometry
// ===========================================================================

/// A geometry entry in the model.
///
/// Every variant carries its own `GeometryId`.  There is no sentinel value
/// like `GeometryId::ZERO` — every geometry has a real, unique id assigned
/// by the parser.
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
    /// 2D drawing geometry.  Carries parsed drawing data, id, and bounds.
    Drawing2D {
        id: GeometryId,
        bounds: BoundingBox,
        drawing: Box<crate::drawing::Drawing2DGeometry>,
    },
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

// ===========================================================================
// Material
// ===========================================================================

/// A platform-neutral material definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Material {
    pub id: MaterialId,
    pub name: String,
    pub base_color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
}

// ===========================================================================
// Metadata
// ===========================================================================

/// Free-form metadata attached to the model.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Metadata {
    pub units: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub custom: std::collections::HashMap<String, String>,
}

// ===========================================================================
// Parse output / warnings
// ===========================================================================

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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParseStats {
    pub node_count: usize,
    pub geometry_count: usize,
    pub material_count: usize,
    pub triangle_count: usize,
    pub parse_duration_ms: u64,
}

// ===========================================================================
// Geometry helpers
// ===========================================================================

impl Geometry {
    /// The geometry's typed ID.  Every variant carries a real id.
    pub fn id(&self) -> GeometryId {
        match self {
            Self::BRepHandleRef { id, .. } => *id,
            Self::Mesh(m) => m.id,
            Self::Drawing2D { id, .. } => *id,
        }
    }

    /// Axis-aligned bounding box.
    pub fn bounds(&self) -> BoundingBox {
        match self {
            Self::BRepHandleRef { bounds, .. } => *bounds,
            Self::Mesh(m) => m.bounds,
            Self::Drawing2D { bounds, .. } => *bounds,
        }
    }

    /// Number of triangles (0 for BRepHandleRef and Drawing2D).
    pub fn triangle_count(&self) -> usize {
        match self {
            Self::Mesh(m) => m.indices.len() / 3,
            _ => 0,
        }
    }
}

// ===========================================================================
// SceneTree operations
// ===========================================================================

impl SceneTree {
    /// Find a node by id (linear scan).
    pub fn find_node(&self, id: NodeId) -> Option<&Node> {
        self.nodes.iter().find(|n| n.id == id)
    }

    /// Find a node by id, returning a mutable reference.
    pub fn find_node_mut(&mut self, id: NodeId) -> Option<&mut Node> {
        self.nodes.iter_mut().find(|n| n.id == id)
    }

    /// Add a node to the tree.  If `parent` is `Some`, the new node is
    /// appended to that parent's children list.  Returns the node's id.
    pub fn add_node(&mut self, node: Node) -> NodeId {
        let id = node.id;
        if let Some(parent_id) = node.parent {
            if let Some(parent) = self.find_node_mut(parent_id) {
                parent.children.push(id);
            }
        }
        if self.nodes.is_empty() {
            self.root = id;
        }
        self.nodes.push(node);
        id
    }

    /// Remove a node and all its descendants.
    ///
    /// Returns the number of nodes removed on success.
    ///
    /// Fails with [`RemoveError::NotFound`] if `id` is not in the tree,
    /// or [`RemoveError::SoleRoot`] if `id` is the only remaining node
    /// (i.e. the tree would become empty).
    ///
    /// Uses a `HashSet`-backed descendant collection so that `remove_node`
    /// is safe even on trees with duplicate-child bugs (those would be
    /// caught by `validate_references`).
    pub fn remove_node(&mut self, id: NodeId) -> std::result::Result<usize, RemoveError> {
        if self.find_node(id).is_none() {
            return Err(RemoveError::NotFound(id.get()));
        }

        // Refuse to remove the sole root.
        if self.nodes.len() == 1 && self.root == id {
            return Err(RemoveError::SoleRoot(id.get()));
        }

        // Collect all descendants (including self) into a set to deduplicate.
        let to_remove: std::collections::HashSet<NodeId> =
            self.descendants_of(id).map(|n| n.id).collect();
        let count = to_remove.len();

        // Remove from parent's children list.
        if let Some(node) = self.find_node(id) {
            if let Some(parent_id) = node.parent {
                if let Some(parent) = self.find_node_mut(parent_id) {
                    parent.children.retain(|c| !to_remove.contains(c));
                }
            }
        }

        // Remove the nodes themselves.
        self.nodes.retain(|n| !to_remove.contains(&n.id));

        // Update root if needed.
        if to_remove.contains(&self.root) {
            self.root = self.nodes.first().map_or(NodeId::ZERO, |n| n.id);
        }

        Ok(count)
    }

    /// Direct children of a node.
    pub fn children_of(&self, id: NodeId) -> impl Iterator<Item = &Node> {
        self.find_node(id).into_iter().flat_map(move |n| {
            n.children
                .iter()
                .filter_map(move |cid| self.find_node(*cid))
        })
    }

    /// Parent of a node.
    pub fn parent_of(&self, id: NodeId) -> Option<&Node> {
        self.find_node(id)
            .and_then(|n| n.parent)
            .and_then(|pid| self.find_node(pid))
    }

    /// Depth of a node (root = 0).
    ///
    /// Guards against cycles: stops after `MAX_WALK_DEPTH` hops.
    pub fn depth(&self, id: NodeId) -> usize {
        let mut depth = 0;
        let mut current = id;
        let mut visited = std::collections::HashSet::new();
        visited.insert(id);
        while let Some(node) = self.find_node(current) {
            if let Some(parent_id) = node.parent {
                if !visited.insert(parent_id) {
                    break; // cycle detected
                }
                current = parent_id;
                depth += 1;
                if depth >= MAX_WALK_DEPTH {
                    break;
                }
            } else {
                break;
            }
        }
        depth
    }

    /// Whether `ancestor` is an ancestor of (or equal to) `descendant`.
    ///
    /// Guards against cycles: stops after `MAX_WALK_DEPTH` hops.
    pub fn is_ancestor(&self, ancestor: NodeId, descendant: NodeId) -> bool {
        let mut current = descendant;
        let mut visited = std::collections::HashSet::new();
        visited.insert(descendant);
        for _ in 0..MAX_WALK_DEPTH {
            if current == ancestor {
                return true;
            }
            if let Some(node) = self.find_node(current) {
                if let Some(parent_id) = node.parent {
                    if !visited.insert(parent_id) {
                        return false; // cycle detected
                    }
                    current = parent_id;
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }
        false
    }

    /// All descendants of a node (depth-first, including self).
    ///
    /// The iterator tracks visited nodes to avoid yielding duplicates
    /// on trees with children-cycle bugs.
    pub fn descendants_of(&self, id: NodeId) -> DescendantsIter<'_> {
        DescendantsIter {
            tree: self,
            stack: vec![id],
            visited: std::collections::HashSet::new(),
        }
    }

    /// All ancestors of a node (walking up to root, including self).
    ///
    /// Guards against cycles: stops when a node is revisited.
    pub fn ancestors_of(&self, id: NodeId) -> AncestorsIter<'_> {
        AncestorsIter {
            tree: self,
            current: Some(id),
            visited: std::collections::HashSet::new(),
            exhausted: false,
        }
    }

    /// Number of nodes in the tree.
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// Whether the tree is empty.
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// Collect all node ids reachable from `start` via parent links
    /// (walking upward).  Used by validation.
    fn reachable_from_root(&self) -> std::collections::HashSet<NodeId> {
        let mut reachable = std::collections::HashSet::new();
        if self.nodes.is_empty() {
            return reachable;
        }
        // BFS from root through children
        let mut queue = std::collections::VecDeque::new();
        queue.push_back(self.root);
        reachable.insert(self.root);
        while let Some(id) = queue.pop_front() {
            if let Some(node) = self.find_node(id) {
                for &child in &node.children {
                    if reachable.insert(child) {
                        queue.push_back(child);
                    }
                }
            }
        }
        reachable
    }
}

/// Iterator over descendants (depth-first, including start node).
///
/// Tracks visited nodes to handle children cycles gracefully.
pub struct DescendantsIter<'a> {
    tree: &'a SceneTree,
    stack: Vec<NodeId>,
    visited: std::collections::HashSet<NodeId>,
}

impl<'a> Iterator for DescendantsIter<'a> {
    type Item = &'a Node;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let id = self.stack.pop()?;
            // Skip already-visited nodes (children cycle protection).
            if !self.visited.insert(id) {
                continue;
            }
            if let Some(node) = self.tree.find_node(id) {
                // Push children in reverse so we visit in order.
                for child in node.children.iter().rev() {
                    self.stack.push(*child);
                }
                return Some(node);
            }
            // Node not found; skip.
        }
    }
}

/// Iterator over ancestors (walking up to root, including start node).
///
/// Stops when a node is revisited (cycle protection).
pub struct AncestorsIter<'a> {
    tree: &'a SceneTree,
    current: Option<NodeId>,
    visited: std::collections::HashSet<NodeId>,
    exhausted: bool,
}

impl<'a> Iterator for AncestorsIter<'a> {
    type Item = &'a Node;

    fn next(&mut self) -> Option<Self::Item> {
        if self.exhausted {
            return None;
        }
        let id = self.current?;
        if !self.visited.insert(id) {
            self.exhausted = true;
            return None; // cycle
        }
        let node = self.tree.find_node(id)?;
        self.current = node.parent;
        Some(node)
    }
}

// ===========================================================================
// Validation types
// ===========================================================================

/// A structural issue found by `validate_references`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationIssue {
    pub kind: ValidationIssueKind,
    pub context: String,
    pub detail: String,
}

/// The category of a validation issue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationIssueKind {
    /// Reference to a non-existent id.
    DanglingRef,
    /// Duplicate id in the same id namespace.
    DuplicateId,
    /// A.parent=B but B.children does not contain A, or vice-versa.
    ParentChildInconsistent,
    /// A node is not reachable from the scene root.
    Orphan,
    /// A cycle was detected in the parent chain.
    Cycle,
    /// A node's children list contains the same child id more than once.
    DuplicateChildEdge,
}

impl std::fmt::Display for ValidationIssue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{:?}] {}: {}", self.kind, self.context, self.detail)
    }
}

// Backward-compatible alias.
pub type DanglingRef = ValidationIssue;

/// Error returned by [`SceneTree::remove_node`].
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RemoveError {
    /// The target node does not exist in the tree.
    #[error("NodeId({0}) not found")]
    NotFound(u32),

    /// Attempting to remove the only remaining node (the root).
    #[error("cannot remove the sole root node NodeId({0})")]
    SoleRoot(u32),
}

// ===========================================================================
// LsmModel operations
// ===========================================================================

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
        self.geometries.iter().map(|g| g.triangle_count()).sum()
    }

    /// Aggregate bounding box from scene nodes.
    ///
    /// **Rule**: this uses *node-level* bounds, not geometry-level bounds.
    /// Parsers are responsible for propagating geometry bounds into the
    /// corresponding node's `bounds` field.  This keeps the rendering
    /// path simple — it only reads node bounds — and allows group nodes
    /// to have a bounds that is the union of their children.
    pub fn bounds(&self) -> BoundingBox {
        let mut bb = BoundingBox::EMPTY;
        for node in &self.scene.nodes {
            if node.bounds.is_valid() {
                bb.extend(node.bounds);
            }
        }
        bb
    }

    /// Collect runtime statistics from the model.
    pub fn stats(&self) -> ParseStats {
        ParseStats {
            node_count: self.scene.nodes.len(),
            geometry_count: self.geometries.len(),
            material_count: self.materials.len(),
            triangle_count: self.total_triangle_count(),
            parse_duration_ms: 0,
        }
    }

    /// Validate structural integrity of the model.
    ///
    /// Checks performed:
    ///
    /// 1. **Duplicate ids** — no two nodes share a `NodeId`, no two
    ///    geometries share a `GeometryId`, no two materials share a
    ///    `MaterialId`.
    /// 2. **Dangling references** — every node's `parent`, `children`,
    ///    `geometry`, and `material` refer to an existing entity; the
    ///    scene root exists in the nodes list.
    /// 3. **Parent/children reciprocity** — if A.parent = B then
    ///    B.children must contain A; if B.children contains A then
    ///    A.parent must be B.
    /// 4. **Orphan nodes** — every node must be reachable from the
    ///    scene root via child links.
    /// 5. **Cycle detection** — the parent chain of every node must
    ///    not loop back on itself.
    ///
    /// Returns a list of issues.  An empty list means structurally valid.
    pub fn validate_references(&self) -> Vec<ValidationIssue> {
        let mut issues = Vec::new();

        // --- 1. Duplicate ids ---
        Self::check_duplicate_ids(
            &self.scene.nodes.iter().map(|n| n.id).collect::<Vec<_>>(),
            "NodeId",
            &mut issues,
        );
        Self::check_duplicate_ids(
            &self.geometries.iter().map(|g| g.id()).collect::<Vec<_>>(),
            "GeometryId",
            &mut issues,
        );
        Self::check_duplicate_ids(
            &self.materials.iter().map(|m| m.id).collect::<Vec<_>>(),
            "MaterialId",
            &mut issues,
        );

        // Build lookup sets.
        let known_geometry: std::collections::HashSet<GeometryId> =
            self.geometries.iter().map(|g| g.id()).collect();
        let known_material: std::collections::HashSet<MaterialId> =
            self.materials.iter().map(|m| m.id).collect();
        let known_nodes: std::collections::HashSet<NodeId> =
            self.scene.nodes.iter().map(|n| n.id).collect();

        // --- 2. Root exists ---
        if !self.scene.nodes.is_empty() && !known_nodes.contains(&self.scene.root) {
            issues.push(ValidationIssue {
                kind: ValidationIssueKind::DanglingRef,
                context: "SceneTree.root".to_string(),
                detail: format!("NodeId({}) does not exist", self.scene.root.get()),
            });
        }

        // --- 2+3+5. Per-node checks ---
        for node in &self.scene.nodes {
            let ctx = format!("Node({})", node.id.get());

            // Dangling parent.
            if let Some(parent_id) = node.parent {
                if !known_nodes.contains(&parent_id) {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::DanglingRef,
                        context: ctx.clone(),
                        detail: format!("parent NodeId({}) does not exist", parent_id.get()),
                    });
                }
                // Reciprocity: parent must list this node as child.
                if let Some(parent) = self.scene.find_node(parent_id) {
                    if !parent.children.contains(&node.id) {
                        issues.push(ValidationIssue {
                            kind: ValidationIssueKind::ParentChildInconsistent,
                            context: ctx.clone(),
                            detail: format!(
                                "parent NodeId({}) does not list NodeId({}) as child",
                                parent_id.get(),
                                node.id.get()
                            ),
                        });
                    }
                }
            }

            // Duplicate child edges.
            {
                let mut seen_children = std::collections::HashSet::new();
                for &child_id in &node.children {
                    if !seen_children.insert(child_id) {
                        issues.push(ValidationIssue {
                            kind: ValidationIssueKind::DuplicateChildEdge,
                            context: ctx.clone(),
                            detail: format!(
                                "NodeId({}) appears more than once in children list",
                                child_id.get()
                            ),
                        });
                    }
                }
            }

            // Dangling children + reciprocity.
            for &child_id in &node.children {
                if !known_nodes.contains(&child_id) {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::DanglingRef,
                        context: ctx.clone(),
                        detail: format!("child NodeId({}) does not exist", child_id.get()),
                    });
                    continue;
                }
                if let Some(child) = self.scene.find_node(child_id) {
                    if child.parent != Some(node.id) {
                        issues.push(ValidationIssue {
                            kind: ValidationIssueKind::ParentChildInconsistent,
                            context: ctx.clone(),
                            detail: format!(
                                "child NodeId({}) has parent {:?}, expected NodeId({})",
                                child_id.get(),
                                child.parent.map(|p| p.get()),
                                node.id.get()
                            ),
                        });
                    }
                }
            }

            // Dangling geometry.
            if let Some(geom_id) = node.geometry {
                if !known_geometry.contains(&geom_id) {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::DanglingRef,
                        context: ctx.clone(),
                        detail: format!("geometry GeometryId({}) does not exist", geom_id.get()),
                    });
                }
            }

            // Dangling material.
            if let Some(mat_id) = node.material {
                if !known_material.contains(&mat_id) {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::DanglingRef,
                        context: ctx.clone(),
                        detail: format!("material MaterialId({}) does not exist", mat_id.get()),
                    });
                }
            }

            // --- 5. Cycle detection in parent chain ---
            let mut visited = std::collections::HashSet::new();
            visited.insert(node.id);
            let mut walk = node.parent;
            let mut cycle_found = false;
            while let Some(pid) = walk {
                if pid == node.id {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::Cycle,
                        context: ctx.clone(),
                        detail: format!("parent chain loops back to NodeId({})", pid.get()),
                    });
                    cycle_found = true;
                    break;
                }
                if !visited.insert(pid) {
                    // Revisiting a node that isn't self = cycle in middle.
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::Cycle,
                        context: ctx.clone(),
                        detail: format!("parent chain revisits NodeId({})", pid.get()),
                    });
                    cycle_found = true;
                    break;
                }
                if let Some(pnode) = self.scene.find_node(pid) {
                    walk = pnode.parent;
                } else {
                    break; // dangling ref already caught
                }
            }
            if cycle_found {
                continue; // don't double-report
            }
        }

        // --- 4. Orphan nodes (not reachable from root) ---
        if !self.scene.nodes.is_empty() {
            let reachable = self.scene.reachable_from_root();
            for node in &self.scene.nodes {
                if !reachable.contains(&node.id) {
                    issues.push(ValidationIssue {
                        kind: ValidationIssueKind::Orphan,
                        context: format!("Node({})", node.id.get()),
                        detail: "not reachable from scene root".to_string(),
                    });
                }
            }
        }

        issues
    }

    /// Whether the model has any validation issues.
    pub fn has_validation_issues(&self) -> bool {
        !self.validate_references().is_empty()
    }

    /// Deprecated: use [`has_validation_issues`] instead.
    #[deprecated(since = "0.1.0", note = "use `has_validation_issues()` instead")]
    pub fn has_dangling_references(&self) -> bool {
        self.has_validation_issues()
    }

    /// Helper: check for duplicate ids in a list.
    fn check_duplicate_ids<T: Copy + std::fmt::Debug + std::hash::Hash + Eq>(
        ids: &[T],
        label: &str,
        issues: &mut Vec<ValidationIssue>,
    ) {
        let mut seen = std::collections::HashSet::new();
        for id in ids {
            if !seen.insert(id) {
                issues.push(ValidationIssue {
                    kind: ValidationIssueKind::DuplicateId,
                    context: format!("{label}({id:?})"),
                    detail: "duplicate id".to_string(),
                });
            }
        }
    }
}

// ===========================================================================
// ModelBuilder — convenience for tests and CLI
// ===========================================================================

/// Fluent builder for constructing `LsmModel` instances in tests.
pub struct ModelBuilder {
    model: LsmModel,
    next_node_id: u32,
    next_geom_id: u32,
    next_mat_id: u32,
}

impl ModelBuilder {
    /// Start building a model with the given source format.
    pub fn new(source_format: impl Into<String>) -> Self {
        Self {
            model: LsmModel::empty(source_format),
            next_node_id: 0,
            next_geom_id: 0,
            next_mat_id: 0,
        }
    }

    /// Add a root node and return its id.
    pub fn add_root(&mut self, name: impl Into<String>) -> NodeId {
        let id = NodeId::new(self.next_node_id);
        self.next_node_id += 1;
        let node = Node {
            id,
            name: name.into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        };
        self.model.scene.add_node(node);
        id
    }

    /// Add a child node under `parent` and return its id.
    /// If `geometry` is provided, the node's bounds are set from that geometry.
    pub fn add_child(
        &mut self,
        parent: NodeId,
        name: impl Into<String>,
        geometry: Option<GeometryId>,
        material: Option<MaterialId>,
    ) -> NodeId {
        let id = NodeId::new(self.next_node_id);
        self.next_node_id += 1;
        let bounds = geometry
            .and_then(|gid| self.model.geometries.iter().find(|g| g.id() == gid))
            .map(|g| g.bounds())
            .unwrap_or(BoundingBox::EMPTY);
        let node = Node {
            id,
            name: name.into(),
            parent: Some(parent),
            children: Vec::new(),
            geometry,
            material,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds,
        };
        self.model.scene.add_node(node);
        id
    }

    /// Add a mesh geometry and return its id.
    pub fn add_mesh(
        &mut self,
        positions: Vec<[f32; 3]>,
        normals: Vec<[f32; 3]>,
        indices: Vec<u32>,
    ) -> GeometryId {
        let id = GeometryId::new(self.next_geom_id);
        self.next_geom_id += 1;
        let mut bounds = BoundingBox::EMPTY;
        for p in &positions {
            bounds.extend_point(glam::Vec3::new(p[0], p[1], p[2]));
        }
        self.model.geometries.push(Geometry::Mesh(MeshGeometry {
            id,
            positions,
            normals,
            uvs: Vec::new(),
            indices,
            bounds,
        }));
        id
    }

    /// Add a material and return its id.
    pub fn add_material(&mut self, name: impl Into<String>, base_color: [f32; 4]) -> MaterialId {
        let id = MaterialId::new(self.next_mat_id);
        self.next_mat_id += 1;
        self.model.materials.push(Material {
            id,
            name: name.into(),
            base_color,
            metallic: 0.0,
            roughness: 0.5,
        });
        id
    }

    /// Set metadata.
    pub fn with_units(mut self, units: impl Into<String>) -> Self {
        self.model.metadata.units = Some(units.into());
        self
    }

    /// Consume the builder and return the model.
    pub fn build(self) -> LsmModel {
        self.model
    }
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    fn sample_model() -> LsmModel {
        let mut builder = ModelBuilder::new("TEST");
        let geom_id = builder.add_mesh(
            vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            vec![[0.0, 0.0, 1.0]; 3],
            vec![0, 1, 2],
        );
        let mat_id = builder.add_material("steel", [0.7, 0.7, 0.7, 1.0]);
        let root = builder.add_root("assembly");
        let _child = builder.add_child(root, "part1", Some(geom_id), Some(mat_id));
        builder.build()
    }

    // -----------------------------------------------------------------------
    // LsmModel basics
    // -----------------------------------------------------------------------

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
    }

    #[test]
    fn bounds_uses_node_bounds() {
        // Verify that bounds() reads from node.bounds, not geometry.bounds.
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "custom".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::new(Vec3::new(-5.0, -5.0, -5.0), Vec3::new(5.0, 5.0, 5.0)),
        });
        let bb = model.bounds();
        assert!(bb.is_valid());
        assert_eq!(bb.center(), Vec3::ZERO);
    }

    #[test]
    fn stats_from_model() {
        let model = sample_model();
        let stats = model.stats();
        assert_eq!(stats.node_count, 2);
        assert_eq!(stats.geometry_count, 1);
        assert_eq!(stats.material_count, 1);
        assert_eq!(stats.triangle_count, 1);
    }

    // -----------------------------------------------------------------------
    // SceneTree operations
    // -----------------------------------------------------------------------

    #[test]
    fn find_node() {
        let model = sample_model();
        assert!(model.scene.find_node(NodeId::new(0)).is_some());
        assert!(model.scene.find_node(NodeId::new(99)).is_none());
    }

    #[test]
    fn children_of() {
        let model = sample_model();
        let children: Vec<_> = model.scene.children_of(NodeId::new(0)).collect();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].name, "part1");
    }

    #[test]
    fn parent_of() {
        let model = sample_model();
        let parent = model.scene.parent_of(NodeId::new(1));
        assert!(parent.is_some());
        assert_eq!(parent.unwrap().name, "assembly");
    }

    #[test]
    fn parent_of_root_is_none() {
        let model = sample_model();
        assert!(model.scene.parent_of(NodeId::new(0)).is_none());
    }

    #[test]
    fn depth_root_is_zero() {
        let model = sample_model();
        assert_eq!(model.scene.depth(NodeId::new(0)), 0);
    }

    #[test]
    fn depth_child_is_one() {
        let model = sample_model();
        assert_eq!(model.scene.depth(NodeId::new(1)), 1);
    }

    #[test]
    fn is_ancestor_self() {
        let model = sample_model();
        assert!(model.scene.is_ancestor(NodeId::new(0), NodeId::new(0)));
    }

    #[test]
    fn is_ancestor_parent() {
        let model = sample_model();
        assert!(model.scene.is_ancestor(NodeId::new(0), NodeId::new(1)));
        assert!(!model.scene.is_ancestor(NodeId::new(1), NodeId::new(0)));
    }

    #[test]
    fn descendants_iterator() {
        let model = sample_model();
        let desc: Vec<_> = model.scene.descendants_of(NodeId::new(0)).collect();
        assert_eq!(desc.len(), 2);
        assert_eq!(desc[0].name, "assembly");
        assert_eq!(desc[1].name, "part1");
    }

    #[test]
    fn ancestors_iterator() {
        let model = sample_model();
        let anc: Vec<_> = model.scene.ancestors_of(NodeId::new(1)).collect();
        assert_eq!(anc.len(), 2);
        assert_eq!(anc[0].name, "part1");
        assert_eq!(anc[1].name, "assembly");
    }

    #[test]
    fn add_and_remove_node() {
        let mut tree = SceneTree::default();
        let root = tree.add_node(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        let child = tree.add_node(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: Some(root),
            geometry: None,
            material: None,
            children: Vec::new(),
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        assert_eq!(tree.len(), 2);

        let removed = tree.remove_node(child).unwrap();
        assert_eq!(removed, 1);
        assert_eq!(tree.len(), 1);
        assert!(tree.children_of(root).next().is_none());
    }

    #[test]
    fn remove_node_with_descendants() {
        let mut tree = SceneTree::default();
        let root = tree.add_node(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: Some(root),
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(2),
            name: "grandchild".into(),
            parent: Some(NodeId::new(1)),
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let removed = tree.remove_node(NodeId::new(1)).unwrap();
        assert_eq!(removed, 2);
        assert_eq!(tree.len(), 1);
    }

    #[test]
    fn remove_sole_root_returns_err() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let result = tree.remove_node(NodeId::new(0));
        assert_eq!(result, Err(RemoveError::SoleRoot(0)));
        assert_eq!(tree.len(), 1);
    }

    #[test]
    fn remove_nonexistent_returns_err() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let result = tree.remove_node(NodeId::new(99));
        assert_eq!(result, Err(RemoveError::NotFound(99)));
    }

    // -----------------------------------------------------------------------
    // Geometry helpers
    // -----------------------------------------------------------------------

    #[test]
    fn geometry_id_and_bounds() {
        let geom = Geometry::Mesh(MeshGeometry {
            id: GeometryId::new(5),
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![],
            uvs: vec![],
            indices: vec![0, 1, 2],
            bounds: BoundingBox::new(Vec3::ZERO, Vec3::ONE),
        });
        assert_eq!(geom.id(), GeometryId::new(5));
        assert!(geom.bounds().is_valid());
        assert_eq!(geom.triangle_count(), 1);
    }

    #[test]
    fn geometry_brep_placeholder() {
        let geom = Geometry::BRepHandleRef {
            id: GeometryId::new(10),
            bounds: BoundingBox::new(Vec3::ZERO, Vec3::new(2.0, 2.0, 2.0)),
            label: "box".into(),
        };
        assert_eq!(geom.id(), GeometryId::new(10));
        assert_eq!(geom.triangle_count(), 0);
    }

    #[test]
    fn geometry_drawing2d_has_own_id() {
        let geom = Geometry::Drawing2D {
            id: GeometryId::new(42),
            bounds: BoundingBox::new(Vec3::new(-1.0, -1.0, 0.0), Vec3::new(1.0, 1.0, 0.0)),
            drawing: Box::new(crate::drawing::Drawing2DGeometry::new()),
        };
        assert_eq!(geom.id(), GeometryId::new(42));
        assert!(geom.bounds().is_valid());
        assert_eq!(geom.triangle_count(), 0);
    }

    // -----------------------------------------------------------------------
    // validate_references — basic
    // -----------------------------------------------------------------------

    #[test]
    fn valid_model_has_no_issues() {
        let model = sample_model();
        let issues = model.validate_references();
        assert!(issues.is_empty(), "Expected no issues, got: {issues:?}");
        assert!(!model.has_validation_issues());
    }

    #[test]
    fn dangling_geometry_ref_detected() {
        let mut builder = ModelBuilder::new("TEST");
        let root = builder.add_root("root");
        builder.add_child(root, "bad_part", Some(GeometryId::new(99)), None);
        let model = builder.build();

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::DanglingRef
                    && i.detail.contains("GeometryId(99)"))
        );
    }

    #[test]
    fn dangling_material_ref_detected() {
        let mut builder = ModelBuilder::new("TEST");
        let root = builder.add_root("root");
        builder.add_child(root, "bad_part", None, Some(MaterialId::new(99)));
        let model = builder.build();

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::DanglingRef
                    && i.detail.contains("MaterialId(99)"))
        );
    }

    #[test]
    fn dangling_parent_ref_detected() {
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "orphan".into(),
            parent: Some(NodeId::new(99)),
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::DanglingRef && i.detail.contains("parent"))
        );
    }

    #[test]
    fn dangling_child_ref_detected() {
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "parent".into(),
            parent: None,
            children: vec![NodeId::new(99)],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::DanglingRef && i.detail.contains("child"))
        );
    }

    #[test]
    fn dangling_root_detected() {
        let mut model = LsmModel::empty("TEST");
        model.scene.root = NodeId::new(99);
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "only".into(),
            parent: None,
            children: Vec::new(),
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(issues.iter().any(|i| i.context.contains("SceneTree.root")));
    }

    // -----------------------------------------------------------------------
    // validate_references — duplicate ids
    // -----------------------------------------------------------------------

    #[test]
    fn duplicate_node_id_detected() {
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: None,
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(0), // duplicate!
            name: "b".into(),
            parent: None,
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(issues
            .iter()
            .any(|i| i.kind == ValidationIssueKind::DuplicateId && i.context.contains("NodeId")));
    }

    #[test]
    fn duplicate_geometry_id_detected() {
        let mut model = LsmModel::empty("TEST");
        model.geometries.push(Geometry::Mesh(MeshGeometry {
            id: GeometryId::new(1),
            positions: vec![],
            normals: vec![],
            uvs: vec![],
            indices: vec![],
            bounds: BoundingBox::EMPTY,
        }));
        model.geometries.push(Geometry::Mesh(MeshGeometry {
            id: GeometryId::new(1), // duplicate!
            positions: vec![],
            normals: vec![],
            uvs: vec![],
            indices: vec![],
            bounds: BoundingBox::EMPTY,
        }));

        let issues = model.validate_references();
        assert!(issues.iter().any(
            |i| i.kind == ValidationIssueKind::DuplicateId && i.context.contains("GeometryId")
        ));
    }

    #[test]
    fn duplicate_material_id_detected() {
        let mut model = LsmModel::empty("TEST");
        model.materials.push(Material {
            id: MaterialId::new(1),
            name: "a".into(),
            base_color: [0.0; 4],
            metallic: 0.0,
            roughness: 0.5,
        });
        model.materials.push(Material {
            id: MaterialId::new(1), // duplicate!
            name: "b".into(),
            base_color: [1.0; 4],
            metallic: 0.0,
            roughness: 0.5,
        });

        let issues = model.validate_references();
        assert!(issues.iter().any(
            |i| i.kind == ValidationIssueKind::DuplicateId && i.context.contains("MaterialId")
        ));
    }

    // -----------------------------------------------------------------------
    // validate_references — parent/children reciprocity
    // -----------------------------------------------------------------------

    #[test]
    fn parent_not_listing_child_detected() {
        // Node 1 says parent=0, but node 0's children is empty.
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "parent".into(),
            parent: None,
            children: vec![], // missing NodeId(1)
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::ParentChildInconsistent)
        );
    }

    #[test]
    fn child_with_wrong_parent_detected() {
        // Node 0 lists NodeId(1) as child, but node 1 has parent=None.
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "parent".into(),
            parent: None,
            children: vec![NodeId::new(1)],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: None, // should be Some(NodeId(0))
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::ParentChildInconsistent)
        );
    }

    // -----------------------------------------------------------------------
    // validate_references — orphan nodes
    // -----------------------------------------------------------------------

    #[test]
    fn orphan_node_detected() {
        // Node 1 has no parent and is not the root → orphan.
        let mut model = LsmModel::empty("TEST");
        model.scene.root = NodeId::new(0);
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "root".into(),
            parent: None,
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "orphan".into(),
            parent: None,
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(issues.iter().any(|i| i.kind == ValidationIssueKind::Orphan));
    }

    // -----------------------------------------------------------------------
    // validate_references — cycles
    // -----------------------------------------------------------------------

    #[test]
    fn duplicate_child_edge_detected() {
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "parent".into(),
            parent: None,
            children: vec![NodeId::new(1), NodeId::new(1)], // duplicate edge
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "child".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(
            issues
                .iter()
                .any(|i| i.kind == ValidationIssueKind::DuplicateChildEdge)
        );
    }

    #[test]
    fn has_validation_issues_reports_correctly() {
        let valid = sample_model();
        assert!(!valid.has_validation_issues());

        let mut invalid = LsmModel::empty("TEST");
        invalid.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "orphan".into(),
            parent: Some(NodeId::new(99)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        assert!(invalid.has_validation_issues());
    }

    #[test]
    fn parent_cycle_detected() {
        // Node 0 → parent=1, Node 1 → parent=0 → cycle.
        let mut model = LsmModel::empty("TEST");
        model.scene.nodes.push(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: Some(NodeId::new(1)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        model.scene.nodes.push(Node {
            id: NodeId::new(1),
            name: "b".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let issues = model.validate_references();
        assert!(issues.iter().any(|i| i.kind == ValidationIssueKind::Cycle));
    }

    // -----------------------------------------------------------------------
    // Cycle safety for traversal functions
    // -----------------------------------------------------------------------

    #[test]
    fn depth_on_cyclic_tree_terminates() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: Some(NodeId::new(1)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(1),
            name: "b".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        // Must not infinite loop.
        let d = tree.depth(NodeId::new(0));
        assert!(d <= 2); // cycles after 1 hop
    }

    #[test]
    fn is_ancestor_on_cyclic_tree_terminates() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: Some(NodeId::new(1)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(1),
            name: "b".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        // Must not infinite loop.
        let _ = tree.is_ancestor(NodeId::new(0), NodeId::new(1));
    }

    #[test]
    fn ancestors_of_on_cyclic_tree_terminates() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: Some(NodeId::new(1)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(1),
            name: "b".into(),
            parent: Some(NodeId::new(0)),
            children: vec![],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        // Must not infinite loop — should yield at most 2 unique nodes.
        let anc: Vec<_> = tree.ancestors_of(NodeId::new(0)).collect();
        assert!(anc.len() <= 2);
    }

    #[test]
    fn descendants_of_on_cyclic_children_terminates() {
        let mut tree = SceneTree::default();
        tree.add_node(Node {
            id: NodeId::new(0),
            name: "a".into(),
            parent: None,
            children: vec![NodeId::new(1)],
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });
        tree.add_node(Node {
            id: NodeId::new(1),
            name: "b".into(),
            parent: Some(NodeId::new(0)),
            children: vec![NodeId::new(0)], // cycle back
            geometry: None,
            material: None,
            visible: true,
            local_transform: glam::Mat4::IDENTITY,
            bounds: BoundingBox::EMPTY,
        });

        let desc: Vec<_> = tree.descendants_of(NodeId::new(0)).collect();
        assert_eq!(desc.len(), 2); // a, b (0 is already visited so cycle skipped)
    }

    // -----------------------------------------------------------------------
    // ModelBuilder
    // -----------------------------------------------------------------------

    #[test]
    fn builder_constructs_valid_model() {
        let mut builder = ModelBuilder::new("STEP").with_units("mm");
        let geom_id = builder.add_mesh(
            vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            vec![[0.0, 0.0, 1.0]; 3],
            vec![0, 1, 2],
        );
        let mat_id = builder.add_material("aluminum", [0.8, 0.8, 0.8, 1.0]);
        let root = builder.add_root("assembly");
        builder.add_child(root, "part1", Some(geom_id), Some(mat_id));

        let model = builder.build();
        assert_eq!(model.stats().node_count, 2);
        assert!(!model.has_validation_issues());
        assert_eq!(model.metadata.units.as_deref(), Some("mm"));
    }

    // -----------------------------------------------------------------------
    // Multi-level tree traversal
    // -----------------------------------------------------------------------

    #[test]
    fn deep_tree_traversal() {
        let mut builder = ModelBuilder::new("TEST");
        let root = builder.add_root("root");
        let l1 = builder.add_child(root, "level1", None, None);
        let l2 = builder.add_child(l1, "level2", None, None);
        let l3 = builder.add_child(l2, "level3", None, None);

        let model = builder.build();
        assert_eq!(model.scene.depth(l3), 3);
        assert!(model.scene.is_ancestor(root, l3));
        assert!(model.scene.is_ancestor(l1, l3));
        assert!(!model.scene.is_ancestor(l3, root));

        let ancestors: Vec<_> = model
            .scene
            .ancestors_of(l3)
            .map(|n| n.name.as_str())
            .collect();
        assert_eq!(ancestors, vec!["level3", "level2", "level1", "root"]);
    }

    #[test]
    fn multi_child_traversal() {
        let mut builder = ModelBuilder::new("TEST");
        let root = builder.add_root("root");
        builder.add_child(root, "a", None, None);
        builder.add_child(root, "b", None, None);
        builder.add_child(root, "c", None, None);

        let model = builder.build();
        let names: Vec<_> = model
            .scene
            .children_of(root)
            .map(|n| n.name.as_str())
            .collect();
        assert_eq!(names, vec!["a", "b", "c"]);
    }
}
