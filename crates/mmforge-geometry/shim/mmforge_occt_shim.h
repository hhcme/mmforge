/*
 * mmforge_occt_shim.h — C ABI for OpenCASCADE bridge
 *
 * This header declares the public interface of libmmforge_occt_shim.a.
 * All types are repr(C)-compatible and match the Rust declarations in
 * mmforge-geometry/src/occt/sys.rs exactly.
 *
 * OCCT API contract (STEPCAFControl_Reader):
 *   1. mmforge_step_reader_new()                     — allocates reader + XDE doc
 *   2. mmforge_step_reader_read_file(reader, path)   — ReadFile()
 *   3. mmforge_step_reader_transfer_roots(reader)    — Transfer(doc)
 *   4. mmforge_step_reader_get_root(reader, i)       — borrowed from roots vector
 *   5. mmforge_shape_*(reader, shape)                 — queries scoped to reader
 *   6. mmforge_step_reader_free(reader)              — frees everything
 *
 * Shape pointers are borrowed from the reader and must NOT outlive it.
 *
 * Build: see CMakeLists.txt in this directory.
 */

#ifndef MMFORGE_OCCT_SHIM_H
#define MMFORGE_OCCT_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/* ------------------------------------------------------------------ */
/*  C ABI version                                                      */
/*                                                                     */
/*  Bumped on every ABI-incompatible change.  The Rust side checks     */
/*  this at runtime to prevent linking against a stale shim that       */
/*  passed nm symbol-name validation but has incompatible signatures.  */
/* ------------------------------------------------------------------ */

/** Current C ABI version.  Bump when function signatures change. */
#define MMFORGE_SHIM_ABI_VERSION 2

/* ------------------------------------------------------------------ */
/*  Opaque handle types                                                */
/* ------------------------------------------------------------------ */

/** Opaque handle to a STEP reader session (wraps STEPCAFControl_Reader
    + XCAF document). */
typedef struct MmfStepReader MmfStepReader;

/** Opaque handle to a TopoDS_Shape (borrowed from the reader). */
typedef struct MmfShape MmfShape;

/* ------------------------------------------------------------------ */
/*  Status / result codes                                              */
/* ------------------------------------------------------------------ */

/**
 * Error codes returned by the C shim.
 * Matches `OcctStatus` in sys.rs (repr(C), same discriminant values).
 */
typedef enum {
    MMF_OK              = 0,
    MMF_IO_ERROR        = 1,
    MMF_PARSE_ERROR     = 2,
    MMF_TRANSFER_ERROR  = 3,
    MMF_NULL_ARGUMENT   = 4,
    MMF_INTERNAL_ERROR  = 5
} MmfOcctError;

/* ------------------------------------------------------------------ */
/*  Geometric data                                                     */
/* ------------------------------------------------------------------ */

/**
 * Axis-aligned bounding box.
 * Matches `OcctBBox` in sys.rs (repr(C), 6 × f64).
 */
typedef struct {
    double min_x, min_y, min_z;
    double max_x, max_y, max_z;
} MmfOcctBBox;

/**
 * Shape type enumeration.
 * Matches `OcctShapeType` in sys.rs (repr(C), same discriminant values).
 * Maps 1-to-1 to OCCT TopAbs_ShapeEnum.
 */
typedef enum {
    MMF_COMPOUND   = 0,
    MMF_COMPSOLID  = 1,
    MMF_SOLID      = 2,
    MMF_SHELL      = 3,
    MMF_FACE       = 4,
    MMF_WIRE       = 5,
    MMF_EDGE       = 6,
    MMF_VERTEX     = 7,
    MMF_UNKNOWN    = 8
} MmfOcctShapeType;

/* ------------------------------------------------------------------ */
/*  C ABI version check                                                */
/* ------------------------------------------------------------------ */

/**
 * Return the C ABI version of this shim library.
 * The Rust side calls this at runtime and asserts the value matches
 * MMFORGE_SHIM_ABI_VERSION.  This catches stale shims that passed
 * nm symbol-name validation but have incompatible function signatures.
 */
int mmforge_abi_version(void);

/* ------------------------------------------------------------------ */
/*  STEP reader functions                                              */
/* ------------------------------------------------------------------ */

/**
 * Create a new reader session.
 * Internally allocates STEPCAFControl_Reader and TDocStd_Document.
 * Returns NULL on allocation failure.
 */
MmfStepReader* mmforge_step_reader_new(void);

/**
 * Read a STEP file via STEPCAFControl_Reader::ReadFile().
 * @param reader  Valid reader from mmforge_step_reader_new().
 * @param path    Null-terminated UTF-8 file path.
 * @return MMF_OK on success.
 */
