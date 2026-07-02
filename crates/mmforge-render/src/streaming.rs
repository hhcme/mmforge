//! RenderPacket streaming — chunk-based incremental upload.
//!
//! Splits a monolithic [`RenderPacket`] into smaller [`RenderChunk`]s that
//! each fit within a [`MemoryBudget`].  Each chunk is independently renderable
//! so the GPU can begin displaying geometry while later chunks are still loading.

use std::collections::HashMap;

use super::memory::MemoryBudget;
use super::packet::{RenderBatch, RenderInstance, RenderMaterial, RenderMesh, RenderStats};
use mmforge_core::math::BoundingBox;

/// A self-contained subset of a RenderPacket that fits within a memory budget.
///
/// Each chunk is fully self-contained:
/// - `meshes[i].mesh_id == i` — all mesh ids are chunk-local.
/// - `instances[*].mesh_id` references `meshes` by its chunk-local index.
/// - `batches[*].instance_range` index into `instances` and never exceed `instances.len()`.
/// - `stats.batch_count == batches.len()`.
#[derive(Debug, Clone)]
pub struct RenderChunk {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    /// Indices of the instances in the **original** RenderPacket.
    pub instance_indices: Vec<usize>,
    /// Draw-call batches built from chunk instances, grouped by material.
    pub batches: Vec<RenderBatch>,
    /// The world-space bounds covering all meshes in this chunk.
    pub chunk_bounds: BoundingBox,
    pub stats: RenderStats,
}

/// Splits a render packet into chunks that each fit within a memory budget.
///
/// Chunks are greedy: meshes are selected in order.  For each selected mesh,
/// **all** instances that reference it (by `mesh_id`) are pulled into the chunk,
/// so the chunk contains every instance that depends on its meshes.  When adding
/// the next mesh + its instances would exceed the budget, a new chunk starts.
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

        let mut mesh_to_instances: HashMap<usize, Vec<usize>> = HashMap::new();
        for (inst_idx, inst) in packet.instances.iter().enumerate() {
            mesh_to_instances
                .entry(inst.mesh_id as usize)
                .or_default()
                .push(inst_idx);
        }

        let mut current_meshes: Vec<(usize, RenderMesh)> = Vec::new();
        let mut current_cost: usize = 0;
        let mut current_bounds = BoundingBox::EMPTY;

        for (orig_mesh_idx, mesh) in packet.meshes.iter().enumerate() {
            let mesh_cost =
                super::memory::gpu_mesh_memory_bytes(mesh.positions.len(), mesh.indices.len());

            if !current_meshes.is_empty() && current_cost + mesh_cost > capacity {
                chunks.push(finish_chunk(
                    &packet.materials,
                    &packet.instances,
                    &mesh_to_instances,
                    &mut current_meshes,
                    &mut current_bounds,
                    &mut current_cost,
                ));
            }

            current_meshes.push((orig_mesh_idx, mesh.clone()));
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
                &packet.materials,
                &packet.instances,
                &mesh_to_instances,
                &mut current_meshes,
                &mut current_bounds,
                &mut current_cost,
            ));
        }

        Self { chunks }
    }

    pub fn chunk_count(&self) -> usize {
        self.chunks.len()
    }

    pub fn chunk(&self, index: usize) -> Option<&RenderChunk> {
        self.chunks.get(index)
    }

    pub fn iter_chunks(&self) -> impl Iterator<Item = &RenderChunk> {
        self.chunks.iter()
    }

    pub fn into_chunks(self) -> Vec<RenderChunk> {
        self.chunks
    }
}

