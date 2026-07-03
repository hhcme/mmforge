//! LSM file reader — reads `.lsm` v1 binary files with forward compatibility.

use std::io::{Read, Seek, SeekFrom};

use super::binary::*;
use super::constants::*;
use crate::drawing::Drawing2DGeometry;
use crate::ids::{GeometryId, MaterialId, NodeId};
use crate::math::BoundingBox;
use crate::model::{
    Geometry, LsmModel, Material, MeshGeometry, Metadata, ModelHeader, Node, SceneTree,
};

#[derive(Debug)]
pub enum ReadError {
    Io(std::io::Error),
    BadMagic {
        found: [u8; 4],
    },
    UnsupportedVersion {
        found: u16,
        max: u16,
    },
    MissingCoreSection {
        section_type: u32,
        name: &'static str,
    },
    CorruptSection {
        section_type: u32,
        reason: String,
    },
    CorruptToc {
        reason: String,
    },
    DuplicateSection {
        section_type: u32,
        name: &'static str,
    },
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::Io(e) => write!(f, "I/O error: {e}"),
            ReadError::BadMagic { found } => {
                write!(f, "bad magic: {found:02X?} (expected {:02X?})", MAGIC)
            }
            ReadError::UnsupportedVersion { found, max } => {
                write!(f, "unsupported version {found} (max supported {max})")
            }
            ReadError::MissingCoreSection { section_type, name } => {
                write!(f, "missing core section 0x{section_type:02X} ({name})")
            }
            ReadError::CorruptSection {
                section_type,
                reason,
            } => {
                write!(f, "corrupt section 0x{section_type:02X}: {reason}")
            }
            ReadError::CorruptToc { reason } => {
                write!(f, "corrupt TOC: {reason}")
            }
            ReadError::DuplicateSection { section_type, name } => {
                write!(f, "duplicate core section 0x{section_type:02X} ({name})")
            }
        }
    }
}

