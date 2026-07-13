#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub(crate) mod dxf_detector;
pub mod format_route;
pub mod gltf_parser;
pub(crate) mod iges_detector;
pub(crate) mod lsm_detector;
pub(crate) mod stl_parser;

pub mod job;

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use mmforge_core::model::{Geometry, ParseOutput};
use mmforge_geometry::tessellation::TessellationRegistry;
use mmforge_render::Frustum;
use mmforge_render::memory::MemoryBudget;
use mmforge_render::packet::RenderPacket;
use mmforge_render::streaming::StreamingPacket;

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
    /// Pre-computed per-mesh base_color [r,g,b,a] from RenderMaterial.
    /// Keyed by `geometry_id` (== original RenderMesh.geometry_id) so that
    /// both the flat mesh list and chunked streaming lookups are correct
    /// even when geometry IDs are non-contiguous.
    mesh_base_colors: std::collections::HashMap<u32, [f32; 4]>,
    /// 2D draw list (populated for DXF documents, empty for 3D).
    draw_list: mmforge_render::draw2d::DrawingDrawList,
    /// Pre-computed CStrings for draw command text content.
    draw_text_cstrings: Vec<CString>,
    /// Pre-computed CStrings for layer names in the draw list.
    draw_layer_cstrings: Vec<CString>,
    /// Pre-computed CStrings for line type names per draw command.
    draw_linetype_cstrings: Vec<CString>,
    /// Pre-computed CStrings for layer line type names.
    layer_line_type_cstrings: Vec<Option<CString>>,
    /// Spatial index for 2D viewport culling.
    spatial_index: Option<mmforge_render::spatial2d::SpatialIndex2D>,
    /// Optional streaming packet built on demand.
    streaming_packet: Option<StreamingPacket>,
}

// --- Lifecycle ---

/// Helper: build MmfDocument from parse output + tessellation registry.
fn build_document(output: ParseOutput, registry: TessellationRegistry) -> MmfDocument {
    let packet = mmforge_render::build_render_packet(&registry);

    let default_color: [f32; 4] = [0.7, 0.7, 0.72, 1.0];
    let mesh_base_colors: std::collections::HashMap<u32, [f32; 4]> = {
        let mut instance_map: std::collections::HashMap<u32, u32> =
            std::collections::HashMap::new();
        for inst in &packet.instances {
            instance_map.entry(inst.mesh_id).or_insert(inst.material_id);
        }
        packet
            .meshes
            .iter()
            .map(|m| {
                let color = instance_map
                    .get(&m.mesh_id)
                    .and_then(|mat_id| {
                        packet
                            .materials
                            .iter()
                            .find(|mat| mat.material_id == *mat_id)
                            .map(|mat| mat.base_color)
                    })
                    .unwrap_or(default_color);
                (m.geometry_id, color)
            })
            .collect()
    };

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

    let draw_linetype_cstrings: Vec<CString> = draw_list
        .flat_commands
        .iter()
        .map(|fc| {
            fc.line_type
                .as_deref()
                .and_then(|s| CString::new(s).ok())
                .unwrap_or_default()
        })
        .collect();

    // Build layer line type CStrings for C ABI access.
    let layer_line_type_cstrings: Vec<Option<CString>> = output
        .model
        .geometries
        .iter()
        .find_map(|g| {
            if let Geometry::Drawing2D { drawing, .. } = g {
                Some(
                    drawing
                        .layers
                        .iter()
                        .map(|l| l.line_type.as_deref().and_then(|s| CString::new(s).ok()))
                        .collect(),
                )
            } else {
                None
            }
        })
        .unwrap_or_default();

    // Build spatial index for 2D viewport culling.
    let spatial_index = if draw_list.flat_commands.is_empty() {
        None
    } else {
        Some(mmforge_render::spatial2d::SpatialIndex2D::build(
            &draw_list.flat_commands,
            draw_list.bounds,
            32,
        ))
    };

    MmfDocument {
        packet,
        model: output.model,
        node_names,
        geometry_labels,
        mesh_base_colors,
        draw_list,
        draw_text_cstrings,
        draw_layer_cstrings,
        draw_linetype_cstrings,
        layer_line_type_cstrings,
        spatial_index,
        streaming_packet: None,
    }
}

