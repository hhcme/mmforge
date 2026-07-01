//! Safe Rust wrappers over the raw OCCT C ABI ([`super::sys`]).
//!
//! This module converts raw C pointers and status codes into idiomatic
//! Rust types (`Result`, `String`, `BoundingBox`).  It is the **only**
//! place in the Rust codebase that calls `unsafe` OCCT functions.
//!
//! # Conditional compilation
//!
//! - **`occt_found`** (set by build.rs when OCCT is actually found):
//!   real implementations that call into the C shim.
//! - **`feature = "occt"` but NOT `occt_found`**: stub implementations
//!   that return `OcctError::NotAvailable`.  The types are still usable
//!   for API compatibility.
//!
//! # Resource ownership
//!
//! - [`StepReaderAdapter`] owns the `STEPControl_Reader` pointer and
//!   frees it on `Drop`.
//! - Shape pointers are **borrowed** from the reader; they are freed
//!   when the reader is dropped.  [`ShapeHandle`] holds a raw pointer
//!   but does **not** free it — the lifetime is tied to the reader.

use super::OcctError;
use std::path::Path;

#[cfg(occt_found)]
use super::shape::{OcctShapeHandle, ShapeType};
#[cfg(occt_found)]
use mmforge_core::math::BoundingBox;
#[cfg(occt_found)]
use std::ffi::{CStr, CString};

// ---------------------------------------------------------------------------
// Types (always available when feature = "occt")
// ---------------------------------------------------------------------------

/// Adapter for `STEPControl_Reader`.  Owns the C++ object and frees it on drop.
///
/// Contains a `*const ()` to make the type `!Send + !Sync` without
/// needing the unstable negative impls feature.
#[allow(dead_code)] // ptr is read in the occt_found impl but not in the stub
pub struct StepReaderAdapter {
    ptr: *mut super::sys::StepControlReader,
    _not_send_sync: std::marker::PhantomData<*const ()>,
}

impl std::fmt::Debug for StepReaderAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StepReaderAdapter")
            .field("ptr", &self.ptr)
            .finish()
    }
}

/// Borrowed handle to a `TopoDS_Shape`.  Does NOT own the pointer.
///
/// Stores both the shape pointer and the owning reader pointer.
/// The reader pointer is needed for shape queries that require XDE
/// context (e.g. label lookup from STEP product names).
#[allow(dead_code)] // fields are read in the occt_found impl but not in the stub
pub struct ShapeHandle<'a> {
    reader_ptr: *const super::sys::StepControlReader,
    ptr: *const super::sys::TopoDsShape,
    _lifetime: std::marker::PhantomData<&'a ()>,
}

// ---------------------------------------------------------------------------
// Real implementation (only when OCCT is actually found and linked)
// ---------------------------------------------------------------------------

/// C ABI version expected by this Rust code.
/// Must match `MMFORGE_SHIM_ABI_VERSION` in `mmforge_occt_shim.h`.
/// Bumped on every ABI-incompatible change to the shim.
#[cfg(occt_found)]
const EXPECTED_ABI_VERSION: i32 = 3;

// ---------------------------------------------------------------------------
// IGES adapter (same pattern as STEP)
// ---------------------------------------------------------------------------

/// Adapter for `IGESControl_Reader`.  Owns the C++ object and frees it on drop.
#[allow(dead_code)]
pub struct IgesReaderAdapter {
    ptr: *mut super::sys::IgesControlReader,
    _not_send_sync: std::marker::PhantomData<*const ()>,
}

impl std::fmt::Debug for IgesReaderAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IgesReaderAdapter")
            .field("ptr", &self.ptr)
            .finish()
    }
}

/// Borrowed handle to a `TopoDS_Shape` from an IGES reader.
#[allow(dead_code)]
pub struct IgesShapeHandle<'a> {
    reader_ptr: *const super::sys::IgesControlReader,
    ptr: *const super::sys::TopoDsShape,
    _lifetime: std::marker::PhantomData<&'a ()>,
}