impl std::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ReadError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for ReadError {
    fn from(e: std::io::Error) -> Self {
        ReadError::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, ReadError>;

#[derive(Debug)]
struct SectionDesc {
    section_type: u32,
    offset: u64,
    length: u64,
}

/// Read an `LsmModel` from a `.lsm` binary file.
///
/// Unknown sections (types ≥ 0x10 or unrecognised core types) are silently
/// skipped.  Core sections that are missing raise `MissingCoreSection`.
/// Duplicate core sections raise `DuplicateSection`.
pub fn read_lsm(r: &mut (impl Read + Seek)) -> Result<LsmModel> {
    let file_size = r.seek(SeekFrom::End(0))?;
    r.seek(SeekFrom::Start(0))?;

    // --- File header ---
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(ReadError::BadMagic { found: magic });
    }
    let version = read_u16(r)?;
    if version > SCHEMA_VERSION {
        return Err(ReadError::UnsupportedVersion {
            found: version,
            max: SCHEMA_VERSION,
        });
    }
    let _flags = read_u16(r)?;
    let toc_offset = read_u64(r)?;
    let _toc_count = read_u32(r)?;
    let _source_format = read_u32(r)?;
    let mut pad = [0u8; 40];
    r.read_exact(&mut pad)?;

    if toc_offset < FILE_HEADER_SIZE as u64 || toc_offset > file_size {
        return Err(ReadError::CorruptToc {
            reason: format!("TOC offset {toc_offset} out of bounds (file size {file_size})"),
        });
    }

    let toc_size = calculate_toc_size(r, toc_offset, file_size)?;

    r.seek(SeekFrom::Start(toc_offset))?;
    let toc_count_total = read_u32(r)?;
    if toc_count_total > 1024 {
        return Err(ReadError::CorruptToc {
            reason: format!("implausible TOC count {toc_count_total}"),
        });
    }

    let mut sections: Vec<SectionDesc> = Vec::with_capacity(toc_count_total as usize);
    for _ in 0..toc_count_total {
        let st = read_u32(r)?;
        let off = read_u64(r)?;
        let len = read_u64(r)?;

        if off < FILE_HEADER_SIZE as u64 {
            return Err(ReadError::CorruptToc {
                reason: format!("section 0x{st:02X} offset {off} is inside the file header"),
            });
        }
        // Section must not overlap the TOC region.
        let toc_end = toc_offset + toc_size;
        if off >= toc_offset && off < toc_end {
            return Err(ReadError::CorruptToc {
                reason: format!(
                    "section 0x{st:02X} offset {off} starts inside TOC ({toc_offset}–{toc_end})"
                ),
            });
        }
        if off < toc_offset {
            match off.checked_add(len) {
                Some(end) if end > toc_offset => {
                    return Err(ReadError::CorruptToc {
                        reason: format!(
                            "section 0x{st:02X} range {off}–{end} crosses into TOC ({toc_offset}–{toc_end})"
                        ),
                    });
                }
                _ => {}
            }
        }
        match off.checked_add(len) {
            Some(end) if end <= file_size => {}
            _ => {
                return Err(ReadError::CorruptToc {
                    reason: format!(
                        "section 0x{st:02X} offset {off} + length {len} exceeds file size {file_size}"
                    ),
                });
            }
        }

        sections.push(SectionDesc {
            section_type: st,
            offset: off,
            length: len,
        });
    }

    // --- Read known sections, reject duplicates ---
    let mut header: Option<ModelHeader> = None;
    let mut scene: Option<SceneTree> = None;
    let mut geometries: Option<Vec<Geometry>> = None;
    let mut materials: Option<Vec<Material>> = None;
    let mut metadata: Option<Metadata> = None;

    for s in &sections {
        r.seek(SeekFrom::Start(s.offset))?;
        // Bounded read: wrap reader so it can only read `length` bytes.
        let mut limited = LimitedReader::new(r, s.length);

        match s.section_type {
            section::HEADER => {
                if header.is_some() {
                    return Err(ReadError::DuplicateSection {
                        section_type: section::HEADER,
                        name: "Header",
                    });
                }
                header = Some(read_header_section(&mut limited)?);
            }
            section::SCENE_TREE => {
                if scene.is_some() {
                    return Err(ReadError::DuplicateSection {
                        section_type: section::SCENE_TREE,
                        name: "SceneTree",
                    });
                }
                scene = Some(read_scene_tree_section(&mut limited)?);
            }
            section::GEOMETRY => {
                if geometries.is_some() {
                    return Err(ReadError::DuplicateSection {
                        section_type: section::GEOMETRY,
                        name: "Geometry",
                    });
                }
                geometries = Some(read_geometry_section(&mut limited)?);
            }
            section::MATERIALS => {
                if materials.is_some() {
                    return Err(ReadError::DuplicateSection {
                        section_type: section::MATERIALS,
                        name: "Materials",
                    });
                }
                materials = Some(read_materials_section(&mut limited)?);
            }
            section::METADATA => {
                if metadata.is_some() {
                    return Err(ReadError::DuplicateSection {
                        section_type: section::METADATA,
                        name: "Metadata",
                    });
                }
                metadata = Some(read_metadata_section(&mut limited)?);
            }
            _ => {} // skip
        }
    }

    Ok(LsmModel {
        header: header.ok_or(ReadError::MissingCoreSection {
            section_type: section::HEADER,
            name: "Header",
        })?,
        scene: scene.ok_or(ReadError::MissingCoreSection {
            section_type: section::SCENE_TREE,
            name: "SceneTree",
        })?,
        geometries: geometries.ok_or(ReadError::MissingCoreSection {
            section_type: section::GEOMETRY,
            name: "Geometry",
        })?,
        materials: materials.ok_or(ReadError::MissingCoreSection {
            section_type: section::MATERIALS,
            name: "Materials",
        })?,
        metadata: metadata.ok_or(ReadError::MissingCoreSection {
            section_type: section::METADATA,
            name: "Metadata",
        })?,
    })
}

/// Compute total TOC size in bytes from `toc_offset` to end of last TOC entry.
fn calculate_toc_size(r: &mut (impl Read + Seek), toc_offset: u64, _file_size: u64) -> Result<u64> {
    r.seek(SeekFrom::Start(toc_offset))?;
    let count = read_u32(r)?;
    if count > 1024 {
        return Err(ReadError::CorruptToc {
            reason: format!("implausible TOC count {count}"),
        });
    }
    Ok(4 + count as u64 * TOC_ENTRY_SIZE as u64)
}

/// Wraps a reader to limit total readable bytes, preventing section parsers
/// from reading past the declared section boundary.
struct LimitedReader<'a, R> {
    inner: &'a mut R,
    remaining: u64,
}

