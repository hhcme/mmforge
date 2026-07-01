#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod dxf_detector;
mod gltf_parser;
mod stl_parser;

mod iges_detector;

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use mmforge_core::model::{Geometry, ParseOutput};
use mmforge_geometry::tessellation::TessellationRegistry;
use mmforge_render::packet::RenderPacket;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_last_error(msg: &str) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(msg).ok();
    });
}

pub struct MmfDocument {
    packet: RenderPacket,
    model: mmforge_core::model::LsmModel,
    /// Pre-computed CStrings for node names (borrowed by mmf_node_name).
    node_names: Vec<CString>,
    /// Pre-computed CStrings for geometry labels (borrowed by mmf_node_geometry_label).
    geometry_labels: Vec<CString>,
    /// 2D draw list (populated for DXF documents, empty for 3D).
    draw_list: mmforge_render::draw2d::DrawingDrawList,
    /// Pre-computed CStrings for draw command text content.
    draw_text_cstrings: Vec<CString>,
    /// Pre-computed CStrings for layer names in the draw list.
    draw_layer_cstrings: Vec<CString>,
}

// --- Lifecycle ---

/// Helper: build MmfDocument from parse output + tessellation registry.
fn build_document(output: ParseOutput, registry: TessellationRegistry) -> MmfDocument {
    let packet = mmforge_render::build_render_packet(&registry);
    let node_names: Vec<CString> = output
        .model
        .scene
        .nodes
        .iter()
        .map(|n| CString::new(n.name.as_str()).unwrap_or_default())
        .collect();
    let geometry_labels: Vec<CString> = output
        .model
        .geometries
        .iter()
        .map(|g| {
            let label = match g {
                Geometry::BRepHandleRef { label, .. } => label.as_str(),
                Geometry::Mesh(_) => "Mesh",
                Geometry::Drawing2D { .. } => "Drawing2D",
            };
            CString::new(label).unwrap_or_default()
        })
        .collect();

    // Build 2D draw list from Drawing2D geometry (if present).
    let draw_list = output
        .model
        .geometries
        .iter()
        .find_map(|g| {
            if let Geometry::Drawing2D { drawing, .. } = g {
                Some(mmforge_render::draw2d::build_draw_list(drawing))
            } else {
                None
            }
        })
        .unwrap_or(mmforge_render::draw2d::DrawingDrawList {
            layers: Vec::new(),
            bounds: mmforge_core::drawing::BBox2D::EMPTY,
            flat_commands: Vec::new(),
        });

    let draw_text_cstrings: Vec<CString> = draw_list
        .flat_commands
        .iter()
        .map(|fc| match &fc.cmd {
            mmforge_render::draw2d::DrawCommand2D::Text { content, .. } => {
                CString::new(content.as_str()).unwrap_or_default()
            }
            _ => CString::default(),
        })
        .collect();

    let draw_layer_cstrings: Vec<CString> = draw_list
        .layers
        .iter()
        .map(|l| CString::new(l.layer_name.as_str()).unwrap_or_default())
        .collect();

    MmfDocument {
        packet,
        model: output.model,
        node_names,
        geometry_labels,
        draw_list,
        draw_text_cstrings,
        draw_layer_cstrings,
    }
}

/// Parse a STEP file.  Returns NULL on error.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_parse_step(path: *const c_char) -> *mut MmfDocument {
    let path = match c_path_to_owned(path) {
        Some(p) => p,
        None => return ptr::null_mut(),
    };

    match mmforge_format_step::parse_step_with_tessellation(&path) {
        Ok((output, registry)) => Box::into_raw(Box::new(build_document(output, registry))),
        Err(e) => {
            set_last_error(&format!("{e}"));
            ptr::null_mut()
        }
    }
}