#[cfg(occt_found)]
impl IgesReaderAdapter {
    pub fn new() -> Result<Self, OcctError> {
        let actual = unsafe { super::sys::mmforge_abi_version() };
        if actual != EXPECTED_ABI_VERSION {
            return Err(OcctError::NotAvailable(format!(
                "OCCT shim ABI version mismatch: expected {EXPECTED_ABI_VERSION}, \
                 got {actual}. Rebuild libmmforge_occt_shim.a."
            )));
        }
        let ptr = unsafe { super::sys::mmforge_iges_reader_new() };
        if ptr.is_null() {
            return Err(OcctError::NotAvailable(
                "failed to allocate IGESControl_Reader".to_string(),
            ));
        }
        Ok(Self {
            ptr,
            _not_send_sync: std::marker::PhantomData,
        })
    }

    pub fn read_file(&mut self, path: &Path) -> Result<(), OcctError> {
        let c_path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| OcctError::StepError("path contains null byte".to_string()))?;
        let status =
            unsafe { super::sys::mmforge_iges_reader_read_file(self.ptr, c_path.as_ptr()) };
        status_to_result(status)
    }

    pub fn transfer_roots(&mut self) -> Result<(), OcctError> {
        let status = unsafe { super::sys::mmforge_iges_reader_transfer_roots(self.ptr) };
        status_to_result(status)
    }

    pub fn root_count(&self) -> usize {
        unsafe { super::sys::mmforge_iges_reader_root_count(self.ptr) as usize }
    }

    pub fn get_root(&self, index: usize) -> Result<IgesShapeHandle<'_>, OcctError> {
        let ptr =
            unsafe { super::sys::mmforge_iges_reader_get_root(self.ptr, index as std::ffi::c_int) };
        if ptr.is_null() {
            return Err(OcctError::ShapeError(format!(
                "root shape index {index} out of bounds"
            )));
        }
        Ok(IgesShapeHandle {
            reader_ptr: self.ptr,
            ptr,
            _lifetime: std::marker::PhantomData,
        })
    }

    pub fn warnings(&self) -> Vec<String> {
        let count = unsafe { super::sys::mmforge_iges_reader_warning_count(self.ptr) as usize };
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let ptr = unsafe {
                super::sys::mmforge_iges_reader_get_warning(self.ptr, i as std::ffi::c_int)
            };
            if !ptr.is_null() {
                let msg = unsafe { CStr::from_ptr(ptr) }
                    .to_string_lossy()
                    .into_owned();
                out.push(msg);
            }
        }
        out
    }

    /// Raw pointer for tessellation (cast to StepControlReader* since
    /// mmforge_tessellate_shape ignores the reader parameter).
    fn as_step_ptr(&self) -> *const super::sys::StepControlReader {
        self.ptr as *const super::sys::StepControlReader
    }
}

#[cfg(not(occt_found))]
impl IgesReaderAdapter {
    pub fn new() -> Result<Self, OcctError> {
        Err(occt_not_available())
    }
    pub fn read_file(&mut self, _path: &Path) -> Result<(), OcctError> {
        Err(occt_not_available())
    }
    pub fn transfer_roots(&mut self) -> Result<(), OcctError> {
        Err(occt_not_available())
    }
    pub fn root_count(&self) -> usize {
        0
    }
    pub fn get_root(&self, _index: usize) -> Result<IgesShapeHandle<'_>, OcctError> {
        Err(occt_not_available())
    }
    pub fn warnings(&self) -> Vec<String> {
        Vec::new()
    }
}

impl Drop for IgesReaderAdapter {
    fn drop(&mut self) {
        #[cfg(occt_found)]
        if !self.ptr.is_null() {
            unsafe { super::sys::mmforge_iges_reader_free(self.ptr) };
        }
    }
}

#[cfg(occt_found)]
impl<'a> IgesShapeHandle<'a> {
    pub fn shape_type(&self) -> ShapeType {
        let raw = unsafe { super::sys::mmforge_iges_shape_type(self.reader_ptr, self.ptr) };
        occt_to_shape_type(raw)
    }

    pub fn bbox(&self) -> Result<BoundingBox, OcctError> {
        let mut raw = super::sys::OcctBBox {
            min_x: 0.0,
            min_y: 0.0,
            min_z: 0.0,
            max_x: 0.0,
            max_y: 0.0,
            max_z: 0.0,
        };
        let status =
            unsafe { super::sys::mmforge_iges_shape_bbox(self.reader_ptr, self.ptr, &mut raw) };
        status_to_result(status)?;
        Ok(BoundingBox::new(
            glam::Vec3::new(raw.min_x as f32, raw.min_y as f32, raw.min_z as f32),
            glam::Vec3::new(raw.max_x as f32, raw.max_y as f32, raw.max_z as f32),
        ))
    }

