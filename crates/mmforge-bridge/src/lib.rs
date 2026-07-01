#![allow(clippy::not_unsafe_ptr_arg_deref)]

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
    MmfDocument {
        packet,
        model: output.model,
        node_names,
        geometry_labels,
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

    let result = if stl_parser::detect_stl(&header, &path) {
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