/// Parse a file with auto-detection (STL, glTF/GLB, STEP).
/// Returns NULL on error — call mmf_last_error() for the message.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_parse_file(path: *const c_char) -> *mut MmfDocument {
    let path = match c_path_to_owned(path) {
        Some(p) => p,
        None => return ptr::null_mut(),
    };

    // Read first 84 bytes for format detection (STL binary needs 80-byte header + u32 count).
    let header = match std::fs::read(&path) {
        Ok(data) => {
            let mut buf = [0u8; 84];
            let len = data.len().min(84);
            buf[..len].copy_from_slice(&data[..len]);
            buf
        }
        Err(e) => {
            set_last_error(&format!("cannot read file: {e}"));
            return ptr::null_mut();
        }
    };

    let result = if dxf_detector::detect_dxf(&header, &path) {
        // DXF produces Drawing2D, not tessellated meshes.
        // Wrap into (ParseOutput, empty TessellationRegistry).
        mmforge_format_dxf::parse_dxf(&path)
            .map(|(output, _drawing)| (output, TessellationRegistry::new()))
    } else if stl_parser::detect_stl(&header, &path) {
        stl_parser::parse_stl(&path)
    } else if gltf_parser::detect_gltf(&header, &path) {
        gltf_parser::parse_gltf(&path)
    } else if iges_detector::detect_iges(&header, &path) {
        mmforge_format_iges::parse_iges_with_tessellation(&path)
    } else if mmforge_format_step::detect::detect_step(&header, &path).is_some() {
        mmforge_format_step::parse_step_with_tessellation(&path)
    } else {
        // Try STEP as fallback (it has the most flexible detection).
        mmforge_format_step::parse_step_with_tessellation(&path)
    };

    match result {
        Ok((output, registry)) => Box::into_raw(Box::new(build_document(output, registry))),
        Err(e) => {
            set_last_error(&format!("{e}"));
            ptr::null_mut()
        }
    }
}

/// Helper: convert C string path to an owned `PathBuf`.
///
/// Copies the C string into Rust-owned memory so there is no lifetime
/// dependence on the caller's buffer.  Returns `None` (with last-error
/// set) on null pointer or invalid UTF-8.
fn c_path_to_owned(path: *const c_char) -> Option<std::path::PathBuf> {
    if path.is_null() {
        set_last_error("null path");
        return None;
    }
    match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => Some(std::path::PathBuf::from(s)),
        Err(e) => {
            set_last_error(&format!("invalid UTF-8 path: {e}"));
            None
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_document_free(doc: *mut MmfDocument) {
    if !doc.is_null() {
        unsafe {
            drop(Box::from_raw(doc));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_last_error() -> *const c_char {
    LAST_ERROR.with(|e| match e.borrow().as_ref() {
        Some(s) => s.as_ptr(),
        None => ptr::null(),
    })
}

// --- Version ---

const VERSION_CSTR: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

#[unsafe(no_mangle)]
pub extern "C" fn mmf_version() -> *const c_char {
    VERSION_CSTR.as_ptr() as *const c_char
}

// --- Mesh data ---

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.packet.meshes.len() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_vertex_count(doc: *const MmfDocument, index: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) => m.positions.len() as u32,
        None => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_index_count(doc: *const MmfDocument, index: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) => m.indices.len() as u32,
        None => 0,
    }
}

/// Get the GeometryId for a mesh at the given index.
/// Returns -1 if index is out of range.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_geometry_id(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) => m.geometry_id as i32,
        None => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_positions(doc: *const MmfDocument, index: u32) -> *const f32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) if !m.positions.is_empty() => m.positions.as_ptr() as *const f32,
        _ => ptr::null(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_normals(doc: *const MmfDocument, index: u32) -> *const f32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) if !m.normals.is_empty() => m.normals.as_ptr() as *const f32,
        _ => ptr::null(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_indices(doc: *const MmfDocument, index: u32) -> *const u32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.packet.meshes.get(index as usize) {
        Some(m) if !m.indices.is_empty() => m.indices.as_ptr(),
        _ => ptr::null(),
    }
}

// --- Scene bounds ---

#[unsafe(no_mangle)]
pub extern "C" fn mmf_scene_bounds(doc: *const MmfDocument, out_min: *mut f32, out_max: *mut f32) {
    if doc.is_null() || out_min.is_null() || out_max.is_null() {
        return;
    }
    let doc = unsafe { &*doc };
    let b = doc.packet.scene_bounds;
    unsafe {
        *out_min.add(0) = b.min.x;
        *out_min.add(1) = b.min.y;
        *out_min.add(2) = b.min.z;
        *out_max.add(0) = b.max.x;
        *out_max.add(1) = b.max.y;
        *out_max.add(2) = b.max.z;
    }
}

// --- Scene tree ---

#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.model.scene.nodes.len() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_name(doc: *const MmfDocument, index: u32) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.node_names.get(index as usize) {
        Some(s) => s.as_ptr(),
        None => ptr::null(),
    }
}