impl<'a, R: Read> LimitedReader<'a, R> {
    fn new(inner: &'a mut R, limit: u64) -> Self {
        Self {
            inner,
            remaining: limit,
        }
    }
}

impl<R: Read> Read for LimitedReader<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.remaining == 0 {
            return Ok(0);
        }
        let max = (buf.len() as u64).min(self.remaining) as usize;
        let n = self.inner.read(&mut buf[..max])?;
        self.remaining -= n as u64;
        Ok(n)
    }
}

// --- Section readers (unchanged logic, same function bodies) ---

fn read_header_section(r: &mut impl Read) -> Result<ModelHeader> {
    let source_format = read_string(r)?;
    let source_path = read_string(r)?;
    let parser_version = read_string(r)?;
    Ok(ModelHeader {
        source_format,
        source_path: if source_path.is_empty() {
            None
        } else {
            Some(source_path)
        },
        parser_version,
    })
}

fn read_scene_tree_section(r: &mut impl Read) -> Result<SceneTree> {
    let node_count = read_array_count(r)?;
    let root_id_u32 = read_u32(r)?;
    let root = NodeId::new(root_id_u32);
    let mut nodes: Vec<Node> = Vec::with_capacity(node_count as usize);
    for _ in 0..node_count {
        nodes.push(read_node(r)?);
    }
    Ok(SceneTree { nodes, root })
}

fn read_node(r: &mut impl Read) -> Result<Node> {
    let id = NodeId::new(read_u32(r)?);
    let name = read_string(r)?;
    let parent = read_option_node_id(r)?;
    let child_count = read_array_count(r)?;
    let mut children = Vec::with_capacity(child_count as usize);
    for _ in 0..child_count {
        children.push(NodeId::new(read_u32(r)?));
    }
    let geometry = read_option_geom_id(r)?;
    let material = read_option_mat_id(r)?;
    let visible = read_u8(r)? != 0;
    let local_transform = read_mat4(r)?;
    let has_bounds = read_u8(r)? != 0;
    let bounds = if has_bounds {
        let min = read_vec3(r)?;
        let max = read_vec3(r)?;
        BoundingBox { min, max }
    } else {
        BoundingBox::EMPTY
    };
    Ok(Node {
        id,
        name,
        parent,
        children,
        geometry,
        material,
        visible,
        local_transform,
        bounds,
    })
}

fn read_geometry_section(r: &mut impl Read) -> Result<Vec<Geometry>> {
    let count = read_array_count(r)?;
    let mut geoms = Vec::with_capacity(count as usize);
    for _ in 0..count {
        geoms.push(read_geometry(r)?);
    }
    Ok(geoms)
}

fn read_geometry(r: &mut impl Read) -> Result<Geometry> {
    let tag = read_u8(r)?;
    let id = GeometryId::new(read_u32(r)?);
    let has_bounds = read_u8(r)? != 0;
    let min = if has_bounds {
        read_vec3(r)?
    } else {
        glam::Vec3::ZERO
    };
    let max = if has_bounds {
        read_vec3(r)?
    } else {
        glam::Vec3::ZERO
    };
    let bounds = if has_bounds {
        BoundingBox { min, max }
    } else {
        BoundingBox::EMPTY
    };
    match tag {
        1 => {
            let label = read_string(r)?;
            Ok(Geometry::BRepHandleRef { id, bounds, label })
        }
        2 => {
            let mesh = read_mesh_data(r)?;
            Ok(Geometry::Mesh(MeshGeometry {
                id,
                positions: mesh.0,
                normals: mesh.1,
                uvs: mesh.2,
                indices: mesh.3,
                bounds,
            }))
        }
        3 => {
            let _entity_count = read_u32(r)?;
            Ok(Geometry::Drawing2D {
                id,
                bounds,
                drawing: Box::new(Drawing2DGeometry::new()),
            })
        }
        _ => Err(ReadError::CorruptSection {
            section_type: section::GEOMETRY,
            reason: format!("unknown geometry tag {tag}"),
        }),
    }
}

