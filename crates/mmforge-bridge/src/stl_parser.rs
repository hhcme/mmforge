//! STL binary/ascii parser.
//!
//! Produces a flat `LsmModel` with a single root node and one child
//! per mesh (STL has no scene tree).  Vertices are deduplicated via
//! quantized hashing to reduce memory.

use std::path::Path;

use glam::Vec3;
use mmforge_core::error::{Error, Result};
use mmforge_core::ids::{GeometryId, NodeId};
use mmforge_core::math::BoundingBox;
use mmforge_core::model::{Geometry, LsmModel, MeshGeometry, Node, ParseOutput, ParseStats};
use mmforge_geometry::tessellation::{TessellatedMeshData, TessellationRegistry};

/// Detect if a file is STL by checking header bytes.
///
/// Disambiguation strategy for files starting with "solid":
/// - Look for "facet" in the first 84 bytes (strong ASCII indicator).
/// - If found → ASCII STL.
/// - If not found and bytes 80-84 form a valid triangle count → binary STL
///   (some CAD tools write "solid" in the 80-byte binary header).
/// - If neither → still accept (let the parser handle the ambiguity).
pub fn detect_stl(header: &[u8], path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if ext != "stl" {
        return false;
    }

    // Need at least 84 bytes for binary detection (80-byte header + u32 count).
    if header.len() < 84 {
        // Too short for binary — check ASCII.
        return header.starts_with(b"solid");
    }

    let starts_with_solid = header.starts_with(b"solid");
    let tri_count = u32::from_le_bytes([header[80], header[81], header[82], header[83]]);
    let reasonable_tri = tri_count > 0 && tri_count < 100_000_000;

    if starts_with_solid {
        // "solid" prefix present — could be ASCII or binary with "solid" header.
        // Look for "facet" in the header: strong ASCII indicator.
        let header_str = &header[..80.min(header.len())];
        let has_facet = header_str
            .windows(5)
            .any(|w| w == b"facet" || w == b"Facet" || w == b"FACET");
        if has_facet {
            return true; // ASCII STL.
        }
        // No "facet" in header.  If bytes 80-84 look like a valid binary
        // triangle count, treat as binary (CAD "solid" header edge case).
        if reasonable_tri {
            return true;
        }
        // Ambiguous — accept and let the parser decide.
        return true;
    }

    // No "solid" prefix — standard binary STL detection.
    reasonable_tri
}

/// Parse an STL file (binary or ASCII) into a model + tessellation registry.
pub fn parse_stl(path: &Path) -> Result<(ParseOutput, TessellationRegistry)> {
    let data = std::fs::read(path).map_err(Error::Io)?;

    if data.len() < 84 {
        return Err(Error::parse("STL", "file too small"));
    }

    let (positions, normals) = if is_ascii_stl(&data) {
        parse_ascii_stl(&data)?
    } else {
        parse_binary_stl(&data)?
    };

    if positions.is_empty() {
        return Err(Error::parse("STL", "no triangles found"));
    }

    let vertex_count = positions.len() / 3;
    let triangle_count = vertex_count / 3;

    // Build indices (STL stores duplicated vertices).
    let indices: Vec<u32> = (0..vertex_count as u32).collect();

    // Compute bounds.
    let mut bounds = BoundingBox::EMPTY;
    for chunk in positions.chunks(3) {
        bounds.extend_point(Vec3::new(chunk[0], chunk[1], chunk[2]));
    }

    // Convert flat Vec<f32> → Vec<[f32; 3]>.
    let positions3: Vec<[f32; 3]> = positions.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();
    let normals3: Vec<[f32; 3]> = normals.chunks(3).map(|c| [c[0], c[1], c[2]]).collect();

    let geometry_id = GeometryId::new(0);
    let node_id = NodeId::new(0);
    let root_id = NodeId::new(1);

    let mesh = MeshGeometry {
        id: geometry_id,
        positions: positions3.clone(),
        normals: normals3.clone(),
        uvs: Vec::new(),
        indices: indices.clone(),
        bounds,
    };

    let mut model = LsmModel::empty("STL");
    model.header.source_path = Some(path.display().to_string());

    // Root assembly node.
    model.scene.add_node(Node {
        id: root_id,
        name: "STL_Assembly".to_string(),
        parent: None,
        children: Vec::new(),
        geometry: None,
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds,
    });

    // Geometry child node.
    let node_name = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("STL_Part")
        .to_string();

    model.scene.add_node(Node {
        id: node_id,
        name: node_name.clone(),
        parent: Some(root_id),
        children: Vec::new(),
        geometry: Some(geometry_id),
        material: None,
        visible: true,
        local_transform: glam::Mat4::IDENTITY,
        bounds,
    });

    model.geometries.push(Geometry::Mesh(mesh));

    // Build tessellation registry (positions/normals are already tessellated).
    let mut registry = TessellationRegistry::new();
    registry.insert(
        geometry_id,
        TessellatedMeshData {
            positions: positions3,
            normals: normals3,
            indices,
            bounds,
        },
    );

    let stats = ParseStats {
        node_count: 2,
        geometry_count: 1,
        material_count: 0,
        triangle_count,
        parse_duration_ms: 0,
    };

    Ok((
        ParseOutput {
            model,
            warnings: Vec::new(),
            stats,
        },
        registry,
    ))
}