    pub fn label(&self) -> Option<String> {
        let ptr = unsafe { super::sys::mmforge_iges_shape_label(self.reader_ptr, self.ptr) };
        if ptr.is_null() {
            return None;
        }
        Some(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    pub fn to_handle(&self, fallback_label: &str) -> Result<OcctShapeHandle, OcctError> {
        let bounds = self.bbox().unwrap_or(BoundingBox::EMPTY);
        let label = self.label().unwrap_or_else(|| fallback_label.to_string());
        Ok(OcctShapeHandle {
            label,
            bounds,
            shape_type: self.shape_type(),
        })
    }
}

#[cfg(occt_found)]
impl StepReaderAdapter {
    /// Create a new reader.  Returns `Err` if allocation fails or if
    /// the linked shim has an incompatible C ABI version.
    pub fn new() -> Result<Self, OcctError> {
        // Runtime ABI version check — catches stale shims that passed
        // nm symbol-name validation but have wrong function signatures.
        let actual = unsafe { super::sys::mmforge_abi_version() };
        if actual != EXPECTED_ABI_VERSION {
            return Err(OcctError::NotAvailable(format!(
                "OCCT shim ABI version mismatch: expected {EXPECTED_ABI_VERSION}, \
                 got {actual}. Rebuild libmmforge_occt_shim.a."
            )));
        }

        let ptr = unsafe { super::sys::mmforge_step_reader_new() };
        if ptr.is_null() {
            return Err(OcctError::NotAvailable(
                "failed to allocate STEPControl_Reader".to_string(),
            ));
        }
        Ok(Self {
            ptr,
            _not_send_sync: std::marker::PhantomData,
        })
    }

    /// Read a STEP file from disk.
    ///
    /// Takes `&mut self` to enforce that no shapes are borrowed while
    /// reading a new file (prevents stale shape pointers).
    pub fn read_file(&mut self, path: &Path) -> Result<(), OcctError> {
        let c_path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| OcctError::StepError("path contains null byte".to_string()))?;
        let status =
            unsafe { super::sys::mmforge_step_reader_read_file(self.ptr, c_path.as_ptr()) };
        status_to_result(status)
    }

    /// Transfer roots from the read file into OCCT shapes.
    ///
    /// Takes `&mut self` because the shim creates a fresh XDE document
    /// and rebuilds the root/label collections.  Any previously borrowed
    /// `ShapeHandle`s are invalidated.
    pub fn transfer_roots(&mut self) -> Result<(), OcctError> {
        let status = unsafe { super::sys::mmforge_step_reader_transfer_roots(self.ptr) };
        status_to_result(status)
    }

    /// Number of transferred root shapes.
    pub fn root_count(&self) -> usize {
        unsafe { super::sys::mmforge_step_reader_root_count(self.ptr) as usize }
    }

    /// Borrow a root shape by index.
    pub fn get_root(&self, index: usize) -> Result<ShapeHandle<'_>, OcctError> {
        let ptr =
            unsafe { super::sys::mmforge_step_reader_get_root(self.ptr, index as std::ffi::c_int) };
        if ptr.is_null() {
            return Err(OcctError::ShapeError(format!(
                "root shape index {index} out of bounds"
            )));
        }
        Ok(ShapeHandle {
            reader_ptr: self.ptr,
            ptr,
            _lifetime: std::marker::PhantomData,
        })
    }

    /// Collect transfer warnings.
    pub fn warnings(&self) -> Vec<String> {
        let count = unsafe { super::sys::mmforge_step_reader_warning_count(self.ptr) as usize };
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let ptr = unsafe {
                super::sys::mmforge_step_reader_get_warning(self.ptr, i as std::ffi::c_int)
            };
            if !ptr.is_null() {
                let msg = unsafe { CStr::from_ptr(ptr) }
                    .to_string_lossy()
                    .into_owned();
                out.push(msg);
            }
        }
        out
    }

    /// Raw pointer (for advanced use only).
    pub fn as_ptr(&self) -> *const super::sys::StepControlReader {
        self.ptr
    }
}