MmfOcctError mmforge_step_reader_read_file(MmfStepReader* reader,
                                           const char* path);

/**
 * Transfer all roots via STEPCAFControl_Reader::Transfer(doc).
 * Clears any previous roots/warnings/labels before transferring.
 * On success, populates root shapes, warnings, and label map.
 * @return MMF_OK on success.
 */
MmfOcctError mmforge_step_reader_transfer_roots(MmfStepReader* reader);

/**
 * Get the number of transferred root shapes.
 */
int mmforge_step_reader_root_count(const MmfStepReader* reader);

/**
 * Get a root shape by index.
 * Returns a borrowed pointer — owned by the reader, must NOT be freed.
 * Returns NULL if index is out of bounds.
 */
const MmfShape* mmforge_step_reader_get_root(const MmfStepReader* reader,
                                             int index);

/**
 * Get the number of transfer warnings.
 */
int mmforge_step_reader_warning_count(const MmfStepReader* reader);

/**
 * Get a transfer warning message by index.
 * Returns a borrowed null-terminated string, or NULL if out of bounds.
 */
const char* mmforge_step_reader_get_warning(const MmfStepReader* reader,
                                            int index);

/**
 * Free a reader and all associated resources.
 * Passing NULL is a no-op.
 */
void mmforge_step_reader_free(MmfStepReader* reader);

/* ------------------------------------------------------------------ */
/*  Shape functions (require owning reader for context)                */
/* ------------------------------------------------------------------ */

MmfOcctShapeType mmforge_shape_type(const MmfStepReader* reader,
                                    const MmfShape* shape);

MmfOcctError mmforge_shape_bbox(const MmfStepReader* reader,
                                const MmfShape* shape,
                                MmfOcctBBox* out_bbox);

/**
 * Get label from STEP product name.  Requires the owning reader.
 * Valid until mmforge_step_reader_free() is called.
 */
const char* mmforge_shape_label(const MmfStepReader* reader,
                                const MmfShape* shape);

void mmforge_shape_free(MmfShape* shape);

/* ------------------------------------------------------------------ */
/*  Tessellation                                                       */
/* ------------------------------------------------------------------ */

/** Opaque handle to a tessellated mesh. */
typedef struct MmfMesh MmfMesh;

/**
 * Tessellate a shape using BRepMesh_IncrementalMesh.
 * @param reader       Owning reader (for context).
 * @param shape        Borrowed shape pointer.
 * @param linear_deflection  Linear deflection for tessellation quality.
 * @param out_mesh     Set to the resulting mesh on success.
 * @return MMF_OK on success.
 */
MmfOcctError mmforge_tessellate_shape(
    const MmfStepReader* reader,
    const MmfShape* shape,
    double linear_deflection,
    MmfMesh** out_mesh);

/** Number of vertices in the mesh. */
int mmforge_mesh_vertex_count(const MmfMesh* mesh);

/** Number of triangles in the mesh. */
int mmforge_mesh_triangle_count(const MmfMesh* mesh);

/**
 * Vertex positions as flat float array [x0,y0,z0, x1,y1,z1, ...].
 * Returns pointer to internal buffer (valid until mesh is freed).
 * Returns NULL if mesh is NULL.
 */
const float* mmforge_mesh_positions(const MmfMesh* mesh);

/**
 * Vertex normals as flat float array [nx0,ny0,nz0, ...].
 * Returns pointer to internal buffer.  Returns NULL if mesh is NULL.
 */
const float* mmforge_mesh_normals(const MmfMesh* mesh);

/**
 * Triangle indices as flat int array [i0,i1,i2, ...].
 * Returns pointer to internal buffer.  Returns NULL if mesh is NULL.
 */
const int* mmforge_mesh_indices(const MmfMesh* mesh);

/**
 * Axis-aligned bounding box of the tessellated mesh.
 * @return MMF_OK on success.
 */
MmfOcctError mmforge_mesh_bbox(const MmfMesh* mesh, MmfOcctBBox* out_bbox);

/** Free a mesh.  Passing NULL is a no-op. */
void mmforge_mesh_free(MmfMesh* mesh);

/* ------------------------------------------------------------------ */
/*  Version / build info                                               */
/* ------------------------------------------------------------------ */

/**
 * Get the OCCT version string (e.g. "7.8.0").
 * Returns a pointer to a static null-terminated string.
 */
const char* mmforge_occt_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MMFORGE_OCCT_SHIM_H */