fn finish_chunk(
    materials: &[RenderMaterial],
    packet_instances: &[RenderInstance],
    mesh_to_instances: &HashMap<usize, Vec<usize>>,
    meshes: &mut Vec<(usize, RenderMesh)>,
    bounds: &mut BoundingBox,
    cost: &mut usize,
) -> RenderChunk {
    // Build original_mesh_index -> chunk-local mesh index mapping.
    let mut mesh_remap: HashMap<usize, u32> = HashMap::new();
    for (local_idx, (orig_idx, _)) in meshes.iter().enumerate() {
        mesh_remap.insert(*orig_idx, local_idx as u32);
    }

    // Collect all instances that reference the meshes in this chunk.
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut chunk_instances: Vec<RenderInstance> = Vec::new();
    let mut chunk_instance_indices: Vec<usize> = Vec::new();

    for (orig_idx, _) in meshes.iter() {
        if let Some(inst_indices) = mesh_to_instances.get(orig_idx) {
            for &inst_idx in inst_indices {
                if seen.insert(inst_idx) {
                    let mut inst = packet_instances[inst_idx].clone();
                    inst.mesh_id = mesh_remap[&(inst.mesh_id as usize)];
                    chunk_instances.push(inst);
                    chunk_instance_indices.push(inst_idx);
                }
            }
        }
    }

    // Build batches: group consecutive instances by material.
    let mut batches: Vec<RenderBatch> = Vec::new();
    if !chunk_instances.is_empty() {
        let mut start = 0usize;
        let mut prev_material = chunk_instances[0].material_id;
        for (i, inst) in chunk_instances.iter().enumerate().skip(1) {
            if inst.material_id != prev_material {
                batches.push(RenderBatch {
                    material_id: prev_material,
                    instance_range: start..i,
                    transparent: false,
                });
                start = i;
                prev_material = inst.material_id;
            }
        }
        batches.push(RenderBatch {
            material_id: prev_material,
            instance_range: start..chunk_instances.len(),
            transparent: false,
        });
    }

    let triangle_count: usize = meshes.iter().map(|(_, m)| m.indices.len() / 3).sum();
    let total_vertices: usize = meshes.iter().map(|(_, m)| m.positions.len()).sum();
    let total_indices: usize = meshes.iter().map(|(_, m)| m.indices.len()).sum();
    let memory_bytes = *cost;
    let instance_count = chunk_instance_indices.len();

    // Build final mesh vector with chunk-local mesh_ids.
    let mut chunk_meshes: Vec<RenderMesh> =
        std::mem::take(meshes).into_iter().map(|(_, m)| m).collect();
    for (i, mesh) in chunk_meshes.iter_mut().enumerate() {
        mesh.mesh_id = i as u32;
    }
    let mesh_count = chunk_meshes.len();

    let batch_count = batches.len();

    let chunk = RenderChunk {
        meshes: chunk_meshes,
        materials: materials.to_vec(),
        instances: chunk_instances,
        instance_indices: chunk_instance_indices,
        batches,
        chunk_bounds: *bounds,
        stats: RenderStats {
            mesh_count,
            instance_count,
            triangle_count,
            batch_count,
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

    fn sample_material(id: u32, name: &str) -> RenderMaterial {
        RenderMaterial {
            material_id: id,
            name: name.into(),
            base_color: [0.5, 0.5, 0.5, 1.0],
            metallic: 0.0,
            roughness: 0.5,
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
            materials: vec![sample_material(0, "default")],
            instances,
            batches: vec![batch],
            scene_bounds: BoundingBox {
                min: glam::Vec3::ZERO,
                max: glam::Vec3::ONE,
            },
            stats,
        }
    }

    fn sample_packet_instanced(
        meshes: Vec<RenderMesh>,
        instance_specs: Vec<(usize, u32)>,
    ) -> super::super::packet::RenderPacket {
        let instances: Vec<RenderInstance> = instance_specs
            .iter()
            .map(|(mesh_idx, mat_id)| RenderInstance {
                mesh_id: *mesh_idx as u32,
                material_id: *mat_id,
                transform: glam::Mat4::IDENTITY,
                visible: true,
            })
            .collect();
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
            materials: vec![sample_material(0, "default")],
            instances,
            batches: vec![super::super::packet::RenderBatch {
                material_id: 0,
                instance_range: 0..stats.instance_count,
                transparent: false,
            }],
            scene_bounds: BoundingBox {
                min: glam::Vec3::ZERO,
                max: glam::Vec3::ONE,
            },
            stats,
        }
    }

    // ------------------------------------------------------------------
    // Basic tests
    // ------------------------------------------------------------------

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
        let budget = MemoryBudget::new(1024);
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

    // ------------------------------------------------------------------
    // Instance ↔ mesh mapping tests
    // ------------------------------------------------------------------

    #[test]
    fn multiple_instances_per_mesh_are_all_collected() {
        let m0 = sample_mesh(0, 100, 300);
        let m1 = sample_mesh(1, 100, 300);
        let packet = sample_packet_instanced(vec![m0, m1], vec![(0, 0), (0, 0), (1, 0)]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert_eq!(sp.chunk_count(), 1);
        let chunk = sp.chunk(0).unwrap();
        assert_eq!(chunk.meshes.len(), 2);
        assert_eq!(chunk.instances.len(), 3, "all 3 instances must be present");
        assert_eq!(chunk.stats.instance_count, 3);
    }

    #[test]
    fn instance_mesh_ids_remapped_to_local() {
        let m0 = sample_mesh(0, 100, 300);
        let m1 = sample_mesh(1, 100, 300);
        let packet = sample_packet_instanced(vec![m0, m1], vec![(1, 0), (0, 0)]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let chunk = sp.chunk(0).unwrap();
        assert_eq!(chunk.meshes.len(), 2);
        for inst in &chunk.instances {
            assert!(
                inst.mesh_id < chunk.meshes.len() as u32,
                "instance mesh_id must be a valid chunk-local index"
            );
        }
    }

    #[test]
    fn stats_instance_count_matches_after_chunking() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let total_instance_count: usize = sp.iter_chunks().map(|c| c.stats.instance_count).sum();
        assert_eq!(total_instance_count, packet.instances.len());
    }

    #[test]
    fn stats_triangle_count_preserved() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let total_tris: usize = sp.iter_chunks().map(|c| c.stats.triangle_count).sum();
        assert_eq!(total_tris, packet.stats.triangle_count);
    }

    // ------------------------------------------------------------------
    // Chunk-local mesh_id invariant: meshes[i].mesh_id == i
    // ------------------------------------------------------------------

    #[test]
    fn chunk_mesh_ids_are_local_indices() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        for chunk in sp.iter_chunks() {
            for (i, mesh) in chunk.meshes.iter().enumerate() {
                assert_eq!(mesh.mesh_id, i as u32, "meshes[{i}].mesh_id must equal {i}");
            }
        }
    }

    #[test]
    fn instance_mesh_id_indexes_into_chunk_meshes() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        for chunk in sp.iter_chunks() {
            for inst in &chunk.instances {
                assert!(
                    (inst.mesh_id as usize) < chunk.meshes.len(),
                    "instance mesh_id {} out of range (meshes.len={})",
                    inst.mesh_id,
                    chunk.meshes.len(),
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // Batch self-containment tests
    // ------------------------------------------------------------------

    #[test]
    fn chunks_have_batches_field() {
        let mesh = sample_mesh(0, 100, 300);
        let packet = sample_packet(vec![mesh]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let chunk = sp.chunk(0).unwrap();
        assert!(!chunk.batches.is_empty(), "chunk should have batches");
    }

    #[test]
    fn batch_count_matches_stats_and_batches_len() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        for chunk in sp.iter_chunks() {
            assert_eq!(
                chunk.stats.batch_count,
                chunk.batches.len(),
                "stats.batch_count must equal batches.len()"
            );
        }
    }

    #[test]
    fn batch_instance_ranges_cover_all_instances() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        for chunk in sp.iter_chunks() {
            let n = chunk.instances.len();
            let mut covered = vec![false; n.max(1)];
            for batch in &chunk.batches {
                assert!(
                    batch.instance_range.end <= n,
                    "batch range {:?} exceeds instance count {n}",
                    batch.instance_range,
                );
                for idx in batch.instance_range.clone() {
                    covered[idx] = true;
                }
            }
            if n > 0 {
                let uncovered: Vec<usize> = covered
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| !**c)
                    .map(|(i, _)| i)
                    .collect();
                assert!(
                    uncovered.is_empty(),
                    "instances not covered by any batch: {uncovered:?}"
                );
            }
        }
    }

    #[test]
    fn batch_instance_ranges_are_contiguous_and_non_overlapping() {
        let meshes: Vec<RenderMesh> = (0..5).map(|i| sample_mesh(i, 100, 300)).collect();
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        for chunk in sp.iter_chunks() {
            let mut last_end = 0;
            for batch in &chunk.batches {
                assert_eq!(
                    batch.instance_range.start, last_end,
                    "batch ranges must be contiguous; expected start {last_end}, got {:?}",
                    batch.instance_range,
                );
                assert!(
                    batch.instance_range.start < batch.instance_range.end,
                    "batch range must be non-empty: {:?}",
                    batch.instance_range,
                );
                last_end = batch.instance_range.end;
            }
            assert_eq!(
                last_end,
                chunk.instances.len(),
                "last batch end must equal instance count"
            );
        }
    }

    // ------------------------------------------------------------------
    // Multi-material chunk test
    // ------------------------------------------------------------------

    #[test]
    fn multi_material_chunk_splits_batches() {
        let m0 = sample_mesh(0, 100, 300);
        let m1 = sample_mesh(1, 100, 300);
        let packet = sample_packet_instanced(vec![m0, m1], vec![(0, 0), (1, 1), (0, 0), (1, 2)]);
        let budget = MemoryBudget::new(64 * 1024 * 1024);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        let chunk = sp.chunk(0).unwrap();
        assert_eq!(chunk.instances.len(), 4);
        assert!(
            chunk.batches.len() >= 3,
            "expected at least 3 batches (material changes), got {}",
            chunk.batches.len()
        );
        assert_eq!(chunk.stats.batch_count, chunk.batches.len());
        // Verify batch ranges don't exceed instance count.
        for batch in &chunk.batches {
            assert!(batch.instance_range.end <= 4);
        }
    }

    // ------------------------------------------------------------------
    // Multi-chunk test with split meshes
    // ------------------------------------------------------------------

    #[test]
    fn multi_chunk_each_chunk_has_its_own_batches() {
        let meshes: Vec<RenderMesh> = (0..6).map(|i| sample_mesh(i, 1000, 3000)).collect();
        let mesh_cost = gpu_mesh_memory_bytes(1000, 3000);
        let packet = sample_packet(meshes);
        let budget = MemoryBudget::new(mesh_cost * 2 + 1);
        let sp = StreamingPacket::from_packet(&packet, &budget);
        assert!(sp.chunk_count() > 1);

        let mut total_instances = 0;
        for (ci, chunk) in sp.iter_chunks().enumerate() {
            assert!(!chunk.batches.is_empty(), "chunk {ci} should have batches");
            assert_eq!(chunk.batches.len(), chunk.stats.batch_count);

            let n = chunk.instances.len();
            total_instances += n;
            for batch in &chunk.batches {
                assert!(batch.instance_range.end <= n);
            }
        }
        assert_eq!(total_instances, packet.instances.len());
    }
}