/// Get a progress label for the detected format.
///
/// All call sites (sync `mmf_parse_file`, async `run_open_pipeline`,
/// and the loading UI) derive from the same `format_route::detect()`.
pub(crate) fn detect_format_name(header: &[u8], path: &std::path::Path) -> &'static str {
    format_route::detect(header, path).as_progress_label()
}

/// Shared parse + build pipeline used by the async job.
///
/// Detects the format from `header` and dispatches to the appropriate
/// progressive parser.  After parsing, builds a `MmfDocument`.
pub(crate) fn parse_with_detection(
    path: &std::path::Path,
    header: &[u8],
    progress: Option<&mmforge_core::progress::ProgressCallback>,
    cancel: &mmforge_core::cancel::CancellationToken,
) -> mmforge_core::Result<Box<MmfDocument>> {
    if cancel.is_cancelled() {
        return Err(mmforge_core::error::Error::Cancelled);
    }

    let fmt = format_route::detect(header, path);
    let route = format_route::parse_with_progress(fmt, path, progress, cancel)?;

    // Check cancellation before the expensive build step.
    if cancel.is_cancelled() {
        return Err(mmforge_core::error::Error::Cancelled);
    }

    if let Some(cb) = progress {
        cb(&mmforge_core::progress::ParseProgress::new(
            "building", 0, 1,
        ));
    }

    let (output, registry) = route.into_parts();
    Ok(Box::new(build_document(output, registry)))
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

/// Parse a file with auto-detection (STL, glTF/GLB, STEP, IGES, DXF, LSM/LSMC).
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

    let fmt = format_route::detect(&header, &path);
    let result = format_route::parse_sync(fmt, &path);

    match result {
        Ok(route) => {
            let (output, registry) = route.into_parts();
            Box::into_raw(Box::new(build_document(output, registry)))
        }
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

/// Returns the pre-computed base color for the given mesh index.
/// `out_rgba` must point to a 4-element f32 array.
/// Returns 0 on success, -1 if doc is null or index is out of range.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_mesh_base_color(
    doc: *const MmfDocument,
    index: u32,
    out_rgba: *mut f32,
) -> i32 {
    if doc.is_null() || out_rgba.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    let geom_id = doc.packet.meshes.get(index as usize).map(|m| m.geometry_id);
    match geom_id.and_then(|gid| doc.mesh_base_colors.get(&gid)) {
        Some(color) => {
            unsafe {
                *out_rgba.add(0) = color[0];
                *out_rgba.add(1) = color[1];
                *out_rgba.add(2) = color[2];
                *out_rgba.add(3) = color[3];
            }
            0
        }
        None => -1,
    }
}

/// Returns 1 if OCCT (OpenCASCADE) support was compiled into this build,
/// 0 otherwise.  macOS app can use this to show format-specific guidance.
///
/// Uses `mmforge_geometry::is_occt_available()` which checks
/// `cfg!(occt_found)` — set by `build.rs` only when headers, libraries,
/// and the C ABI shim were actually located and linked.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_occt_available() -> i32 {
    if mmforge_geometry::is_occt_available() {
        1
    } else {
        0
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

/// Render statistics.  All outputs are optional (pass NULL to skip).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_render_stats(
    doc: *const MmfDocument,
    out_mesh_count: *mut u32,
    out_vertex_count: *mut u32,
    out_triangle_count: *mut u32,
    out_memory_bytes: *mut u64,
    out_build_ms: *mut f64,
) {
    if doc.is_null() {
        return;
    }
    let doc = unsafe { &*doc };
    let s = &doc.packet.stats;
    if !out_mesh_count.is_null() {
        unsafe { *out_mesh_count = s.mesh_count as u32 };
    }
    if !out_vertex_count.is_null() {
        unsafe { *out_vertex_count = s.total_vertices as u32 };
    }
    if !out_triangle_count.is_null() {
        unsafe { *out_triangle_count = s.triangle_count as u32 };
    }
    if !out_memory_bytes.is_null() {
        unsafe { *out_memory_bytes = s.memory_bytes as u64 };
    }
    if !out_build_ms.is_null() {
        unsafe { *out_build_ms = s.build_duration_ms };
    }
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

/// Get the default line type name for a layer.  Returns NULL if Continuous.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_layer_line_type(
    doc: *const MmfDocument,
    index: u32,
) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.layer_line_type_cstrings.get(index as usize) {
        Some(Some(cs)) if !cs.is_empty() => cs.as_ptr(),
        _ => ptr::null(),
    }
}