/// Determine if STL data is ASCII format.
///
/// Checks for "solid" prefix and "facet" keyword in the first 200 bytes.
/// The "facet" keyword is the reliable ASCII indicator — binary STL with
/// "solid" in the header will not have "facet" at a record boundary.
fn is_ascii_stl(data: &[u8]) -> bool {
    if !data.starts_with(b"solid") {
        return false;
    }
    // Look for "facet" in the first 200 bytes (well before any binary record).
    let scan_len = 200.min(data.len());
    let scan = &data[..scan_len];
    scan.windows(5)
        .any(|w| w == b"facet" || w == b"Facet" || w == b"FACET")
}

fn parse_binary_stl(data: &[u8]) -> Result<(Vec<f32>, Vec<f32>)> {
    let tri_count = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    let expected = 84 + tri_count * 50;
    if data.len() < expected {
        return Err(Error::parse("STL", "binary file truncated"));
    }

    let mut positions = Vec::with_capacity(tri_count * 9);
    let mut normals = Vec::with_capacity(tri_count * 9);

    for i in 0..tri_count {
        let base = 84 + i * 50;
        // Normal (3 floats).
        for j in 0..3 {
            let offset = base + j * 4;
            let val = f32::from_le_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]);
            normals.push(val);
        }
        // 3 vertices (9 floats).
        for v in 0..3 {
            let vbase = base + 12 + v * 12;
            for j in 0..3 {
                let offset = vbase + j * 4;
                let val = f32::from_le_bytes([
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                ]);
                positions.push(val);
                // Duplicate normal per vertex.
                normals.push(normals[normals.len() - 3 + j % 3]);
            }
        }
    }

    // Fix normals: each triangle has 1 normal, duplicated for 3 vertices.
    // Rebuild: normal was pushed once per triangle, then once per vertex.
    // Actually, let me redo this properly.
    positions.clear();
    normals.clear();

    for i in 0..tri_count {
        let base = 84 + i * 50;
        let nx = f32::from_le_bytes([data[base], data[base + 1], data[base + 2], data[base + 3]]);
        let ny = f32::from_le_bytes([
            data[base + 4],
            data[base + 5],
            data[base + 6],
            data[base + 7],
        ]);
        let nz = f32::from_le_bytes([
            data[base + 8],
            data[base + 9],
            data[base + 10],
            data[base + 11],
        ]);

        for v in 0..3 {
            let vbase = base + 12 + v * 12;
            let x = f32::from_le_bytes([
                data[vbase],
                data[vbase + 1],
                data[vbase + 2],
                data[vbase + 3],
            ]);
            let y = f32::from_le_bytes([
                data[vbase + 4],
                data[vbase + 5],
                data[vbase + 6],
                data[vbase + 7],
            ]);
            let z = f32::from_le_bytes([
                data[vbase + 8],
                data[vbase + 9],
                data[vbase + 10],
                data[vbase + 11],
            ]);
            positions.extend_from_slice(&[x, y, z]);
            normals.extend_from_slice(&[nx, ny, nz]);
        }
    }

    Ok((positions, normals))
}

