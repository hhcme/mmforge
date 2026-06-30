//! Tessellation adapter — converts B-Rep shapes to triangle meshes.
//!
//! Uses OCCT `BRepMesh_IncrementalMesh` when `occt_found` is set.
//! The tessellated mesh contains positions, normals, and indices
//! suitable for GPU upload.

use mmforge_core::math::BoundingBox;

/// Quality presets for tessellation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TessellationQuality {
    /// Fast preview: bbox diagonal x 0.002.
    Preview,
    /// Standard viewing: bbox diagonal x 0.0005.
    Standard,
    /// High quality for screenshots: bbox diagonal x 0.0001.
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

/// Tessellated mesh data — positions, normals, and indices.
///
/// Platform-neutral: can be consumed by Metal, D3D12, or Vulkan adapters.
#[derive(Debug, Clone)]
pub struct TessellatedMeshData {
    /// Vertex positions as `[x0,y0,z0, x1,y1,z1, ...]`.
    pub positions: Vec<[f32; 3]>,
    /// Vertex normals as `[nx0,ny0,nz0, ...]`.
    pub normals: Vec<[f32; 3]>,
    /// Triangle indices as `[i0,i1,i2, ...]` (0-based).
    pub indices: Vec<u32>,
    /// Axis-aligned bounding box of the tessellated mesh.
    pub bounds: BoundingBox,
}

impl TessellatedMeshData {
    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }
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

    #[test]
    fn empty_mesh_data() {
        let mesh = TessellatedMeshData {
            positions: Vec::new(),
            normals: Vec::new(),
            indices: Vec::new(),
            bounds: BoundingBox::EMPTY,
        };
        assert_eq!(mesh.vertex_count(), 0);
        assert_eq!(mesh.triangle_count(), 0);
    }
}