// ---------------------------------------------------------------------------
// Stub implementation (occt feature on, but OCCT not found at build time)
// ---------------------------------------------------------------------------

#[cfg(not(occt_found))]
impl StepReaderAdapter {
    pub fn new() -> Result<Self, OcctError> {
        Err(occt_not_available())
    }
    pub fn read_file(&mut self, _path: &Path) -> Result<(), OcctError> {
        Err(occt_not_available())
    }
    pub fn transfer_roots(&mut self) -> Result<(), OcctError> {
        Err(occt_not_available())
    }
    pub fn root_count(&self) -> usize {
        0
    }
    pub fn get_root(&self, _index: usize) -> Result<ShapeHandle<'_>, OcctError> {
        Err(occt_not_available())
    }
    pub fn warnings(&self) -> Vec<String> {
        Vec::new()
    }
}

// Drop is safe to implement unconditionally — freeing a null pointer is a no-op.
impl Drop for StepReaderAdapter {
    fn drop(&mut self) {
        #[cfg(occt_found)]
        if !self.ptr.is_null() {
            unsafe {
                super::sys::mmforge_step_reader_free(self.ptr);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ShapeHandle (real calls only when occt_found)
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
impl<'a> ShapeHandle<'a> {
    /// Shape type (solid, shell, face, etc.).
    pub fn shape_type(&self) -> ShapeType {
        let raw = unsafe { super::sys::mmforge_shape_type(self.reader_ptr, self.ptr) };
        occt_to_shape_type(raw)
    }

    /// Compute the axis-aligned bounding box.
    pub fn bbox(&self) -> Result<BoundingBox, OcctError> {
        let mut raw = super::sys::OcctBBox {
            min_x: 0.0,
            min_y: 0.0,
            min_z: 0.0,
            max_x: 0.0,
            max_y: 0.0,
            max_z: 0.0,
        };
        let status = unsafe { super::sys::mmforge_shape_bbox(self.reader_ptr, self.ptr, &mut raw) };
        status_to_result(status)?;
        Ok(BoundingBox::new(
            glam::Vec3::new(raw.min_x as f32, raw.min_y as f32, raw.min_z as f32),
            glam::Vec3::new(raw.max_x as f32, raw.max_y as f32, raw.max_z as f32),
        ))
    }

    /// Human-readable label (from STEP product name).
    /// Requires the owning reader — labels are stored in the XDE document.
    pub fn label(&self) -> Option<String> {
        let ptr = unsafe { super::sys::mmforge_shape_label(self.reader_ptr, self.ptr) };
        if ptr.is_null() {
            return None;
        }
        Some(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// Convert to an `OcctShapeHandle` (metadata snapshot).
    pub fn to_handle(&self, fallback_label: &str) -> Result<OcctShapeHandle, OcctError> {
        let bounds = self.bbox().unwrap_or(BoundingBox::EMPTY);
        let label = self.label().unwrap_or_else(|| fallback_label.to_string());
        Ok(OcctShapeHandle {
            label,
            bounds,
            shape_type: self.shape_type(),
        })
    }
}

// ---------------------------------------------------------------------------
// Utility functions (always available)
// ---------------------------------------------------------------------------

/// Map an `OcctStatus` to `Result<(), OcctError>`.
pub fn status_to_result(status: super::sys::OcctStatus) -> Result<(), OcctError> {
    match status {
        super::sys::OcctStatus::Ok => Ok(()),
        super::sys::OcctStatus::IoError => {
            Err(OcctError::Io(std::io::Error::other("OCCT I/O error")))
        }
        super::sys::OcctStatus::ParseError => {
            Err(OcctError::StepError("STEP parse error".to_string()))
        }
        super::sys::OcctStatus::TransferError => {
            Err(OcctError::StepError("STEP transfer error".to_string()))
        }
        super::sys::OcctStatus::NullArgument => {
            Err(OcctError::ShapeError("null pointer argument".to_string()))
        }
        super::sys::OcctStatus::InternalError => {
            Err(OcctError::ShapeError("OCCT internal error".to_string()))
        }
    }
}

// ---------------------------------------------------------------------------
// Tessellation (real calls only when occt_found)
// ---------------------------------------------------------------------------

/// Result of tessellating a B-Rep shape into a triangle mesh.
///
/// Owns the mesh data (positions, normals, indices).  The underlying
/// OCCT `MmfMesh` is freed on drop.
#[cfg(occt_found)]
pub struct TessellatedMesh {
    positions: Vec<f32>,
    normals: Vec<f32>,
    indices: Vec<i32>,
    bounds: mmforge_core::math::BoundingBox,
    mesh_ptr: *mut super::sys::MmfMesh,
}

#[cfg(occt_found)]
impl std::fmt::Debug for TessellatedMesh {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TessellatedMesh")
            .field("vertices", &(self.positions.len() / 3))
            .field("triangles", &(self.indices.len() / 3))
            .field("bounds", &self.bounds)
            .finish()
    }
}

#[cfg(occt_found)]
impl TessellatedMesh {
    /// Tessellate a shape with the given linear deflection.
    ///
    /// The shape must have been obtained from the same reader.
    pub fn tessellate(
        reader: &StepReaderAdapter,
        shape: &ShapeHandle<'_>,
        linear_deflection: f64,
    ) -> Result<Self, OcctError> {
        let mut mesh_ptr: *mut super::sys::MmfMesh = std::ptr::null_mut();
        let status = unsafe {
            super::sys::mmforge_tessellate_shape(
                reader.ptr,
                shape.ptr,
                linear_deflection,
                &mut mesh_ptr,
            )
        };
        status_to_result(status)?;

        if mesh_ptr.is_null() {
            return Err(OcctError::ShapeError(
                "tessellation returned null mesh".to_string(),
            ));
        }

        let vertex_count = unsafe { super::sys::mmforge_mesh_vertex_count(mesh_ptr) } as usize;
        let triangle_count = unsafe { super::sys::mmforge_mesh_triangle_count(mesh_ptr) } as usize;

        // Copy positions.
        let positions = {
            let src = unsafe { super::sys::mmforge_mesh_positions(mesh_ptr) };
            if src.is_null() || vertex_count == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(src, vertex_count * 3).to_vec() }
            }
        };

        // Copy normals.
        let normals = {
            let src = unsafe { super::sys::mmforge_mesh_normals(mesh_ptr) };
            if src.is_null() || vertex_count == 0 {
                vec![0.0f32; vertex_count * 3]
            } else {
                unsafe { std::slice::from_raw_parts(src, vertex_count * 3).to_vec() }
            }
        };

        // Copy indices.
        let indices = {
            let src = unsafe { super::sys::mmforge_mesh_indices(mesh_ptr) };
            if src.is_null() || triangle_count == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(src, triangle_count * 3).to_vec() }
            }
        };

        // Copy bounding box.
        let mut raw_bbox = super::sys::OcctBBox {
            min_x: 0.0,
            min_y: 0.0,
            min_z: 0.0,
            max_x: 0.0,
            max_y: 0.0,
            max_z: 0.0,
        };
        let bbox_status = unsafe { super::sys::mmforge_mesh_bbox(mesh_ptr, &mut raw_bbox) };
        let bounds = if bbox_status == super::sys::OcctStatus::Ok {
            mmforge_core::math::BoundingBox::new(
                glam::Vec3::new(
                    raw_bbox.min_x as f32,
                    raw_bbox.min_y as f32,
                    raw_bbox.min_z as f32,
                ),
                glam::Vec3::new(
                    raw_bbox.max_x as f32,
                    raw_bbox.max_y as f32,
                    raw_bbox.max_z as f32,
                ),
            )
        } else {
            mmforge_core::math::BoundingBox::EMPTY
        };

        Ok(Self {
            positions,
            normals,
            indices,
            bounds,
            mesh_ptr,
        })
    }

    pub fn positions(&self) -> &[[f32; 3]] {
        // SAFETY: positions is always a multiple of 3.
        unsafe {
            std::slice::from_raw_parts(
                self.positions.as_ptr() as *const [f32; 3],
                self.positions.len() / 3,
            )
        }
    }

    pub fn normals(&self) -> &[[f32; 3]] {
        unsafe {
            std::slice::from_raw_parts(
                self.normals.as_ptr() as *const [f32; 3],
                self.normals.len() / 3,
            )
        }
    }

    pub fn indices(&self) -> &[[i32; 3]] {
        unsafe {
            std::slice::from_raw_parts(
                self.indices.as_ptr() as *const [i32; 3],
                self.indices.len() / 3,
            )
        }
    }

    pub fn vertex_count(&self) -> usize {
        self.positions.len() / 3
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }

    pub fn bounds(&self) -> mmforge_core::math::BoundingBox {
        self.bounds
    }

    /// Tessellate using an IGES reader.  The underlying C function
    /// `mmforge_tessellate_shape` ignores the reader parameter, so we
    /// cast the IGES reader pointer to `StepControlReader*`.
    pub fn tessellate_iges(
        reader: &IgesReaderAdapter,
        shape: &IgesShapeHandle<'_>,
        linear_deflection: f64,
    ) -> Result<Self, OcctError> {
        let mut mesh_ptr: *mut super::sys::MmfMesh = std::ptr::null_mut();
        let status = unsafe {
            super::sys::mmforge_tessellate_shape(
                reader.as_step_ptr(),
                shape.ptr,
                linear_deflection,
                &mut mesh_ptr,
            )
        };
        status_to_result(status)?;

        if mesh_ptr.is_null() {
            return Err(OcctError::ShapeError(
                "tessellation returned null mesh".to_string(),
            ));
        }

        let vertex_count = unsafe { super::sys::mmforge_mesh_vertex_count(mesh_ptr) } as usize;
        let triangle_count = unsafe { super::sys::mmforge_mesh_triangle_count(mesh_ptr) } as usize;

        let positions = {
            let src = unsafe { super::sys::mmforge_mesh_positions(mesh_ptr) };
            if src.is_null() || vertex_count == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(src, vertex_count * 3).to_vec() }
            }
        };

