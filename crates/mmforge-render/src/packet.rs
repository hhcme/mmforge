//! RenderPacket — the platform-neutral rendering instruction set.

use mmforge_core::math::BoundingBox;
use serde::{Deserialize, Serialize};

/// The complete rendering payload produced from an LSM model.
#[derive(Debug, Clone, Default)]
pub struct RenderPacket {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    pub batches: Vec<RenderBatch>,
    pub scene_bounds: BoundingBox,
    pub stats: RenderStats,
}

/// A single mesh ready for GPU upload.
#[derive(Debug, Clone)]
pub struct RenderMesh {
    pub mesh_id: u32,
    pub geometry_id: u32,
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub indices: Vec<u32>,
    pub bounds: BoundingBox,
}

/// Platform-neutral material parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderMaterial {
    pub material_id: u32,
    pub name: String,
    pub base_color: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
}

/// An instance referencing a mesh + material.
#[derive(Debug, Clone)]
pub struct RenderInstance {
    pub mesh_id: u32,
    pub material_id: u32,
    pub transform: glam::Mat4,
    pub visible: bool,
}

/// A draw-call batch grouping instances by material and render state.
#[derive(Debug, Clone)]
pub struct RenderBatch {
    pub material_id: u32,
    pub instance_range: std::ops::Range<usize>,
    pub transparent: bool,
}

/// Aggregate rendering statistics.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RenderStats {
    pub mesh_count: usize,
    pub instance_count: usize,
    pub triangle_count: usize,
    pub batch_count: usize,
}

impl RenderPacket {
    /// Whether the packet contains anything to render.
    pub fn is_empty(&self) -> bool {
        self.meshes.is_empty()
    }

    /// Serialize to JSON for CLI debugging.
    pub fn to_debug_json(&self) -> String {
        serde_json::to_string_pretty(&serde_json::json!({
            "stats": self.stats,
            "scene_bounds": {
                "min": [self.scene_bounds.min.x, self.scene_bounds.min.y, self.scene_bounds.min.z],
                "max": [self.scene_bounds.max.x, self.scene_bounds.max.y, self.scene_bounds.max.z],
            },
            "mesh_count": self.meshes.len(),
            "material_count": self.materials.len(),
            "batch_count": self.batches.len(),
        }))
        .unwrap_or_else(|_| "{}".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_packet() {
        let pkt = RenderPacket::default();
        assert!(pkt.is_empty());
        assert_eq!(pkt.stats.mesh_count, 0);
    }

    #[test]
    fn debug_json_output() {
        let pkt = RenderPacket::default();
        let json = pkt.to_debug_json();
        assert!(json.contains("mesh_count"));
    }
}