// --- Node details ---

/// Parent node index.  Returns -1 for root nodes or if index is invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_parent(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    match doc.model.scene.nodes.get(index as usize) {
        Some(node) => match node.parent {
            Some(parent_id) => {
                // Find the index of the parent node by ID.
                doc.model
                    .scene
                    .nodes
                    .iter()
                    .position(|n| n.id == parent_id)
                    .map(|i| i as i32)
                    .unwrap_or(-1)
            }
            None => -1,
        },
        None => -1,
    }
}

/// Whether the node at index has associated geometry.
/// Returns 1 if true, 0 if false or invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_has_geometry(
    doc: *const MmfDocument,
    index: u32,
) -> std::os::raw::c_int {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    if doc
        .model
        .scene
        .nodes
        .get(index as usize)
        .is_some_and(|n| n.geometry.is_some())
    {
        1
    } else {
        0
    }
}

/// Get the GeometryId for a node.
/// Returns -1 if the node has no geometry or index is invalid.
/// This is the authoritative key for node↔mesh mapping.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_geometry_id(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    match doc.model.scene.nodes.get(index as usize) {
        Some(node) => match node.geometry {
            Some(id) => id.get() as i32,
            None => -1,
        },
        None => -1,
    }
}

/// Get the mesh index in the RenderPacket for a given node.
/// Returns -1 if the node has no geometry or index is invalid.
///
/// The mapping is: node → geometry_id → position in model.geometries
/// → mesh index in RenderPacket (which is sorted by GeometryId).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_mesh_index(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    let node = match doc.model.scene.nodes.get(index as usize) {
        Some(n) => n,
        None => return -1,
    };
    let geom_id = match node.geometry {
        Some(id) => id,
        None => return -1,
    };
    // Find the geometry's position in model.geometries.
    // Since build_render_packet sorts by GeometryId, and model.geometries
    // is created in the same order, the index equals the mesh index.
    doc.model
        .geometries
        .iter()
        .position(|g| g.id() == geom_id)
        .map(|i| i as i32)
        .unwrap_or(-1)
}

/// Get the bounding box of a node.
/// Returns 1 on success, 0 if index invalid or bounds empty.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_bounds(
    doc: *const MmfDocument,
    index: u32,
    out_min: *mut f32,
    out_max: *mut f32,
) -> std::os::raw::c_int {
    if doc.is_null() || out_min.is_null() || out_max.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.model.scene.nodes.get(index as usize) {
        Some(node) if node.bounds.is_valid() => {
            let b = node.bounds;
            unsafe {
                *out_min.add(0) = b.min.x;
                *out_min.add(1) = b.min.y;
                *out_min.add(2) = b.min.z;
                *out_max.add(0) = b.max.x;
                *out_max.add(1) = b.max.y;
                *out_max.add(2) = b.max.z;
            }
            1
        }
        _ => 0,
    }
}

// Pre-computed CStrings for geometry labels.
// Stored alongside node_names in MmfDocument.

/// Get the geometry label for a node.  Returns NULL if no geometry.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_node_geometry_label(doc: *const MmfDocument, index: u32) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    let node = match doc.model.scene.nodes.get(index as usize) {
        Some(n) => n,
        None => return ptr::null(),
    };
    let geom_id = match node.geometry {
        Some(id) => id,
        None => return ptr::null(),
    };
    // Find the geometry index by ID, then return the pre-computed CString.
    doc.model
        .geometries
        .iter()
        .position(|g| g.id() == geom_id)
        .and_then(|pos| doc.geometry_labels.get(pos))
        .map(|s| s.as_ptr())
        .unwrap_or(ptr::null())
}

// --- Render stats ---

/// Total triangle count across all meshes.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_triangle_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.packet.stats.triangle_count as u32
}

/// Number of materials.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_material_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.packet.materials.len() as u32
}

