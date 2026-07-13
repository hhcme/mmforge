//! Deterministic large-model generator for performance baselines.
//!
//! Produces a multi-layer procedural scene tree with box, icosphere, and
//! cylinder meshes.  The generator is fully deterministic: identical seeds
//! produce identical models every time, with zero external randomness
//! dependencies.
//!
//! Usage (via CLI):
//!   mmforge generate-large-model --output /tmp/perf.lsm \
//!       --triangles 100000 --seed 42 --levels 4

use mmforge_core::ids::{GeometryId, MaterialId, NodeId};
use mmforge_core::model::{Geometry, LsmModel, Material, MeshGeometry, ModelBuilder};

// ---------------------------------------------------------------------------
// Deterministic PRNG — simple LCG + xorshift, no `rand` crate dependency
// ---------------------------------------------------------------------------

/// A seedable, deterministic pseudo-random number generator.
///
/// Uses a permuted congruential generator style: multiply with a large
/// constant, add another constant, then apply xorshift-multiply mixing
/// to improve statistical quality of the output.
pub struct DeterministicRng {
    state: u64,
}

impl DeterministicRng {
    /// Create a new RNG from a user-provided seed.
    ///
    /// The seed is mixed with the golden-ratio constant to avoid the zero
    /// fixed-point.
    pub fn new(seed: u64) -> Self {
        Self {
            state: seed.wrapping_add(0x9E3779B97F4A7C15),
        }
    }

    /// Return the next `u64` in the sequence.
    pub fn next(&mut self) -> u64 {
        // PCG-style LCG step.
        self.state = self
            .state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        // Xorshift-multiply mixer for improved avalanche.
        let mut x = self.state;
        x ^= x >> 33;
        x = x.wrapping_mul(0xFF51AFD7ED558CCD);
        x ^= x >> 33;
        x = x.wrapping_mul(0xC4CEB9FE1A85EC53);
        x ^= x >> 33;
        x
    }

    /// Return a float in [0.0, 1.0).
    #[allow(dead_code)]
    pub fn next_f32(&mut self) -> f32 {
        // Use only the top 24 bits for mantissa precision.
        (self.next() >> 40) as f32 / ((1u64 << 24) as f32)
    }

    /// Return a float in [min, max).
    #[allow(dead_code)]
    pub fn next_range(&mut self, min: f32, max: f32) -> f32 {
        min + self.next_f32() * (max - min)
    }

    /// Return an integer in [min, max] (inclusive).
    pub fn next_int_range(&mut self, min: u32, max: u32) -> u32 {
        let range = (max - min + 1) as u64;
        min + (self.next() % range) as u32
    }
}

// ---------------------------------------------------------------------------
// Procedural mesh generators
// ---------------------------------------------------------------------------

/// Generate vertex positions, normals, and indices for a unit box (1x1x1)
/// centred at the origin.
///
/// Produces 12 triangles (6 faces × 2 triangles each).
fn generate_box_mesh() -> (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<u32>) {
    let h = 0.5f32; // half-extent

    #[rustfmt::skip]
    let positions: Vec<[f32; 3]> = vec![
        // +X face (normal +X)
        [ h, -h, -h], [ h,  h, -h], [ h,  h,  h], [ h, -h,  h],
        // -X face (normal -X)
        [-h, -h,  h], [-h,  h,  h], [-h,  h, -h], [-h, -h, -h],
        // +Y face (normal +Y)
        [-h,  h, -h], [ h,  h, -h], [ h,  h,  h], [-h,  h,  h],
        // -Y face (normal -Y)
        [-h, -h,  h], [ h, -h,  h], [ h, -h, -h], [-h, -h, -h],
        // +Z face (normal +Z)
        [-h, -h,  h], [-h,  h,  h], [ h,  h,  h], [ h, -h,  h],
        // -Z face (normal -Z)
        [ h, -h, -h], [ h,  h, -h], [-h,  h, -h], [-h, -h, -h],
    ];

    #[rustfmt::skip]
    let normals: Vec<[f32; 3]> = vec![
        // +X
        [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0],
        // -X
        [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0], [-1.0, 0.0, 0.0],
        // +Y
        [0.0, 1.0, 0.0], [0.0, 1.0, 0.0], [0.0, 1.0, 0.0], [0.0, 1.0, 0.0],
        // -Y
        [0.0, -1.0, 0.0], [0.0, -1.0, 0.0], [0.0, -1.0, 0.0], [0.0, -1.0, 0.0],
        // +Z
        [0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0],
        // -Z
        [0.0, 0.0, -1.0], [0.0, 0.0, -1.0], [0.0, 0.0, -1.0], [0.0, 0.0, -1.0],
    ];

    #[rustfmt::skip]
    let indices: Vec<u32> = vec![
        0, 1, 2,  0, 2, 3,       // +X
        4, 5, 6,  4, 6, 7,       // -X
        8, 9, 10, 8, 10, 11,     // +Y
        12,13,14, 12,14,15,      // -Y
        16,17,18, 16,18,19,      // +Z
        20,21,22, 20,22,23,      // -Z
    ];

    (positions, normals, indices)
}

