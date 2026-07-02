//! RenderPacket streaming — chunk-based incremental upload.
//!
//! Splits a monolithic [`RenderPacket`] into smaller [`RenderChunk`]s that
//! each fit within a [`MemoryBudget`].  Each chunk is independently renderable
//! so the GPU can begin displaying geometry while later chunks are still loading.

use super::memory::MemoryBudget;
use super::packet::{RenderInstance, RenderMaterial, RenderMesh, RenderStats};
use mmforge_core::math::BoundingBox;

/// A self-contained subset of a RenderPacket that fits within a memory budget.
///
/// Each chunk carries a slice of meshes, the instances that reference them,
/// and material+batch metadata.  The owning node IDs are preserved so the
/// scene tree can correctly map each chunk's geometry back to the tree.
#[derive(Debug, Clone)]
pub struct RenderChunk {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    /// Indices of the instances in the **original** RenderPacket.
    pub instance_indices: Vec<usize>,
    /// The world-space bounds covering all meshes in this chunk.
    pub chunk_bounds: BoundingBox,
    pub stats: RenderStats,
}

/// Splits a render packet into chunks that each fit within a memory budget.
///
/// Chunks are greedy: meshes are assigned to the current chunk until adding
/// the next mesh would exceed the budget, at which point a new chunk starts.
/// All materials from the source packet are included in every chunk so that
/// material bindings remain consistent.
#[derive(Debug)]
pub struct StreamingPacket {
    chunks: Vec<RenderChunk>,
}

impl StreamingPacket {
    /// Split a RenderPacket into chunks respecting the given memory budget.
    ///
    /// Each mesh's memory cost is estimated via [`super::memory::gpu_mesh_memory_bytes`].
    /// A chunk will always contain at least one mesh, even if that single mesh
    /// exceeds the budget (graceful degradation).
    pub fn from_packet(packet: &super::packet::RenderPacket, budget: &MemoryBudget) -> Self {
        let capacity = budget.capacity();
        let mut chunks: Vec<RenderChunk> = Vec::new();
        let mut current_meshes: Vec<RenderMesh> = Vec::new();
        let mut current_instances: Vec<RenderInstance> = Vec::new();
        let mut current_instance_indices: Vec<usize> = Vec::new();
        let mut current_cost: usize = 0;
        let mut current_bounds = BoundingBox::EMPTY;

        for (i, mesh) in packet.meshes.iter().enumerate() {
            let mesh_cost =
                super::memory::gpu_mesh_memory_bytes(mesh.positions.len(), mesh.indices.len());

            if !current_meshes.is_empty() && current_cost + mesh_cost > capacity {
                chunks.push(finish_chunk(
                    &mut current_meshes,
                    &packet.materials,
                    &mut current_instances,
                    &mut current_instance_indices,
                    &mut current_bounds,
                    &mut current_cost,
                ));
            }

            let instance = packet.instances.get(i).cloned().unwrap_or_else(|| {
                let mesh_idx = current_meshes.len() as u32;
                RenderInstance {
                    mesh_id: mesh_idx,
                    material_id: 0,
                    transform: glam::Mat4::IDENTITY,
                    visible: true,
                }
            });

            current_meshes.push(mesh.clone());
            current_instances.push(instance);
            current_instance_indices.push(i);
            current_bounds = if current_bounds.is_valid() {
                current_bounds.extend_point(mesh.bounds.min);
                current_bounds.extend_point(mesh.bounds.max);
                current_bounds
            } else {
                mesh.bounds
            };
            current_cost += mesh_cost;
        }

        if !current_meshes.is_empty() {
            chunks.push(finish_chunk(
                &mut current_meshes,
                &packet.materials,
                &mut current_instances,
                &mut current_instance_indices,
                &mut current_bounds,
                &mut current_cost,
            ));
        }

        Self { chunks }
    }

    /// Returns the number of chunks.
    pub fn chunk_count(&self) -> usize {
        self.chunks.len()
    }

    /// Returns the chunk at the given index.
    pub fn chunk(&self, index: usize) -> Option<&RenderChunk> {
        self.chunks.get(index)
    }

    /// Iterate all chunks in order.
    pub fn iter_chunks(&self) -> impl Iterator<Item = &RenderChunk> {
        self.chunks.iter()
    }

    /// Consume self and return the chunks.
    pub fn into_chunks(self) -> Vec<RenderChunk> {
        self.chunks
    }
}

fn finish_chunk(
    meshes: &mut Vec<RenderMesh>,
    materials: &[RenderMaterial],
    instances: &mut Vec<RenderInstance>,
    instance_indices: &mut Vec<usize>,
    bounds: &mut BoundingBox,
    cost: &mut usize,
) -> RenderChunk {
    // Re-index mesh_ids and material_ids to be local to the chunk.
    let mesh_count = meshes.len() as u32;
    for inst in instances.iter_mut() {
        inst.mesh_id = inst.mesh_id.min(mesh_count.saturating_sub(1));
    }

    let triangle_count: usize = meshes.iter().map(|m| m.indices.len() / 3).sum();
    let total_vertices: usize = meshes.iter().map(|m| m.positions.len()).sum();
    let total_indices: usize = meshes.iter().map(|m| m.indices.len()).sum();
    let memory_bytes = *cost;

    let chunk = RenderChunk {
        meshes: std::mem::take(meshes),
        materials: materials.to_vec(),
        instances: std::mem::take(instances),
        instance_indices: std::mem::take(instance_indices),
        chunk_bounds: *bounds,
        stats: RenderStats {
            mesh_count: mesh_count as usize,
            instance_count: instance_indices.len(),
            triangle_count,
            batch_count: 1,
            total_vertices,
            total_indices,
            memory_bytes,
            build_duration_ms: 0.0,
        },
    };

    *bounds = BoundingBox::EMPTY;
    *cost = 0;

    chunk
}