        let normals = {
            let src = unsafe { super::sys::mmforge_mesh_normals(mesh_ptr) };
            if src.is_null() || vertex_count == 0 {
                vec![0.0f32; vertex_count * 3]
            } else {
                unsafe { std::slice::from_raw_parts(src, vertex_count * 3).to_vec() }
            }
        };

        let indices = {
            let src = unsafe { super::sys::mmforge_mesh_indices(mesh_ptr) };
            if src.is_null() || triangle_count == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(src, triangle_count * 3).to_vec() }
            }
        };

        let mut raw_bbox = super::sys::OcctBBox {
            min_x: 0.0,
            min_y: 0.0,
            min_z: 0.0,
            max_x: 0.0,
            max_y: 0.0,
            max_z: 0.0,
        };
        let bbox_status = unsafe { super::sys::mmforge_mesh_bbox(mesh_ptr, &mut raw_bbox) };
        let bounds = if bbox_status == super::sys::OcctStatus::Ok {
            mmforge_core::math::BoundingBox::new(
                glam::Vec3::new(
                    raw_bbox.min_x as f32,
                    raw_bbox.min_y as f32,
                    raw_bbox.min_z as f32,
                ),
                glam::Vec3::new(
                    raw_bbox.max_x as f32,
                    raw_bbox.max_y as f32,
                    raw_bbox.max_z as f32,
                ),
            )
        } else {
            mmforge_core::math::BoundingBox::EMPTY
        };

        Ok(Self {
            positions,
            normals,
            indices,
            bounds,
            mesh_ptr,
        })
    }
}