/// Generate an icosahedron approximation of a unit sphere (radius 1).
///
/// `subdivision` controls refinement: 0 = base icosahedron (20 triangles),
/// 1 = 80 triangles, 2 = 320 triangles.
fn generate_icosphere_mesh(subdivision: u32) -> (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<u32>) {
    let t = (1.0f32 + 5.0f32.sqrt()) * 0.5;
    #[rustfmt::skip]
    let base_verts: Vec<[f32; 3]> = vec![
        [-1.0,  t,  0.0], [ 1.0,  t,  0.0], [-1.0, -t,  0.0], [ 1.0, -t,  0.0],
        [ 0.0, -1.0,  t], [ 0.0,  1.0,  t], [ 0.0, -1.0, -t], [ 0.0,  1.0, -t],
        [ t,  0.0, -1.0], [ t,  0.0,  1.0], [-t,  0.0, -1.0], [-t,  0.0,  1.0],
    ];

    #[rustfmt::skip]
    let base_indices: Vec<u32> = vec![
        0, 11,  5,   0,  5,  1,   0,  1,  7,   0,  7, 10,   0, 10, 11,
        1,  5,  9,   5, 11,  4,  11, 10,  2,  10,  7,  6,   7,  1,  8,
        3,  9,  4,   3,  4,  2,   3,  2,  6,   3,  6,  8,   3,  8,  9,
        4,  9,  5,   2,  4, 11,   6,  2, 10,   8,  6,  7,   9,  8,  1,
    ];

    let normalize = |v: [f32; 3]| -> [f32; 3] {
        let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
        [v[0] / len, v[1] / len, v[2] / len]
    };

    let midpoint = |a: [f32; 3], b: [f32; 3]| -> [f32; 3] {
        normalize([
            (a[0] + b[0]) * 0.5,
            (a[1] + b[1]) * 0.5,
            (a[2] + b[2]) * 0.5,
        ])
    };

    let mut verts: Vec<[f32; 3]> = base_verts.into_iter().map(normalize).collect();
    let mut tris: Vec<[u32; 3]> = base_indices.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();

    for _ in 0..subdivision {
        let mut new_tris: Vec<[u32; 3]> = Vec::new();
        let mut mid_cache: Vec<((u32, u32), u32)> = Vec::new();

        let mut get_mid = |v1: u32, v2: u32| -> u32 {
            let key = if v1 < v2 { (v1, v2) } else { (v2, v1) };
            if let Some(&(_, idx)) = mid_cache.iter().find(|&&(k, _)| k == key) {
                return idx;
            }
            let mp = midpoint(verts[v1 as usize], verts[v2 as usize]);
            let idx = verts.len() as u32;
            verts.push(mp);
            mid_cache.push((key, idx));
            idx
        };

        for &[a, b, c] in &tris {
            let ab = get_mid(a, b);
            let bc = get_mid(b, c);
            let ca = get_mid(c, a);
            new_tris.push([a, ab, ca]);
            new_tris.push([b, bc, ab]);
            new_tris.push([c, ca, bc]);
            new_tris.push([ab, bc, ca]);
        }
        tris = new_tris;
    }

    let normals: Vec<[f32; 3]> = verts.clone(); // unit sphere: normal = position
    let indices: Vec<u32> = tris.into_iter().flat_map(|t| [t[0], t[1], t[2]]).collect();

    (verts, normals, indices)
}

