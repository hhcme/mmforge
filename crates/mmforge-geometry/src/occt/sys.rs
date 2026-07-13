//! Raw C ABI bindings for OpenCASCADE (OCCT).
//!
//! This module contains `extern "C"` function declarations that call into
//! the C++ OCCT library through a thin C shim layer.  The declarations
//! match the functions exported by `mmforge_occt_shim.c` (compiled by
//! `build.rs` when the `occt` feature is enabled and OCCT is found).
//!
//! # Safety
//!
//! All functions in this module are `unsafe`.  Raw pointers returned by
//! OCCT must be freed via the corresponding `_free` functions.  Calling
//! any function with a null or dangling pointer is undefined behavior.
//!
//! # Stub mode
//!
//! When the `occt` feature is disabled (or OCCT is not found at build
//! time), the shim library is not linked and these declarations are
//! dead code.  The `adapter` module checks `cfg(feature = "occt")`
//! before calling into this module.

// Opaque handle types.  These mirror the C++ classes but expose no
// internals to Rust.  The shim allocates them on the C++ heap.

/// Opaque handle to a `STEPControl_Reader` instance.
#[repr(C)]
pub struct StepControlReader {
    _private: [u8; 0],
}

/// Opaque handle to an `IGESControl_Reader` instance.
#[repr(C)]
pub struct IgesControlReader {
    _private: [u8; 0],
}

/// Opaque handle to a `TopoDS_Shape` instance.
#[repr(C)]
pub struct TopoDsShape {
    _private: [u8; 0],
}

/// Opaque handle to a shape iterator.
#[repr(C)]
pub struct ShapeIterator {
    _private: [u8; 0],
}

/// XDE assembly tree node (matches MmfTreeNode in the C header).
/// All pointers are borrowed from the reader and valid until reader free.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct MmfTreeNode {
    pub parent_index: std::ffi::c_int,
    pub name: *const std::ffi::c_char,
    pub shape_type: OcctShapeType,
    pub bbox: OcctBBox,
    pub is_assembly: std::ffi::c_int,
    pub shape: *const TopoDsShape,
    pub location: [std::ffi::c_double; 16],
}

/// Error codes returned by the C shim.
///
/// These map 1-to-1 to the `MmfOcctError` enum in the shim header.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OcctStatus {
    /// Operation succeeded.
    Ok = 0,
    /// File I/O error (not found, permission denied, etc.).
    IoError = 1,
    /// STEP parsing failed (malformed file, unsupported entities, etc.).
    ParseError = 2,
    /// Transfer from STEP to OCCT shape failed.
    TransferError = 3,
    /// Null pointer argument.
    NullArgument = 4,
    /// Internal OCCT error (should not happen in normal use).
    InternalError = 5,
}

impl OcctStatus {
    pub fn is_ok(self) -> bool {
        self == Self::Ok
    }
}

/// Bounding box result returned by shape queries.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OcctBBox {
    pub min_x: f64,
    pub min_y: f64,
    pub min_z: f64,
    pub max_x: f64,
    pub max_y: f64,
    pub max_z: f64,
}

/// Shape type enumeration matching OCCT `TopAbs_ShapeEnum`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OcctShapeType {
    Compound = 0,
    CompSolid = 1,
    Solid = 2,
    Shell = 3,
    Face = 4,
    Wire = 5,
    Edge = 6,
    Vertex = 7,
    Unknown = 8,
}

// ---------------------------------------------------------------------------
// C ABI version
// ---------------------------------------------------------------------------

// Return the C ABI version of the linked shim library.
// Checked at runtime to catch stale shims that passed nm validation
// but have incompatible function signatures.
#[cfg(occt_found)]
unsafe extern "C" {
    pub fn mmforge_abi_version() -> std::ffi::c_int;
}

// ---------------------------------------------------------------------------
// STEPControl_Reader functions
// ---------------------------------------------------------------------------