/// Get the ACI color index for a layer.  Returns 7 (white) if invalid.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_drawing_layer_color_index(doc: *const MmfDocument, index: u32) -> i16 {
    if doc.is_null() {
        return 7;
    }
    let doc = unsafe { &*doc };
    for g in &doc.model.geometries {
        if let Geometry::Drawing2D { drawing, .. } = g {
            return drawing
                .layers
                .get(index as usize)
                .map_or(7, |l| l.color_index);
        }
    }
    7
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
        Some(fc) => {
            // Use the stable layer_name from FlatDrawCommand directly.
            let name = &fc.layer_name;
            if name.is_empty() {
                ptr::null()
            } else {
                // Safety: we need a stable pointer. Use the pre-computed cstring
                // as backing store, falling back to the layer index lookup.
                doc.draw_layer_cstrings
                    .get(fc.layer_index as usize)
                    .map(|cs| cs.as_ptr())
                    .unwrap_or(ptr::null())
            }
        }
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

/// Get line type name for a draw command.  Returns NULL if not set (Continuous).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_line_type(doc: *const MmfDocument, index: u32) -> *const c_char {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    match doc.draw_linetype_cstrings.get(index as usize) {
        Some(cs) if !cs.is_empty() => cs.as_ptr(),
        _ => ptr::null(),
    }
}

/// Get line weight for a draw command (in mm).  Returns 0.0 if not set.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_line_weight(doc: *const MmfDocument, index: u32) -> f64 {
    if doc.is_null() {
        return 0.0;
    }
    let doc = unsafe { &*doc };
    doc.draw_list
        .flat_commands
        .get(index as usize)
        .and_then(|fc| fc.line_weight)
        .unwrap_or(0.0)
}

/// Get line dash pattern count for a draw command.  Returns 0 if solid line.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_line_dash_count(doc: *const MmfDocument, index: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.draw_list
        .flat_commands
        .get(index as usize)
        .and_then(|fc| fc.line_dash.as_ref())
        .map(|d| d.len() as u32)
        .unwrap_or(0)
}

/// Get line dash pattern data for a draw command.
/// Writes up to `max_count` dash lengths to `out_dash`.
/// Returns number of values written, or 0 if no dash pattern.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_cmd_line_dash(
    doc: *const MmfDocument,
    index: u32,
    out_dash: *mut f64,
    max_count: u32,
) -> u32 {
    if doc.is_null() || out_dash.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    match doc
        .draw_list
        .flat_commands
        .get(index as usize)
        .and_then(|fc| fc.line_dash.as_ref())
    {
        Some(dash) => {
            let count = dash.len().min(max_count as usize);
            for (i, &v) in dash.iter().enumerate().take(count) {
                unsafe {
                    *out_dash.add(i) = v;
                }
            }
            count as u32
        }
        None => 0,
    }
}