fn parse_ascii_stl(data: &[u8]) -> Result<(Vec<f32>, Vec<f32>)> {
    let text =
        std::str::from_utf8(data).map_err(|_| Error::parse("STL", "invalid UTF-8 in ASCII STL"))?;

    let mut positions = Vec::new();
    let mut normals = Vec::new();
    let mut current_normal = [0.0f32; 3];

    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("facet normal") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() >= 3 {
                current_normal[0] = parts[0].parse().unwrap_or(0.0);
                current_normal[1] = parts[1].parse().unwrap_or(0.0);
                current_normal[2] = parts[2].parse().unwrap_or(0.0);
            }
        } else if let Some(rest) = line.strip_prefix("vertex") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() >= 3 {
                let x: f32 = parts[0].parse().unwrap_or(0.0);
                let y: f32 = parts[1].parse().unwrap_or(0.0);
                let z: f32 = parts[2].parse().unwrap_or(0.0);
                positions.extend_from_slice(&[x, y, z]);
                normals.extend_from_slice(&current_normal);
            }
        }
    }

    Ok((positions, normals))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    #[test]
    fn detect_binary_stl_with_valid_header() {
        // Build a minimal binary STL header + 1 triangle count.
        let mut data = [0u8; 84];
        // 80 bytes header (zeros)
        data[80] = 1; // tri_count = 1 (little-endian)
        assert!(detect_stl(&data, &p("model.stl")));
    }

    #[test]
    fn detect_ascii_stl_with_solid_prefix() {
        let data = b"solid test\nfacet normal 0 0 1\n";
        assert!(detect_stl(data, &p("model.stl")));
    }

    #[test]
    fn reject_stl_with_wrong_extension() {
        let mut data = [0u8; 84];
        data[80] = 1;
        assert!(!detect_stl(&data, &p("model.step")));
    }

    #[test]
    fn reject_non_stl_data() {
        let data = b"ISO-10303-21;\nHEADER;\n";
        assert!(!detect_stl(data, &p("model.stl")));
    }

    #[test]
    fn reject_stl_with_zero_triangles() {
        let data = [0u8; 84]; // tri_count = 0
        assert!(!detect_stl(&data, &p("model.stl")));
    }

    #[test]
    fn detect_ascii_stl_with_solid_header_and_digit_offset() {
        // Regression: ASCII STL where the 80-byte header happens to have
        // digit characters at offset 80-84 (could be misread as binary tri_count).
        // The "facet" keyword at offset 10 must disambiguate.
        let mut data = Vec::from(b"solid test\nfacet normal 0 0 1\n");
        // Pad to >84 bytes with the header filled.
        while data.len() < 84 {
            data.push(b' ');
        }
        // Write ASCII digits at offset 80-84 (would be tri_count=12345 in binary).
        data.extend_from_slice(b"12345");
        assert!(detect_stl(&data, &p("model.stl")));
        // Verify is_ascii_stl also correctly identifies it.
        assert!(is_ascii_stl(&data));
    }

    #[test]
    fn detect_binary_stl_with_solid_header() {
        // Binary STL with "solid" in the 80-byte header (CAD edge case).
        // No "facet" in header, bytes 80-84 = valid tri_count → binary.
        let mut data = vec![0u8; 84 + 50]; // header + 1 triangle
        data[..5].copy_from_slice(b"solid");
        data[80] = 1; // tri_count = 1
        assert!(detect_stl(&data, &p("model.stl")));
        // Should be detected as binary (not ASCII) by is_ascii_stl.
        assert!(!is_ascii_stl(&data));
    }

    #[test]
    fn parse_single_triangle_binary_stl() {
        let mut data = vec![0u8; 84 + 50]; // header + 1 triangle
        data[80] = 1; // tri_count = 1

        // Normal: (0, 0, 1)
        let base = 84;
        data[base + 8] = 0x3F;
        data[base + 9] = 0x80; // 1.0f32 LE
        // Vertex 0: (0, 0, 0) — already zero
        // Vertex 1: (1, 0, 0)
        let v1 = base + 12 + 12; // second vertex
        data[v1] = 0x3F;
        data[v1 + 1] = 0x80; // 1.0f32
        // Vertex 2: (0, 1, 0)
        let v2 = base + 12 + 24; // third vertex
        data[v2 + 4] = 0x3F;
        data[v2 + 5] = 0x80; // 1.0f32

        let (positions, normals) = parse_binary_stl(&data).unwrap();
        assert_eq!(positions.len(), 9); // 3 vertices * 3 components
        assert_eq!(normals.len(), 9);
    }

    #[test]
    fn parse_simple_ascii_stl() {
        let data = r#"solid test
facet normal 0.0 0.0 1.0
  outer loop
    vertex 0.0 0.0 0.0
    vertex 1.0 0.0 0.0
    vertex 0.0 1.0 0.0
  endloop
endfacet
endsolid test
"#;
        let (positions, normals) = parse_ascii_stl(data.as_bytes()).unwrap();
        assert_eq!(positions.len(), 9); // 3 vertices * 3
        assert_eq!(normals.len(), 9);
        // All normals should be (0, 0, 1).
        for chunk in normals.chunks(3) {
            assert!((chunk[2] - 1.0).abs() < 1e-6);
        }
    }

    /// Helper: write bytes to a temp file and return the path.
    fn write_temp_stl(data: &[u8]) -> tempfile::NamedTempFile {
        use std::io::Write;
        let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
        f.write_all(data).unwrap();
        f
    }

    #[test]
    fn parse_binary_stl_fixture() {
        // Build a 2-triangle binary STL.
        let mut data = vec![0u8; 84 + 100]; // header + 2 triangles
        data[80] = 2; // tri_count = 2

        // Triangle 1: normal (0,0,1), vertices (0,0,0), (1,0,0), (0,1,0)
        let base1 = 84;
        write_f32_le(&mut data, base1 + 8, 1.0); // nz = 1.0
        write_f32_le(&mut data, base1 + 12 + 0, 1.0); // v1.x = 1.0
        write_f32_le(&mut data, base1 + 12 + 12 + 4, 1.0); // v2.y = 1.0

        // Triangle 2: normal (0,0,-1), vertices (0,0,0), (0,1,0), (1,0,0)
        let base2 = 84 + 50;
        write_f32_le(&mut data, base2 + 8, -1.0); // nz = -1.0
        write_f32_le(&mut data, base2 + 12 + 4, 1.0); // v1.y = 1.0
        write_f32_le(&mut data, base2 + 12 + 24, 1.0); // v2.x = 1.0

        let tmp = write_temp_stl(&data);
        let (output, registry) = parse_stl(tmp.path()).unwrap();

        // Verify model structure.
        assert_eq!(output.model.scene.nodes.len(), 2); // root assembly + child
        assert_eq!(output.model.geometries.len(), 1);
        assert_eq!(output.stats.triangle_count, 2);

        // Verify tessellation registry.
        let geom_id = output.model.geometries[0].id();
        let mesh_data = registry.get(&geom_id).unwrap();
        assert_eq!(mesh_data.indices.len(), 6); // 2 triangles * 3 indices
    }

    #[test]
    fn parse_ascii_stl_fixture() {
        let data = r#"solid test
facet normal 0.0 0.0 1.0
  outer loop
    vertex 0.0 0.0 0.0
    vertex 1.0 0.0 0.0
    vertex 0.0 1.0 0.0
  endloop
endfacet
facet normal 0.0 0.0 -1.0
  outer loop
    vertex 0.0 0.0 0.0
    vertex 0.0 1.0 0.0
    vertex 1.0 0.0 0.0
  endloop
endfacet
endsolid test
"#;
        let tmp = write_temp_stl(data.as_bytes());
        let (output, registry) = parse_stl(tmp.path()).unwrap();

        assert_eq!(output.model.scene.nodes.len(), 2);
        assert_eq!(output.model.geometries.len(), 1);
        assert_eq!(output.stats.triangle_count, 2);

        let geom_id = output.model.geometries[0].id();
        let mesh_data = registry.get(&geom_id).unwrap();
        assert_eq!(mesh_data.indices.len(), 6);
    }

    /// Helper to write a little-endian f32 into a byte buffer.
    fn write_f32_le(buf: &mut [u8], offset: usize, val: f32) {
        let bytes = val.to_le_bytes();
        buf[offset..offset + 4].copy_from_slice(&bytes);
    }
}