// The extern "C" block is only compiled when OCCT was actually found at
// build time (build.rs sets `occt_found`).  Without this gate, the linker
// would fail because the shim library is not linked.
#[cfg(occt_found)]
unsafe extern "C" {
    /// Create a new `STEPControl_Reader`.  Returns null on allocation failure.
    pub fn mmforge_step_reader_new() -> *mut StepControlReader;

    /// Read a STEP file.  The path must be a null-terminated UTF-8 string.
    /// Returns a status code.  On success, the reader holds internal data.
    pub fn mmforge_step_reader_read_file(
        reader: *mut StepControlReader,
        path: *const std::ffi::c_char,
    ) -> OcctStatus;

    /// Transfer roots from the read file into OCCT shapes.
    /// Must be called after `read_file`.  Returns a status code.
    pub fn mmforge_step_reader_transfer_roots(reader: *mut StepControlReader) -> OcctStatus;

    /// Get the number of transferred root shapes.
    /// Must be called after `transfer_roots`.
    pub fn mmforge_step_reader_root_count(reader: *const StepControlReader) -> std::ffi::c_int;

    /// Get a root shape by index.  Returns a borrowed pointer — the shape
    /// is owned by the reader and must NOT be freed by the caller.
    /// Returns null if index is out of bounds.
    pub fn mmforge_step_reader_get_root(
        reader: *const StepControlReader,
        index: std::ffi::c_int,
    ) -> *const TopoDsShape;

    /// Get transfer warning count.
    pub fn mmforge_step_reader_warning_count(reader: *const StepControlReader) -> std::ffi::c_int;

    /// Get transfer warning message by index.  Returns a borrowed
    /// null-terminated string.  Returns null if index is out of bounds.
    pub fn mmforge_step_reader_get_warning(
        reader: *const StepControlReader,
        index: std::ffi::c_int,
    ) -> *const std::ffi::c_char;

    /// Free a `STEPControl_Reader` and all associated resources.
    /// Passing null is a no-op.
    pub fn mmforge_step_reader_free(reader: *mut StepControlReader);
}

// ---------------------------------------------------------------------------
// IGESControl_Reader functions
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
unsafe extern "C" {
    pub fn mmforge_iges_reader_new() -> *mut IgesControlReader;

    pub fn mmforge_iges_reader_read_file(
        reader: *mut IgesControlReader,
        path: *const std::ffi::c_char,
    ) -> OcctStatus;

    pub fn mmforge_iges_reader_transfer_roots(reader: *mut IgesControlReader) -> OcctStatus;

    pub fn mmforge_iges_reader_root_count(reader: *const IgesControlReader) -> std::ffi::c_int;

    pub fn mmforge_iges_reader_get_root(
        reader: *const IgesControlReader,
        index: std::ffi::c_int,
    ) -> *const TopoDsShape;

    pub fn mmforge_iges_reader_warning_count(reader: *const IgesControlReader) -> std::ffi::c_int;

    pub fn mmforge_iges_reader_get_warning(
        reader: *const IgesControlReader,
        index: std::ffi::c_int,
    ) -> *const std::ffi::c_char;

    pub fn mmforge_iges_reader_free(reader: *mut IgesControlReader);
}

// ---------------------------------------------------------------------------
// XDE Assembly Tree Enumeration
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
unsafe extern "C" {
    /// Number of nodes in the XDE assembly tree (STEP).
    pub fn mmforge_shape_tree_node_count(reader: *const StepControlReader) -> std::ffi::c_int;

    /// Get tree node by index (STEP).  Returns null if out of bounds.
    pub fn mmforge_shape_get_tree_node(
        reader: *const StepControlReader,
        index: std::ffi::c_int,
    ) -> *const MmfTreeNode;

    /// Number of nodes in the XDE assembly tree (IGES).
    pub fn mmforge_iges_shape_tree_node_count(reader: *const IgesControlReader) -> std::ffi::c_int;

    /// Get tree node by index (IGES).  Returns null if out of bounds.
    pub fn mmforge_iges_shape_get_tree_node(
        reader: *const IgesControlReader,
        index: std::ffi::c_int,
    ) -> *const MmfTreeNode;
}