/// Generate a unit cylinder (radius 0.5, height 1) centred at origin, with
/// the long axis along Y.
fn generate_cylinder_mesh(sides: u32) -> (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<u32>) {
    let r = 0.5f32;
    let half_h = 0.5f32;
    let sides = sides.max(8);

    let mut positions: Vec<[f32; 3]> = Vec::new();
    let mut normals: Vec<[f32; 3]> = Vec::new();
    let mut indices: Vec<u32> = Vec::new();

    // Top centre (index 0), Bottom centre (index 1)
    positions.push([0.0, half_h, 0.0]);
    normals.push([0.0, 1.0, 0.0]);
    positions.push([0.0, -half_h, 0.0]);
    normals.push([0.0, -1.0, 0.0]);

    // Top ring (indices 2..2+sides)
    let top_start = 2u32;
    for i in 0..sides {
        let angle = (i as f32) / (sides as f32) * 2.0 * std::f32::consts::PI;
        let x = angle.cos() * r;
        let z = angle.sin() * r;
        positions.push([x, half_h, z]);
        normals.push([0.0, 1.0, 0.0]);
    }

    // Bottom ring (indices 2+sides..2+2*sides)
    let bot_start = top_start + sides;
    for i in 0..sides {
        let angle = (i as f32) / (sides as f32) * 2.0 * std::f32::consts::PI;
        let x = angle.cos() * r;
        let z = angle.sin() * r;
        positions.push([x, -half_h, z]);
        normals.push([0.0, -1.0, 0.0]);
    }

    // Body vertices: side normals (indices 2+2*sides..2+4*sides)
    let body_v_start = bot_start + sides;
    for i in 0..sides {
        let angle = (i as f32) / (sides as f32) * 2.0 * std::f32::consts::PI;
        let x = angle.cos() * r;
        let z = angle.sin() * r;
        let nx = angle.cos();
        let nz = angle.sin();
        // Top body vertex
        positions.push([x, half_h, z]);
        normals.push([nx, 0.0, nz]);
        // Bottom body vertex
        positions.push([x, -half_h, z]);
        normals.push([nx, 0.0, nz]);
    }

    // Top cap triangles.
    for i in 0..sides {
        let next = (i + 1) % sides;
        indices.push(0); // top centre
        indices.push(top_start + next);
        indices.push(top_start + i);
    }

    // Bottom cap triangles.
    for i in 0..sides {
        let next = (i + 1) % sides;
        indices.push(1); // bottom centre
        indices.push(bot_start + i);
        indices.push(bot_start + next);
    }

    // Body triangles (quad per side → 2 triangles).
    for i in 0..sides {
        let next = (i + 1) % sides;
        let vt0 = body_v_start + i * 2; // top
        let vb0 = body_v_start + i * 2 + 1; // bottom
        let vt1 = body_v_start + next * 2; // next top
        let vb1 = body_v_start + next * 2 + 1; // next bottom

        // Tri 1: top, bottom, next-bottom
        indices.push(vt0);
        indices.push(vb0);
        indices.push(vb1);
        // Tri 2: top, next-bottom, next-top
        indices.push(vt0);
        indices.push(vb1);
        indices.push(vt1);
    }

    (positions, normals, indices)
}

// ---------------------------------------------------------------------------
// Colour generation
// ---------------------------------------------------------------------------

