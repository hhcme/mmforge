//! LSM file writer — produces `.lsm` v1 binary files.

use std::io::{Seek, SeekFrom, Write};

use super::binary::*;
use super::constants::*;
use crate::model::{Geometry, LsmModel, Material, Node, SceneTree};

#[derive(Debug, Clone)]
struct TocEntry {
    section_type: u32,
    offset: u64,
    length: u64,
}

pub fn write_lsm(model: &LsmModel, w: &mut (impl Write + Seek)) -> std::io::Result<u64> {
    let mut toc: Vec<TocEntry> = Vec::with_capacity(6);

    w.write_all(&MAGIC)?;
    write_u16(w, SCHEMA_VERSION)?;
    write_u16(w, feature_flags::NONE)?;
    write_u64(w, 0)?;
    write_u32(w, 0)?;
    write_u32(w, source_format_tag(&model.header.source_format))?;
    write_padding(w, 40)?; // fill to 64-byte header

    write_header_section(model, w, &mut toc)?;
    write_scene_tree_section(&model.scene, w, &mut toc)?;
    write_geometry_section(&model.geometries, w, &mut toc)?;
    write_materials_section(&model.materials, w, &mut toc)?;
    write_metadata_section(&model.metadata, w, &mut toc)?;

    let toc_offset = w.stream_position()?;
    write_u32(w, toc.len() as u32)?;
    for entry in &toc {
        write_u32(w, entry.section_type)?;
        write_u64(w, entry.offset)?;
        write_u64(w, entry.length)?;
    }

    w.seek(SeekFrom::Start(8))?;
    write_u64(w, toc_offset)?;
    write_u32(w, toc.len() as u32)?;

    let total = w.seek(SeekFrom::End(0))?;
    Ok(total)
}

fn write_header_section(
    model: &LsmModel,
    w: &mut (impl Write + Seek),
    toc: &mut Vec<TocEntry>,
) -> std::io::Result<()> {
    let offset = w.stream_position()?;
    write_string(w, &model.header.source_format)?;
    write_string(w, model.header.source_path.as_deref().unwrap_or(""))?;
    write_string(w, &model.header.parser_version)?;
    write_string(w, model.metadata.units.as_deref().unwrap_or(""))?;
    let length = w.stream_position()? - offset;
    toc.push(TocEntry {
        section_type: section::HEADER,
        offset,
        length,
    });
    Ok(())
}

fn write_scene_tree_section(
    scene: &SceneTree,
    w: &mut (impl Write + Seek),
    toc: &mut Vec<TocEntry>,
) -> std::io::Result<()> {
    let offset = w.stream_position()?;
    write_array_header(w, scene.nodes.len() as u32)?;
    write_u32(w, scene.root.get())?;
    for node in &scene.nodes {
        write_node(w, node)?;
    }
    let length = w.stream_position()? - offset;
    toc.push(TocEntry {
        section_type: section::SCENE_TREE,
        offset,
        length,
    });
    Ok(())
}

fn write_node(w: &mut impl Write, node: &Node) -> std::io::Result<()> {
    write_u32(w, node.id.get())?;
    write_string(w, &node.name)?;
    match node.parent {
        Some(p) => {
            write_u8(w, 1)?;
            write_u32(w, p.get())?;
        }
        None => write_u8(w, 0)?,
    }
    write_array_header(w, node.children.len() as u32)?;
    for &c in &node.children {
        write_u32(w, c.get())?;
    }
    match node.geometry {
        Some(g) => {
            write_u8(w, 1)?;
            write_u32(w, g.get())?;
        }
        None => write_u8(w, 0)?,
    }
    match node.material {
        Some(m) => {
            write_u8(w, 1)?;
            write_u32(w, m.get())?;
        }
        None => write_u8(w, 0)?,
    }
    write_u8(w, if node.visible { 1 } else { 0 })?;
    let cols = node.local_transform.to_cols_array_2d();
    for col in &cols {
        for &v in col.iter() {
            write_f32(w, v)?;
        }
    }
    let bb = &node.bounds;
    write_u8(w, if bb.is_valid() { 1 } else { 0 })?;
    if bb.is_valid() {
        write_vec3(w, bb.min)?;
        write_vec3(w, bb.max)?;
    }
    Ok(())
}