// ---------------------------------------------------------------------------
// IGES shape functions (same logic as STEP, different reader type)
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
unsafe extern "C" {
    pub fn mmforge_iges_shape_type(
        reader: *const IgesControlReader,
        shape: *const TopoDsShape,
    ) -> OcctShapeType;

    pub fn mmforge_iges_shape_bbox(
        reader: *const IgesControlReader,
        shape: *const TopoDsShape,
        out_bbox: *mut OcctBBox,
    ) -> OcctStatus;

    pub fn mmforge_iges_shape_label(
        reader: *const IgesControlReader,
        shape: *const TopoDsShape,
    ) -> *const std::ffi::c_char;
}

// ---------------------------------------------------------------------------
// TopoDS_Shape functions
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
unsafe extern "C" {
    /// Get the shape type (solid, shell, face, etc.).
    /// Requires the owning reader for context (future use).
    pub fn mmforge_shape_type(
        reader: *const StepControlReader,
        shape: *const TopoDsShape,
    ) -> OcctShapeType;

    /// Compute the axis-aligned bounding box.
    /// Requires the owning reader for context (future use).
    /// Returns a status code.  On success, fills `out_bbox`.
    pub fn mmforge_shape_bbox(
        reader: *const StepControlReader,
        shape: *const TopoDsShape,
        out_bbox: *mut OcctBBox,
    ) -> OcctStatus;

    /// Get a human-readable label for the shape (from STEP product name).
    /// Requires the owning reader — labels are stored in the XDE document.
    /// Returns a borrowed null-terminated string, or null if unavailable.
    /// The string is valid until `mmforge_step_reader_free()` is called.
    pub fn mmforge_shape_label(
        reader: *const StepControlReader,
        shape: *const TopoDsShape,
    ) -> *const std::ffi::c_char;

    /// Free a `TopoDS_Shape` that was allocated by the shim.
    /// Most shapes are owned by the reader and should NOT be freed.
    /// Only shapes explicitly copied (future use) need freeing.
    /// Passing null is a no-op.
    pub fn mmforge_shape_free(shape: *mut TopoDsShape);
}

// ---------------------------------------------------------------------------
// Tessellation functions
// ---------------------------------------------------------------------------

/// Opaque handle to a tessellated mesh (owned by the shim).
#[repr(C)]
pub struct MmfMesh {
    _private: [u8; 0],
}

#[cfg(occt_found)]
unsafe extern "C" {
    /// Tessellate a shape using BRepMesh_IncrementalMesh.
    /// Returns a mesh handle on success.  The mesh owns its buffers.
    pub fn mmforge_tessellate_shape(
        reader: *const StepControlReader,
        shape: *const TopoDsShape,
        linear_deflection: std::ffi::c_double,
        out_mesh: *mut *mut MmfMesh,
    ) -> OcctStatus;

    /// Number of vertices in the mesh.
    pub fn mmforge_mesh_vertex_count(mesh: *const MmfMesh) -> std::ffi::c_int;

    /// Number of triangles in the mesh.
    pub fn mmforge_mesh_triangle_count(mesh: *const MmfMesh) -> std::ffi::c_int;

    /// Vertex positions as flat float array [x0,y0,z0, ...].
    /// Returns pointer to internal buffer (valid until mesh is freed).
    pub fn mmforge_mesh_positions(mesh: *const MmfMesh) -> *const std::ffi::c_float;

    /// Vertex normals as flat float array [nx0,ny0,nz0, ...].
    pub fn mmforge_mesh_normals(mesh: *const MmfMesh) -> *const std::ffi::c_float;

    /// Triangle indices as flat int array [i0,i1,i2, ...].
    pub fn mmforge_mesh_indices(mesh: *const MmfMesh) -> *const std::ffi::c_int;

    /// Axis-aligned bounding box of the tessellated mesh.
    pub fn mmforge_mesh_bbox(mesh: *const MmfMesh, out_bbox: *mut OcctBBox) -> OcctStatus;

    /// Free a mesh.  Passing null is a no-op.
    pub fn mmforge_mesh_free(mesh: *mut MmfMesh);
}

// ---------------------------------------------------------------------------
// Version / build info
// ---------------------------------------------------------------------------

#[cfg(occt_found)]
unsafe extern "C" {
    /// Get the OCCT version string (e.g. "7.8.0").
    /// Returns a borrowed null-terminated string.
    pub fn mmforge_occt_version() -> *const std::ffi::c_char;
}
