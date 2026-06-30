//! RenderPacket builder — converts tessellated mesh data into a
//! platform-neutral RenderPacket for GPU upload.

use std::collections::HashMap;

use mmforge_core::ids::GeometryId;
use mmforge_core::math::BoundingBox;
use mmforge_geometry::tessellation::TessellatedMeshData;

use crate::packet::{RenderBatch, RenderMaterial, RenderMesh, RenderPacket, RenderStats};

/// Build a RenderPacket from tessellated mesh data.
///
/// Each entry in `mesh_data` maps a `GeometryId` to its tessellated
/// mesh.  The builder creates one `RenderMesh` per geometry, one
/// default `RenderMaterial`, one `RenderInstance` per mesh, and one
/// `RenderBatch`.
pub fn build_render_packet(mesh_data: &HashMap<GeometryId, TessellatedMeshData>) -> RenderPacket {
    let mut meshes = Vec::with_capacity(mesh_data.len());
    let mut instances = Vec::with_capacity(mesh_data.len());
    let mut scene_bounds = BoundingBox::EMPTY;
    let mut total_triangles = 0usize;

    // Default material (steel-grey).
    let materials = vec![RenderMaterial {
        material_id: 0,
        name: "Default".to_string(),
        base_color: [0.7, 0.7, 0.72, 1.0],
        metallic: 0.1,
        roughness: 0.5,
    }];

    for (i, (_geom_id, mesh)) in mesh_data.iter().enumerate() {
        let mesh_id = i as u32;

        // Convert f32 arrays to the format RenderMesh expects.
        let positions: Vec<[f32; 3]> = mesh.positions.clone();
        let normals: Vec<[f32; 3]> = mesh.normals.clone();
        let indices: Vec<u32> = mesh.indices.clone();

        total_triangles += indices.len() / 3;

        if mesh.bounds.is_valid() {
            scene_bounds.extend(mesh.bounds);
        }

        meshes.push(RenderMesh {
            mesh_id,
            positions,
            normals,
            uvs: Vec::new(),
            indices,
            bounds: mesh.bounds,
        });

        instances.push(crate::packet::RenderInstance {
            mesh_id,
            material_id: 0,
            transform: glam::Mat4::IDENTITY,
            visible: true,
        });
    }

    let batches = if !instances.is_empty() {
        vec![RenderBatch {
            material_id: 0,
            instance_range: 0..instances.len(),
            transparent: false,
        }]
    } else {
        Vec::new()
    };

    RenderPacket {
        meshes,
        materials,
        instances,
        batches,
        scene_bounds,
        stats: RenderStats {
            mesh_count: mesh_data.len(),
            instance_count: mesh_data.len(),
            triangle_count: total_triangles,
            batch_count: 1,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    #[test]
    fn build_from_empty_mesh_data() {
        let data = HashMap::new();
        let pkt = build_render_packet(&data);
        assert!(pkt.is_empty());
        assert_eq!(pkt.stats.triangle_count, 0);
    }

    #[test]
    fn build_from_single_mesh() {
        let mut data = HashMap::new();
        data.insert(
            GeometryId::new(0),
            TessellatedMeshData {
                positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
                normals: vec![[0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
                indices: vec![0, 1, 2],
                bounds: BoundingBox::new(Vec3::ZERO, Vec3::new(1.0, 1.0, 0.0)),
            },
        );

        let pkt = build_render_packet(&data);
        assert_eq!(pkt.meshes.len(), 1);
        assert_eq!(pkt.instances.len(), 1);
        assert_eq!(pkt.materials.len(), 1);
        assert_eq!(pkt.stats.triangle_count, 1);
        assert!(pkt.scene_bounds.is_valid());
        assert!(!pkt.is_empty());
    }

    #[test]
    fn debug_json_contains_stats() {
        let mut data = HashMap::new();
        data.insert(
            GeometryId::new(0),
            TessellatedMeshData {
                positions: vec![[0.0, 0.0, 0.0]; 3],
                normals: vec![[0.0, 0.0, 1.0]; 3],
                indices: vec![0, 1, 2],
                bounds: BoundingBox::new(Vec3::ZERO, Vec3::ONE),
            },
        );

        let pkt = build_render_packet(&data);
        let json = pkt.to_debug_json();
        assert!(json.contains("mesh_count"));
        assert!(json.contains("triangle_count"));
    }
}