/// Derive a deterministic RGBA colour from a node path (slice of child
/// indices at each level).  Different paths produce visually distinct
/// colours.
fn colour_from_path(path: &[u32]) -> [f32; 4] {
    let mut h: u32 = 0x811C9DC5; // FNV-1a 32-bit offset basis
    for &idx in path {
        h ^= idx;
        h = h.wrapping_mul(0x01000193);
    }
    let r = ((h >> 16) & 0xFF) as f32 / 255.0;
    let g = ((h >> 8) & 0xFF) as f32 / 255.0;
    let b = (h & 0xFF) as f32 / 255.0;
    // Ensure some brightness.
    let brightness = r * 0.299 + g * 0.587 + b * 0.114;
    let scale = if brightness < 0.15 {
        let boost = 0.15 / brightness.max(0.001);
        boost.min(4.0)
    } else {
        1.0
    };
    [
        (r * scale).min(1.0),
        (g * scale).min(1.0),
        (b * scale).min(1.0),
        1.0,
    ]
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parameters controlling the generated model.
pub struct GenParams {
    /// Output file path.
    pub output: std::path::PathBuf,
    /// Target minimum triangle count (generator overshoots slightly).
    pub triangles: usize,
    /// Random seed for determinism.
    pub seed: u64,
    /// Number of hierarchical levels including root (at least 3).
    pub levels: u32,
}

/// Internal node tracking during tree construction.
struct BuildNode {
    node_id: NodeId,
    depth: u32,
    path: Vec<u32>,
}

/// Generate the model and write it to the output path.
///
/// Returns the generated `LsmModel` and the output file size in bytes.
pub fn generate_large_model(params: &GenParams) -> Result<(LsmModel, u64), String> {
    let mut rng = DeterministicRng::new(params.seed);

    // ---- Phase 1: Build the scene tree (no geometry / materials yet) ----
    let mut builder = ModelBuilder::new("generator").with_units("mm");
    let root = builder.add_root("root");

    let mut build_nodes: Vec<BuildNode> = Vec::new();
    build_nodes.push(BuildNode {
        node_id: root,
        depth: 0,
        path: vec![0],
    });

    let mut idx = 0usize;

    while idx < build_nodes.len() {
        let current_id = build_nodes[idx].node_id;
        let current_depth = build_nodes[idx].depth;
        let path = build_nodes[idx].path.clone();

        if current_depth < params.levels {
            // Internal node — create 3-8 group children.
            let n_children = rng.next_int_range(3, 8);
            for c in 0..n_children {
                let mut child_path = path.clone();
                child_path.push(c);
                let child_name = format!("l{}_g{}", current_depth + 1, child_path.last().unwrap());
                let child_id = builder.add_child(current_id, child_name, None, None);
                build_nodes.push(BuildNode {
                    node_id: child_id,
                    depth: current_depth + 1,
                    path: child_path,
                });
            }
        }
        // Leaf nodes (depth >= levels) have no children — will get geometry
        // in phase 2.
        idx += 1;
    }

    // ---- Phase 2: Build and populate geometry / materials ----
    let mut model = builder.build();

    // Set metadata.
    model.metadata.description = Some(format!(
        "Deterministic procedural model (seed={}, levels={})",
        params.seed, params.levels
    ));
    model.metadata.author = Some("mmforge generate-large-model".into());
    model.header.source_path = Some("generated".into());

    let mut next_geom_id: u32 = 0;
    let mut next_mat_id: u32 = 0;

    // Use separate RNG for geometry assignment (derived from seed to keep
    // determinism).
    let mut geom_rng = DeterministicRng::new(params.seed.wrapping_add(1));

    for bn in &build_nodes {
        // Leaf nodes are at depth == params.levels.
        if bn.depth == params.levels {
            // Weighted primitive selection for higher triangle density.
            // 10 values: 0=box(10%), 1-3=cyl(30%), 4-9=icosphere(60%).
            let raw = geom_rng.next_int_range(0, 9);
            let (positions, normals, indices): (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<u32>) = match raw
            {
                0 => generate_box_mesh(),            // ~12 tris
                1..=3 => generate_cylinder_mesh(64), // ~384 tris
                _ => generate_icosphere_mesh(2),     // ~320 tris
            };

            let gid = GeometryId::new(next_geom_id);
            next_geom_id += 1;

            // Compute bounds.
            let mut bounds = mmforge_core::math::BoundingBox::EMPTY;
            for p in &positions {
                bounds.extend_point(glam::Vec3::new(p[0], p[1], p[2]));
            }

            model.geometries.push(Geometry::Mesh(MeshGeometry {
                id: gid,
                positions,
                normals,
                uvs: Vec::new(),
                indices,
                bounds,
            }));

            let colour = colour_from_path(&bn.path);
            let mid = MaterialId::new(next_mat_id);
            next_mat_id += 1;

            model.materials.push(Material {
                id: mid,
                name: format!(
                    "mat_{}",
                    bn.path
                        .iter()
                        .map(|p| p.to_string())
                        .collect::<Vec<_>>()
                        .join("_")
                ),
                base_color: colour,
                metallic: 0.0,
                roughness: 0.5,
            });

            // Update the node with geometry and material references.
            let node = model
                .scene
                .find_node_mut(bn.node_id)
                .ok_or_else(|| format!("leaf node {} not found", bn.node_id.get()))?;
            node.geometry = Some(gid);
            node.material = Some(mid);
            node.bounds = bounds;
        }
    }

    // ---- Verify triangle count ----
    let actual_tris = model.total_triangle_count();
    if actual_tris < params.triangles {
        return Err(format!(
            "insufficient triangles: generated {actual_tris}, target {} (increase --levels or primitives)",
            params.triangles
        ));
    }

    // ---- Serialize to .lsm ----
    let mut file = std::fs::File::create(&params.output)
        .map_err(|e| format!("create {}: {e}", params.output.display()))?;
    let size =
        mmforge_core::lsm::write_lsm(&model, &mut file).map_err(|e| format!("write LSM: {e}"))?;

    eprintln!(
        "generated model: {} nodes, {} geometries, {} triangles, {} bytes",
        model.scene.nodes.len(),
        model.geometries.len(),
        actual_tris,
        size,
    );

    Ok((model, size))
}