#[cfg(occt_found)]
impl Drop for TessellatedMesh {
    fn drop(&mut self) {
        if !self.mesh_ptr.is_null() {
            unsafe { super::sys::mmforge_mesh_free(self.mesh_ptr) };
        }
    }
}

#[cfg(occt_found)]
fn occt_to_shape_type(raw: super::sys::OcctShapeType) -> ShapeType {
    match raw {
        super::sys::OcctShapeType::Compound => ShapeType::Compound,
        super::sys::OcctShapeType::CompSolid => ShapeType::CompSolid,
        super::sys::OcctShapeType::Solid => ShapeType::Solid,
        super::sys::OcctShapeType::Shell => ShapeType::Shell,
        super::sys::OcctShapeType::Face => ShapeType::Face,
        super::sys::OcctShapeType::Wire => ShapeType::Wire,
        super::sys::OcctShapeType::Edge => ShapeType::Edge,
        super::sys::OcctShapeType::Vertex => ShapeType::Vertex,
        _ => ShapeType::Unknown,
    }
}

/// Construct the standard "OCCT not available" error.
///
/// Only compiled in stub mode (`occt_found` not set) — avoids dead-code
/// warnings when the real FFI is active.
#[cfg(not(occt_found))]
fn occt_not_available() -> OcctError {
    OcctError::NotAvailable(
        "OCCT shim not linked — set MMFORGE_SHIM_DIR to the pre-built shim \
         library, with OCCT_INCLUDE_DIR + OCCT_LIB_DIR for OCCT headers/libs"
            .to_string(),
    )
}

