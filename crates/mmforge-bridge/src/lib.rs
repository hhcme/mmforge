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
            let doc = MmfDocument {
                packet,
                model: output.model,
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
    match doc.model.scene.nodes.get(index as usize) {
        Some(n) => {
            // Leak a CString — caller does not free.
            // For a production app, use a string table in MmfDocument.
            CString::new(n.name.as_str())
                .map(|s| s.into_raw())
                .unwrap_or(ptr::null_mut())
        }
        None => ptr::null(),
    }
}

// --- Render stats ---

#[unsafe(no_mangle)]
pub extern "C" fn mmf_triangle_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.packet.stats.triangle_count as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn mmf_material_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    unsafe { &*doc }.packet.materials.len() as u32
}