fn write_geometry_section(
    geoms: &[Geometry],
    w: &mut (impl Write + Seek),
    toc: &mut Vec<TocEntry>,
) -> std::io::Result<()> {
    let offset = w.stream_position()?;
    write_array_header(w, geoms.len() as u32)?;
    for g in geoms {
        let tag: u8 = match g {
            Geometry::BRepHandleRef { .. } => 1,
            Geometry::Mesh(_) => 2,
            Geometry::Drawing2D { .. } => 3,
        };
        write_u8(w, tag)?;
        write_u32(w, g.id().get())?;
        let bb = g.bounds();
        write_u8(w, if bb.is_valid() { 1 } else { 0 })?;
        if bb.is_valid() {
            write_vec3(w, bb.min)?;
            write_vec3(w, bb.max)?;
        }
        match g {
            Geometry::BRepHandleRef { label, .. } => {
                write_string(w, label)?;
            }
            Geometry::Mesh(mesh) => {
                write_array_header(w, mesh.positions.len() as u32)?;
                for p in &mesh.positions {
                    write_f32(w, p[0])?;
                    write_f32(w, p[1])?;
                    write_f32(w, p[2])?;
                }
                write_array_header(w, mesh.normals.len() as u32)?;
                for n in &mesh.normals {
                    write_f32(w, n[0])?;
                    write_f32(w, n[1])?;
                    write_f32(w, n[2])?;
                }
                write_array_header(w, mesh.uvs.len() as u32)?;
                for uv in &mesh.uvs {
                    write_f32(w, uv[0])?;
                    write_f32(w, uv[1])?;
                }
                write_array_header(w, mesh.indices.len() as u32)?;
                for &i in &mesh.indices {
                    write_u32(w, i)?;
                }
            }
            Geometry::Drawing2D { .. } => {
                write_u32(w, 0)?;
            }
        }
    }
    let length = w.stream_position()? - offset;
    toc.push(TocEntry {
        section_type: section::GEOMETRY,
        offset,
        length,
    });
    Ok(())
}

fn write_materials_section(
    materials: &[Material],
    w: &mut (impl Write + Seek),
    toc: &mut Vec<TocEntry>,
) -> std::io::Result<()> {
    let offset = w.stream_position()?;
    write_array_header(w, materials.len() as u32)?;
    for mat in materials {
        write_u32(w, mat.id.get())?;
        write_string(w, &mat.name)?;
        for &c in &mat.base_color {
            write_f32(w, c)?;
        }
        write_f32(w, mat.metallic)?;
        write_f32(w, mat.roughness)?;
    }
    let length = w.stream_position()? - offset;
    toc.push(TocEntry {
        section_type: section::MATERIALS,
        offset,
        length,
    });
    Ok(())
}

fn write_metadata_section(
    metadata: &crate::model::Metadata,
    w: &mut (impl Write + Seek),
    toc: &mut Vec<TocEntry>,
) -> std::io::Result<()> {
    let offset = w.stream_position()?;
    write_string(w, metadata.author.as_deref().unwrap_or(""))?;
    write_string(w, metadata.description.as_deref().unwrap_or(""))?;
    write_array_header(w, metadata.custom.len() as u32)?;
    for (k, v) in &metadata.custom {
        write_string(w, k)?;
        write_string(w, v)?;
    }
    let length = w.stream_position()? - offset;
    toc.push(TocEntry {
        section_type: section::METADATA,
        offset,
        length,
    });
    Ok(())
}

fn source_format_tag(fmt: &str) -> u32 {
    match fmt {
        "STEP" => source_format::STEP,
        "IGES" => source_format::IGES,
        "STL" => source_format::STL,
        "glTF" | "GLB" => source_format::GLTF,
        "DXF" => source_format::DXF,
        _ => source_format::UNKNOWN,
    }
}