/// Query spatial index for commands visible in the given viewport rect.
///
/// Returns:
/// - `-1` if no spatial index available (caller should fall back to full draw).
/// - `-1` if `doc` or `out_indices` is null.
/// - `0` if no commands are visible in the viewport (legitimate empty result).
/// - `>0` the total number of matching indices.  If `total > max_count`,
///   only `max_count` were written to `out_indices`; the caller should
///   reallocate with the returned total and re-query.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_draw_spatial_query(
    doc: *const MmfDocument,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
    out_indices: *mut u32,
    max_count: u32,
) -> i32 {
    if doc.is_null() || out_indices.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    let spatial = match &doc.spatial_index {
        Some(s) => s,
        None => return -1,
    };
    let viewport = mmforge_core::drawing::BBox2D {
        min: [min_x, min_y],
        max: [max_x, max_y],
    };
    let indices = spatial.query(viewport);
    let total = indices.len() as i32;
    let written = (indices.len()).min(max_count as usize);
    for (i, &idx) in indices.iter().enumerate().take(written) {
        unsafe {
            *out_indices.add(i) = idx;
        }
    }
    total
}

// ------------------------------------------------------------------
// Streaming / chunk-based progressive loading
// ------------------------------------------------------------------

/// Build a streaming packet from the document's render data.
///
/// Splits the internal `RenderPacket` into chunks respecting `budget_bytes`.
/// Returns the number of chunks (0 if empty or already built).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_build_streaming_packet(doc: *mut MmfDocument, budget_bytes: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &mut *doc };
    if let Some(sp) = &doc.streaming_packet {
        return sp.chunk_count() as u32;
    }
    let budget = MemoryBudget::new(budget_bytes as usize);
    let sp = StreamingPacket::from_packet(&doc.packet, &budget);
    let count = sp.chunk_count() as u32;
    doc.streaming_packet = Some(sp);
    count
}

/// Clear the streaming packet so `mmf_build_streaming_packet` rebuilds with a new budget.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_reset_streaming_packet(doc: *mut MmfDocument) {
    if doc.is_null() {
        return;
    }
    unsafe { &mut *doc }.streaming_packet = None;
}

/// Number of streaming chunks (0 if not built).
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_count(doc: *const MmfDocument) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .map_or(0, |sp| sp.chunk_count() as u32)
}

/// Number of meshes in chunk `chunk_idx`.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_count(doc: *const MmfDocument, chunk_idx: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .map_or(0, |c| c.meshes.len() as u32)
}

/// Number of instances in chunk `chunk_idx`.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_instance_count(doc: *const MmfDocument, chunk_idx: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .map_or(0, |c| c.instances.len() as u32)
}

/// AABB of chunk `chunk_idx`.  Writes 6 f32 to out_min/out_max. Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_bounds(
    doc: *const MmfDocument,
    chunk_idx: u32,
    out_min: *mut f32,
    out_max: *mut f32,
) -> i32 {
    if doc.is_null() || out_min.is_null() || out_max.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    if let Some(c) = doc
        .streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
    {
        let b = &c.chunk_bounds;
        unsafe {
            *out_min.offset(0) = b.min.x;
            *out_min.offset(1) = b.min.y;
            *out_min.offset(2) = b.min.z;
            *out_max.offset(0) = b.max.x;
            *out_max.offset(1) = b.max.y;
            *out_max.offset(2) = b.max.z;
        }
        1
    } else {
        0
    }
}

/// Number of batch groups in chunk `chunk_idx`.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_batch_count(doc: *const MmfDocument, chunk_idx: u32) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .map_or(0, |c| c.batches.len() as u32)
}

/// GPU memory estimate for chunk `chunk_idx` in bytes.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_memory_bytes(doc: *const MmfDocument, chunk_idx: u32) -> u64 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .map_or(0, |c| c.stats.memory_bytes as u64)
}

/// Total GPU memory across all chunks in bytes.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_total_memory(doc: *const MmfDocument) -> u64 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet.as_ref().map_or(0, |sp| {
        sp.iter_chunks().map(|c| c.stats.memory_bytes as u64).sum()
    })
}

/// Vertex count for mesh `mesh_idx` in chunk `chunk_idx`.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_vertex_count(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(0, |m| m.positions.len() as u32)
}

/// Index count for mesh `mesh_idx` in chunk `chunk_idx`.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_index_count(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> u32 {
    if doc.is_null() {
        return 0;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(0, |m| m.indices.len() as u32)
}