/// Number of geometries in the model (distinct from mesh count).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_geometry_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.model.geometries.len() as u32
}

// --- 2D Drawing data ---

/// Check if the document contains a 2D drawing (has Drawing2D geometry).
/// Returns 1 if yes, 0 if no or null.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_is_2d_drawing(doc: *const MmfDocument) -> std::os::raw::c_int {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    if doc
        .model
        .geometries
        .iter()
        .any(|g| matches!(g, Geometry::Drawing2D { .. }))
    {
        1
    } else {
        0
    }
}

/// Get the number of 2D drawing entities.  Returns 0 if not a 2D drawing.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_entity_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            return drawing.entities.len() as u32;
        }
    }
    0
}

/// Get the number of layers in the 2D drawing.  Returns 0 if not a 2D drawing.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_layer_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            return drawing.layers.len() as u32;
        }
    }
    0
}

/// Get the 2D drawing bounding box.
/// Returns 1 on success, 0 if not a 2D drawing or no bounds.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_bounds(
    doc: *const MmfDocument,
    out_min_x: *mut f64,
    out_min_y: *mut f64,
    out_max_x: *mut f64,
    out_max_y: *mut f64,
) -> std::os::raw::c_int {
    if doc.is_null()
        || out_min_x.is_null()
        || out_min_y.is_null()
        || out_max_x.is_null()
        || out_max_y.is_null()
    {
        return 0;
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            let bbox = drawing.bounds();
            if bbox.is_valid() {
                unsafe {
                    *out_min_x = bbox.min[0];
                    *out_min_y = bbox.min[1];
                    *out_max_x = bbox.max[0];
                    *out_max_y = bbox.max[1];
                }
                return 1;
            }
        }
    }
    0
}

/// Get a layer name by index.  Returns NULL if out of range or not a 2D drawing.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_layer_name(doc: *const MmfDocument, index: u32) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            return match drawing.layers.get(index as usize) {
                Some(layer) => {
                    // We need to return a stable pointer.  Use the node names
                    // trick: find the scene node with this layer's name.
                    doc.node_names
                        .iter()
                        .find(|n| n.to_str().unwrap_or("") == layer.name)
                        .map(|s| s.as_ptr())
                        .unwrap_or(ptr::null())
                }
                None => ptr::null(),
            };
        }
    }
    ptr::null()
}

/// Check if a layer is visible by index.  Returns 1 if visible, 0 otherwise.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_layer_visible(
    doc: *const MmfDocument,
    index: u32,
) -> std::os::raw::c_int {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            return match drawing.layers.get(index as usize) {
                Some(layer) if layer.visible => 1,
                _ => 0,
            };
        }
    }
    0
}

// --- Draw command accessors (flat list) ---

/// Total number of draw commands across all layers.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.draw_list.flat_commands.len() as u32
}

/// Draw command type: 0=Line, 1=Circle, 2=Arc, 3=Polyline, 4=Text, -1=invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_type(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(fc) => match &fc.cmd {
            mmforge_render::draw2d::DrawCommand2D::Line { .. } => 0,
            mmforge_render::draw2d::DrawCommand2D::Circle { .. } => 1,
            mmforge_render::draw2d::DrawCommand2D::Arc { .. } => 2,
            mmforge_render::draw2d::DrawCommand2D::Polyline { .. } => 3,
            mmforge_render::draw2d::DrawCommand2D::Text { .. } => 4,
        },
        None => -1,
    }
}

/// Layer index for a draw command.  Returns -1 if invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_layer_index(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(fc) => fc.layer_index as i32,
        None => -1,
    }
}

/// Layer name for a draw command.  Returns NULL if invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_layer_name(doc: *const MmfDocument, index: u32) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(fc) => match doc.draw_layer_cstrings.get(fc.layer_index as usize) {
            Some(cs) => cs.as_ptr(),
            None => ptr::null(),
        },
        None => ptr::null(),
    }
}

/// Layer color index for a draw command.  Returns 7 (white) if invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_color_index(doc: *const MmfDocument, index: u32) -> i16 {
    if doc.is_null() {
        return 7;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(fc) => doc
            .draw_list
            .layers
            .get(fc.layer_index as usize)
            .map_or(7, |l| l.color_index),
        None => 7,
    }
}