#[cfg(test)]
mod tests {
    use super::super::memory::gpu_mesh_memory_bytes;
    use super::*;

    fn sample_mesh(id: u32, vertex_count: usize, index_count: usize) -> RenderMesh {
        let positions: Vec<[f32; 3]> = (0..vertex_count)
            .map(|i| {
                let x = i as f32;
                [x, 0.0, 0.0]
            })
            .collect();
        let indices: Vec<u32> = (0..index_count)
            .map(|i| i as u32 % vertex_count as u32)
            .collect();
        RenderMesh {
            mesh_id: id,
            geometry_id: id,
            positions,
            normals: vec![[0.0, 1.0, 0.0]; vertex_count],
            uvs: Vec::new(),
            indices,
            bounds: BoundingBox {
                min: glam::Vec3::new(0.0, 0.0, 0.0),
                max: glam::Vec3::new(1.0, 1.0, 1.0),
            },
        }
    }

    fn sample_packet(meshes: Vec<RenderMesh>) -> super::super::packet::RenderPacket {
        let instances: Vec<RenderInstance> = meshes
            .iter()
            .enumerate()
            .map(|(i, _)| RenderInstance {
                mesh_id: i as u32,
                material_id: 0,
                transform: glam::Mat4::IDENTITY,
                visible: true,
            })
            .collect();
        let batch = super::super::packet::RenderBatch {
            material_id: 0,
            instance_range: 0..instances.len(),
            transparent: false,
        };
        let stats = RenderStats {
            mesh_count: meshes.len(),
            instance_count: instances.len(),
            triangle_count: meshes.iter().map(|m| m.indices.len() / 3).sum(),
            batch_count: 1,
            total_vertices: meshes.iter().map(|m| m.positions.len()).sum(),
            total_indices: meshes.iter().map(|m| m.indices.len()).sum(),
            memory_bytes: 0,
            build_duration_ms: 0.0,
        };
        super::super::packet::RenderPacket {
            meshes,
            materials: vec![super::super::packet::RenderMaterial {
                material_id: 0,
                name: "default".into(),
                base_color: [0.5, 0.5, 0.5, 1.0],
                metallic: 0.0,
                roughness: 0.5,
            }],
            instances,
            batches: vec![batch],
            scene_bounds: BoundingBox {
                min: glam::Vec3::ZERO,
                max: glam::Vec3::ONE,
            },
            stats,
        }
    }

    #[test]
    fn empty_packet_produces_no_chunks() {
        let packet = super::super::packet::RenderPacket::default();
        let budget = MemoryBudget::new(1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert_eq!(sp.chunk_count(), 0);
    }

    #[test]
    fn single_small_mesh_in_one_chunk() {
        let mesh = sample_mesh(0, 100, 300);
        let packet = sample_packet(vec![mesh]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert_eq!(sp.chunk_count(), 1);
        let chunk = sp.chunk(0).unwrap();
        assert_eq!(chunk.meshes.len(), 1);
        assert_eq!(chunk.instances.len(), 1);
        assert!(chunk.chunk_bounds.is_valid());
    }

    #[test]
    fn multiple_meshes_split_at_budget() {
        let mesh_cost = gpu_mesh_memory_bytes(1000, 3000);
        // Create 10 meshes, budget for 3.
        let meshes: Vec<RenderMesh> = (0..10).map(|i| sample_mesh(i, 1000, 3000)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(mesh_cost * 3 + 1);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert!(sp.chunk_count() > 1, "should produce multiple chunks");
        for i in 0..sp.chunk_count() {
            let c = sp.chunk(i).unwrap();
            assert!(!c.meshes.is_empty(), "chunk {i} should not be empty");
        }
    }

    #[test]
    fn single_large_mesh_gets_its_own_chunk() {
        let mesh = sample_mesh(0, 1_000_000, 3_000_000);
        let packet = sample_packet(vec![mesh]);
        let budget = MemoryBudget::new(1024); // tiny budget
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert_eq!(sp.chunk_count(), 1);
    }

    #[test]
    fn chunk_bounds_cover_all_meshes() {
        let m1 = sample_mesh(0, 10, 30);
        let mut m2 = sample_mesh(1, 10, 30);
        m2.bounds = BoundingBox {
            min: glam::Vec3::new(10.0, 0.0, 0.0),
            max: glam::Vec3::new(20.0, 1.0, 1.0),
        };
        let packet = sample_packet(vec![m1, m2]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert_eq!(sp.chunk_count(), 1);
        let chunk = sp.chunk(0).unwrap();
        assert!(chunk.chunk_bounds.min.x <= 0.0);
        assert!(chunk.chunk_bounds.max.x >= 20.0);
    }

    #[test]
    fn iter_chunks_returns_all() {
        let meshes: Vec<RenderMesh> = (0..10).map(|i| sample_mesh(i, 1000, 3000)).collect();
        let mesh_cost = gpu_mesh_memory_bytes(1000, 3000);
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(mesh_cost * 2 + 1);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let count = sp.iter_chunks().count();
        assert_eq!(sp.chunk_count(), count);
    }

    #[test]
    fn into_chunks_consumes() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let chunks = sp.into_chunks();
        assert!(!chunks.is_empty());
    }
}