/// Geometry id for mesh `mesh_idx` in chunk `chunk_idx`.  Returns -1 on error.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_geometry_id(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> i32 {
    if doc.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(-1, |m| m.geometry_id as i32)
}

/// Borrowed float* to positions for mesh in chunk.  Valid until mmf_document_free.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_positions(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> *const f32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(ptr::null(), |m| m.positions.as_ptr() as *const f32)
}

/// Borrowed float* to normals for mesh in chunk.  Valid until mmf_document_free.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_normals(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> *const f32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(ptr::null(), |m| m.normals.as_ptr() as *const f32)
}

/// Borrowed u32* to indices for mesh in chunk.  Valid until mmf_document_free.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_indices(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
) -> *const u32 {
    if doc.is_null() {
        return ptr::null();
    }
    let doc = unsafe { &*doc };
    doc.streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map_or(ptr::null(), |m| m.indices.as_ptr())
}

/// Returns the pre-computed per-mesh material color for a chunk mesh.
///
/// Looks up the chunk mesh's `geometry_id` in `mesh_base_colors`
/// (a HashMap keyed by the original `RenderMesh.geometry_id`).
/// This is correct even when geometry IDs are non-contiguous.
/// `out_rgba` must point to a 4-element f32 array.
/// Returns 0 on success, -1 if chunk/mesh index out of range.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_chunk_mesh_base_color(
    doc: *const MmfDocument,
    chunk_idx: u32,
    mesh_idx: u32,
    out_rgba: *mut f32,
) -> i32 {
    if doc.is_null() || out_rgba.is_null() {
        return -1;
    }
    let doc = unsafe { &*doc };
    let geom_id = doc
        .streaming_packet
        .as_ref()
        .and_then(|sp| sp.chunk(chunk_idx as usize))
        .and_then(|c| c.meshes.get(mesh_idx as usize))
        .map(|m| m.geometry_id);
    match geom_id.and_then(|gid| doc.mesh_base_colors.get(&gid)) {
        Some(color) => {
            unsafe {
                *out_rgba.add(0) = color[0];
                *out_rgba.add(1) = color[1];
                *out_rgba.add(2) = color[2];
                *out_rgba.add(3) = color[3];
            }
            0
        }
        _ => -1,
    }
}

// ------------------------------------------------------------------
// Frustum culling helper (via C ABI)
// ------------------------------------------------------------------

/// Test whether an AABB is visible within a camera frustum.
///
/// The caller provides the camera description and receives a 1 (visible)
/// or 0 (culled).  Internally constructs an OrbitCamera + Frustum.
///
/// All 12 camera floats are required; aspect is the viewport width/height.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_frustum_aabb_visible(
    bounds_min: *const f32,
    bounds_max: *const f32,
    cam_target: *const f32,
    cam_distance: f32,
    cam_yaw: f32,
    cam_pitch: f32,
    cam_fov_y: f32,
    cam_near: f32,
    cam_far: f32,
    aspect: f32,
) -> i32 {
    if bounds_min.is_null() || bounds_max.is_null() || cam_target.is_null() {
        return 0;
    }
    let cam = mmforge_render::OrbitCamera {
        target: unsafe {
            glam::Vec3::new(
                *cam_target.offset(0),
                *cam_target.offset(1),
                *cam_target.offset(2),
            )
        },
        distance: cam_distance,
        yaw: cam_yaw,
        pitch: cam_pitch,
        fov_y: cam_fov_y,
        near: cam_near,
        far: cam_far,
    };
    let bb = mmforge_core::math::BoundingBox {
        min: unsafe {
            glam::Vec3::new(
                *bounds_min.offset(0),
                *bounds_min.offset(1),
                *bounds_min.offset(2),
            )
        },
        max: unsafe {
            glam::Vec3::new(
                *bounds_max.offset(0),
                *bounds_max.offset(1),
                *bounds_max.offset(2),
            )
        },
    };
    let vp = cam.projection_matrix(aspect) * cam.view_matrix();
    let mut f = Frustum::from_view_projection(&vp);
    f.normalise();
    if f.intersects_aabb(&bb) { 1 } else { 0 }
}
