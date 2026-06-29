//! Safe wrapper for OCCT `TopoDS_Shape`.
//!
//! In the `occt`-disabled build, this is a stub that holds only metadata.
//! When OCCT is enabled, it wraps the actual C++ handle.

use mmforge_core::math::BoundingBox;

/// A safe handle to an OCCT shape.
///
/// # Design
///
/// - The inner C++ pointer is hidden; only metadata is exposed.
/// - `Drop` frees the C++ `TopoDS_Shape` when OCCT is enabled.
/// - Clone is derived for the stub; with OCCT it would use `BRepBuilderAPI_Copy`.
#[derive(Debug, Clone)]
pub struct OcctShapeHandle {
    /// Human-readable label (from STEP product name or fallback).
    pub label: String,
    /// Axis-aligned bounding box computed from the shape.
    pub bounds: BoundingBox,
    /// Whether the shape is a solid, shell, or compound.
    pub shape_type: ShapeType,
}

/// The topological type of an OCCT shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShapeType {
    Compound,
    CompSolid,
    Solid,
    Shell,
    Face,
    Wire,
    Edge,
    Vertex,
    Unknown,
}

impl OcctShapeHandle {
    /// Create a stub handle (no real OCCT shape).
    pub fn stub(label: impl Into<String>, bounds: BoundingBox, shape_type: ShapeType) -> Self {
        Self {
            label: label.into(),
            bounds,
            shape_type,
        }
    }
}