/// Get the OCCT version string.
#[cfg(occt_found)]
pub fn occt_version() -> Option<String> {
    let ptr = unsafe { super::sys::mmforge_occt_version() };
    if ptr.is_null() {
        return None;
    }
    Some(
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_to_result_ok() {
        assert!(status_to_result(super::super::sys::OcctStatus::Ok).is_ok());
    }

    #[test]
    fn status_to_result_errors() {
        assert!(status_to_result(super::super::sys::OcctStatus::IoError).is_err());
        assert!(status_to_result(super::super::sys::OcctStatus::ParseError).is_err());
        assert!(status_to_result(super::super::sys::OcctStatus::TransferError).is_err());
        assert!(status_to_result(super::super::sys::OcctStatus::NullArgument).is_err());
        assert!(status_to_result(super::super::sys::OcctStatus::InternalError).is_err());
    }

    /// Only meaningful when the real shim is NOT linked — verifies the
    /// stub path returns `NotAvailable`.
    #[cfg(not(occt_found))]
    #[test]
    fn stub_new_returns_not_available() {
        let result = StepReaderAdapter::new();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("OCCT") || msg.contains("shim"));
    }

    /// Link-verification probe: only compiles when `occt_found` is set.
    ///
    /// This test takes the address of **every** `extern "C"` function
    /// declared in `sys.rs`.  If the shim library was not actually linked
    /// (e.g. build.rs set `occt_found` incorrectly), this test will fail
    /// to **link** — producing a loud, unmissable build error rather than
    /// a silent runtime failure.
    ///
    /// The addresses are collected into a `Vec` and asserted non-zero to
    /// prevent the compiler from optimising away the references.  We do
    /// **not** call the functions (many require initialised OCCT objects).
    ///
    /// **Maintenance**: when adding a new `extern "C"` to `sys.rs`, add
    /// its address here **and** to `REQUIRED_SHIM_SYMBOLS` in `build.rs`.
    #[cfg(occt_found)]
    #[test]
    fn link_probe_references_all_shim_symbols() {
        let _lock = crate::occt::OCCT_TEST_MUTEX
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        // Collect the address of every extern "C" symbol.
        // Uses full crate::occt::sys:: paths — no intermediate variable
        // (modules are not values in Rust).
        let addrs: Vec<usize> = vec![
            // C ABI version
            crate::occt::sys::mmforge_abi_version as *const () as usize,
            // STEPControl_Reader
            crate::occt::sys::mmforge_step_reader_new as *const () as usize,
            crate::occt::sys::mmforge_step_reader_read_file as *const () as usize,
            crate::occt::sys::mmforge_step_reader_transfer_roots as *const () as usize,
            crate::occt::sys::mmforge_step_reader_root_count as *const () as usize,
            crate::occt::sys::mmforge_step_reader_get_root as *const () as usize,
            crate::occt::sys::mmforge_step_reader_warning_count as *const () as usize,
            crate::occt::sys::mmforge_step_reader_get_warning as *const () as usize,
            crate::occt::sys::mmforge_step_reader_free as *const () as usize,
            // IGESControl_Reader
            crate::occt::sys::mmforge_iges_reader_new as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_read_file as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_transfer_roots as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_root_count as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_get_root as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_warning_count as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_get_warning as *const () as usize,
            crate::occt::sys::mmforge_iges_reader_free as *const () as usize,
            crate::occt::sys::mmforge_iges_shape_type as *const () as usize,
            crate::occt::sys::mmforge_iges_shape_bbox as *const () as usize,
            crate::occt::sys::mmforge_iges_shape_label as *const () as usize,
            // TopoDS_Shape
            crate::occt::sys::mmforge_shape_type as *const () as usize,
            crate::occt::sys::mmforge_shape_bbox as *const () as usize,
            crate::occt::sys::mmforge_shape_label as *const () as usize,
            crate::occt::sys::mmforge_shape_free as *const () as usize,
            // Tessellation
            crate::occt::sys::mmforge_tessellate_shape as *const () as usize,
            crate::occt::sys::mmforge_mesh_vertex_count as *const () as usize,
            crate::occt::sys::mmforge_mesh_triangle_count as *const () as usize,
            crate::occt::sys::mmforge_mesh_positions as *const () as usize,
            crate::occt::sys::mmforge_mesh_normals as *const () as usize,
            crate::occt::sys::mmforge_mesh_indices as *const () as usize,
            crate::occt::sys::mmforge_mesh_bbox as *const () as usize,
            crate::occt::sys::mmforge_mesh_free as *const () as usize,
            // Version
            crate::occt::sys::mmforge_occt_version as *const () as usize,
        ];

        // Every symbol must resolve to a non-null address.
        for (i, &addr) in addrs.iter().enumerate() {
            assert_ne!(
                addr, 0,
                "extern symbol at index {i} resolved to null — \
                 shim may be incomplete"
            );
        }

        // Verify the version string is actually callable.
        let ptr = unsafe { crate::occt::sys::mmforge_occt_version() };
        assert!(!ptr.is_null(), "mmforge_occt_version returned null");
        let version = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_string_lossy();
        assert!(
            !version.is_empty(),
            "OCCT version string is empty — shim may be misconfigured"
        );
    }

    /// E2E tessellation test: STEP fixture → read → tessellate → verify mesh.
    #[cfg(occt_found)]
    #[test]
    fn tessellate_step_fixture() {
        let _lock = crate::occt::OCCT_TEST_MUTEX
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("PQ-04909-A.STEP");

        assert!(
            fixture.exists(),
            "STEP fixture missing at {}",
            fixture.display()
        );

        let mut reader = StepReaderAdapter::new().expect("new reader");
        reader.read_file(&fixture).expect("read_file");
        reader.transfer_roots().expect("transfer_roots");

        let count = reader.root_count();
        assert!(count > 0, "expected at least one root shape");

        for i in 0..count {
            let shape = reader.get_root(i).expect("get_root");
            let shape_bounds = shape.bbox().expect("bbox");

            // Tessellate with standard quality.
            let quality = crate::tessellation::TessellationQuality::Standard;
            let deflection = quality.linear_deflection(&shape_bounds) as f64;

            let mesh =
                TessellatedMesh::tessellate(&reader, &shape, deflection).expect("tessellate");

            // Verify mesh has vertices and triangles.
            assert!(mesh.vertex_count() > 0, "mesh has no vertices");
            assert!(mesh.triangle_count() > 0, "mesh has no triangles");

            // Verify bounds are valid.
            let mesh_bounds = mesh.bounds();
            assert!(mesh_bounds.is_valid(), "mesh bounds invalid");

            // Verify positions are finite.
            for pos in mesh.positions() {
                assert!(
                    pos[0].is_finite() && pos[1].is_finite() && pos[2].is_finite(),
                    "non-finite position: {pos:?}"
                );
            }

            // Verify normals are non-zero.
            for norm in mesh.normals() {
                let len = (norm[0] * norm[0] + norm[1] * norm[1] + norm[2] * norm[2]).sqrt();
                assert!(len > 0.001, "zero-length normal: {norm:?}");
            }

            // Verify indices are in range.
            let vc = mesh.vertex_count() as i32;
            for tri in mesh.indices() {
                assert!(tri[0] >= 0 && tri[0] < vc, "index out of range: {:?}", tri);
                assert!(tri[1] >= 0 && tri[1] < vc, "index out of range: {:?}", tri);
                assert!(tri[2] >= 0 && tri[2] < vc, "index out of range: {:?}", tri);
            }

            eprintln!(
                "tessellate[{i}]: {} vertices, {} triangles, bounds={:?}",
                mesh.vertex_count(),
                mesh.triangle_count(),
                mesh_bounds,
            );
        }
    }
}