type MeshData = (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<[f32; 2]>, Vec<u32>);

fn read_mesh_data(r: &mut impl Read) -> Result<MeshData> {
    let pc = read_array_count(r)? as usize;
    let mut positions = Vec::with_capacity(pc);
    for _ in 0..pc {
        positions.push([read_f32(r)?, read_f32(r)?, read_f32(r)?]);
    }
    let nc = read_array_count(r)? as usize;
    let mut normals = Vec::with_capacity(nc);
    for _ in 0..nc {
        normals.push([read_f32(r)?, read_f32(r)?, read_f32(r)?]);
    }
    let uc = read_array_count(r)? as usize;
    let mut uvs = Vec::with_capacity(uc);
    for _ in 0..uc {
        uvs.push([read_f32(r)?, read_f32(r)?]);
    }
    let ic = read_array_count(r)? as usize;
    let mut indices = Vec::with_capacity(ic);
    for _ in 0..ic {
        indices.push(read_u32(r)?);
    }
    Ok((positions, normals, uvs, indices))
}

fn read_materials_section(r: &mut impl Read) -> Result<Vec<Material>> {
    let count = read_array_count(r)?;
    let mut materials = Vec::with_capacity(count as usize);
    for _ in 0..count {
        materials.push(read_material(r)?);
    }
    Ok(materials)
}

fn read_material(r: &mut impl Read) -> Result<Material> {
    let id = MaterialId::new(read_u32(r)?);
    let name = read_string(r)?;
    let mut base_color = [0.0f32; 4];
    for c in &mut base_color {
        *c = read_f32(r)?;
    }
    let metallic = read_f32(r)?;
    let roughness = read_f32(r)?;
    Ok(Material {
        id,
        name,
        base_color,
        metallic,
        roughness,
    })
}

fn read_metadata_section(r: &mut impl Read) -> Result<Metadata> {
    let units = read_string(r)?;
    let units = if units.is_empty() { None } else { Some(units) };
    let author = read_string(r)?;
    let description = read_string(r)?;
    let description = if description.is_empty() {
        None
    } else {
        Some(description)
    };
    let custom_count = read_array_count(r)?;
    let mut custom = std::collections::HashMap::with_capacity(custom_count as usize);
    for _ in 0..custom_count {
        let k = read_string(r)?;
        let v = read_string(r)?;
        custom.insert(k, v);
    }
    Ok(Metadata {
        units,
        author: if author.is_empty() {
            None
        } else {
            Some(author)
        },
        description,
        custom,
    })
}

fn read_option_node_id(r: &mut impl Read) -> Result<Option<NodeId>> {
    if read_u8(r)? != 0 {
        Ok(Some(NodeId::new(read_u32(r)?)))
    } else {
        Ok(None)
    }
}

fn read_option_geom_id(r: &mut impl Read) -> Result<Option<GeometryId>> {
    if read_u8(r)? != 0 {
        Ok(Some(GeometryId::new(read_u32(r)?)))
    } else {
        Ok(None)
    }
}

fn read_option_mat_id(r: &mut impl Read) -> Result<Option<MaterialId>> {
    if read_u8(r)? != 0 {
        Ok(Some(MaterialId::new(read_u32(r)?)))
    } else {
        Ok(None)
    }
}

fn read_mat4(r: &mut impl Read) -> Result<glam::Mat4> {
    let mut data = [0.0f32; 16];
    for v in &mut data {
        *v = read_f32(r)?;
    }
    let cols = [
        glam::Vec4::new(data[0], data[1], data[2], data[3]),
        glam::Vec4::new(data[4], data[5], data[6], data[7]),
        glam::Vec4::new(data[8], data[9], data[10], data[11]),
        glam::Vec4::new(data[12], data[13], data[14], data[15]),
    ];
    Ok(glam::Mat4::from_cols(cols[0], cols[1], cols[2], cols[3]))
}
