#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

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

#[unsafe(no_mangle)]
pub extern "C" fn mmf_parse_step(path: *const c_char) -> *mut MmfDocument {
    if path.is_null() {
        set_last_error("null path");
        return ptr::null_mut();
    }
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("invalid UTF-8 path: {e}"));
            return ptr::null_mut();
        }
    };
    let path = std::path::Path::new(path_str);

    match mmforge_format_step::parse_step_with_tessellation(path) {
        Ok((output, registry)) => {
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
                        mmforge_core::model::Geometry::BRepHandleRef { label, .. } => {
                            label.as_str()
                        }
                        mmforge_core::model::Geometry::Mesh(_) => "Mesh",
                        mmforge_core::model::Geometry::Drawing2D { .. } => "Drawing2D",
                    };
                    CString::new(label).unwrap_or_default()
                })
                .collect();
            let doc = MmfDocument {
                packet,
                model: output.model,
                node_names,
                geometry_labels,
            };
            Box::into_raw(Box::new(doc))
        }
        Err(e) => {
            set_last_error(&format!("{e}"));
            ptr::null_mut()
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