/// Layer visibility for a draw command.  Returns 1 if visible.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_layer_visible(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(fc) => doc
            .draw_list
            .layers
            .get(fc.layer_index as usize)
            .map_or(0, |l| if l.visible { 1 } else { 0 }),
        None => 0,
    }
}

/// Read LINE command data.  Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_line(
    doc: *const MmfDocument,
    index: u32,
    out_x0: *mut f64,
    out_y0: *mut f64,
    out_x1: *mut f64,
    out_y1: *mut f64,
) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd: mmforge_render::draw2d::DrawCommand2D::Line { start, end },
            ..
        }) => {
            unsafe {
                *out_x0 = start[0];
                *out_y0 = start[1];
                *out_x1 = end[0];
                *out_y1 = end[1];
            }
            1
        }
        _ => 0,
    }
}

/// Read CIRCLE command data.  Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_circle(
    doc: *const MmfDocument,
    index: u32,
    out_cx: *mut f64,
    out_cy: *mut f64,
    out_r: *mut f64,
) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd: mmforge_render::draw2d::DrawCommand2D::Circle { center, radius },
            ..
        }) => {
            unsafe {
                *out_cx = center[0];
                *out_cy = center[1];
                *out_r = *radius;
            }
            1
        }
        _ => 0,
    }
}

/// Read ARC command data.  Angles in radians.  Returns 1 on success.
/// `out_ccw` is set to 1 for counter-clockwise, 0 for clockwise.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_arc(
    doc: *const MmfDocument,
    index: u32,
    out_cx: *mut f64,
    out_cy: *mut f64,
    out_r: *mut f64,
    out_start: *mut f64,
    out_end: *mut f64,
    out_ccw: *mut i32,
) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd:
                mmforge_render::draw2d::DrawCommand2D::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                    ccw,
                },
            ..
        }) => {
            unsafe {
                *out_cx = center[0];
                *out_cy = center[1];
                *out_r = *radius;
                *out_start = *start_angle;
                *out_end = *end_angle;
                *out_ccw = if *ccw { 1 } else { 0 };
            }
            1
        }
        _ => 0,
    }
}

/// Get POLYLINE point count.  Returns 0 if not a polyline.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_polyline_count(doc: *const MmfDocument, index: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd: mmforge_render::draw2d::DrawCommand2D::Polyline { points, .. },
            ..
        }) => points.len() as u32,
        _ => 0,
    }
}

/// Read a polyline point.  Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_polyline_point(
    doc: *const MmfDocument,
    cmd_index: u32,
    point_index: u32,
    out_x: *mut f64,
    out_y: *mut f64,
) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(cmd_index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd: mmforge_render::draw2d::DrawCommand2D::Polyline { points, .. },
            ..
        }) => match points.get(point_index as usize) {
            Some(p) => {
                unsafe {
                    *out_x = p[0];
                    *out_y = p[1];
                }
                1
            }
            None => 0,
        },
        _ => 0,
    }
}

/// Check if polyline is closed.  Returns 1 if closed.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_polyline_closed(doc: *const MmfDocument, index: u32) -> i32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd: mmforge_render::draw2d::DrawCommand2D::Polyline { closed, .. },
            ..
        }) if *closed => 1,
        _ => 0,
    }
}

/// Read TEXT command data.  Returns content pointer, NULL if not text.
/// out_x/out_y/out_height/out_rotation are filled on success.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_text(
    doc: *const MmfDocument,
    index: u32,
    out_x: *mut f64,
    out_y: *mut f64,
    out_height: *mut f64,
    out_rotation: *mut f64,
) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.draw_list.flat_commands.get(index as usize) {
        Some(mmforge_render::draw2d::FlatDrawCommand {
            cmd:
                mmforge_render::draw2d::DrawCommand2D::Text {
                    position,
                    height,
                    rotation,
                    ..
                },
            ..
        }) => {
            unsafe {
                *out_x = position[0];
                *out_y = position[1];
                *out_height = *height;
                *out_rotation = *rotation;
            }
            match doc.draw_text_cstrings.get(index as usize) {
                Some(cs) => cs.as_ptr(),
                None => ptr::null(),
            }
        }
        _ => ptr::null(),
    }
}
