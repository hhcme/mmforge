//! B-Rep shape handle — opaque reference to a shape managed by OCCT (Phase 1).
//!
//! In Phase 0 this is a placeholder.  When OCCT is integrated the inner
//! type will hold a safe wrapper around `TopoDS_Shape`.

use mmforge_core::ids::GeometryId;
use mmforge_core::math::BoundingBox;

/// Opaque handle to a B-Rep shape.
///
/// The actual OCCT pointer is hidden behind this struct.  Core and
/// render crates never see raw C++ pointers.
#[derive(Debug, Clone)]
pub struct BRepHandle {
    pub id: GeometryId,
    pub label: String,
    pub bounds: BoundingBox,
}

impl BRepHandle {
    pub fn new(id: GeometryId, label: impl Into<String>, bounds: BoundingBox) -> Self {
        Self {
            id,
            label: label.into(),
            bounds,
        }
    }
}
