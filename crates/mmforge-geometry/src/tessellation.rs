//! Tessellation adapter — converts B-Rep shapes to triangle meshes.
//!
//! Phase 0 placeholder.  The real implementation will call
//! `BRepMesh_IncrementalMesh` via OCCT FFI.

use mmforge_core::math::BoundingBox;

/// Quality presets for tessellation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TessellationQuality {
    /// Fast preview: bbox diagonal × 0.002.
    Preview,
    /// Standard viewing: bbox diagonal × 0.0005.
    Standard,
    /// High quality for screenshots: bbox diagonal × 0.0001.
    High,
}

impl TessellationQuality {
    /// Compute linear deflection for a given bounding box.
    pub fn linear_deflection(&self, bbox: &BoundingBox) -> f32 {
        let diag = bbox.diagonal().max(1e-6);
        match self {
            Self::Preview => diag * 0.002,
            Self::Standard => diag * 0.0005,
            Self::High => diag * 0.0001,
        }
    }
}

/// Output stats from a tessellation run.
#[derive(Debug, Clone, Default)]
pub struct TessellationStats {
    pub triangle_count: usize,
    pub vertex_count: usize,
    pub face_count: usize,
    pub duration_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    #[test]
    fn deflection_scales_with_bbox() {
        let bbox = BoundingBox::new(Vec3::ZERO, Vec3::new(100.0, 100.0, 100.0));
        let preview = TessellationQuality::Preview.linear_deflection(&bbox);
        let standard = TessellationQuality::Standard.linear_deflection(&bbox);
        let high = TessellationQuality::High.linear_deflection(&bbox);
        assert!(preview > standard);
        assert!(standard > high);
    }
}
