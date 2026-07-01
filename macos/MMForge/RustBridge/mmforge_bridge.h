/*
 * mmforge_bridge.h — C ABI bridge for MMForge macOS app
 *
 * Declares the Rust functions that Swift calls via the bridging header.
 * All functions are implemented in crates/mmforge-bridge/src/lib.rs.
 */

#ifndef MMFORGE_BRIDGE_H
#define MMFORGE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to a parsed document (owns RenderPacket + LsmModel). */
typedef struct MmfDocument MmfDocument;

/** Get the last error message.  Returns NULL if no error. */
const char* mmf_last_error(void);

/** Get the library version string. */
const char* mmf_version(void);

/* ------------------------------------------------------------------ */
/*  Document lifecycle                                                 */
/* ------------------------------------------------------------------ */

/**
 * Parse a STEP file and build the render packet.
 * Returns NULL on error — call mmf_last_error() for the message.
 * The returned handle must be freed with mmf_document_free().
 */
MmfDocument* mmf_parse_step(const char* path);

/**
 * Parse a file with auto-detection (STL, glTF/GLB, STEP).
 * Returns NULL on error — call mmf_last_error() for the message.
 * The returned handle must be freed with mmf_document_free().
 */
MmfDocument* mmf_parse_file(const char* path);

/** Free a document.  Passing NULL is a no-op. */
void mmf_document_free(MmfDocument* doc);

/* ------------------------------------------------------------------ */
/*  Mesh data (borrowed pointers — valid until mmf_document_free)      */
/* ------------------------------------------------------------------ */

/** Number of meshes in the render packet. */
uint32_t mmf_mesh_count(const MmfDocument* doc);

/** Number of vertices in mesh at index. */
uint32_t mmf_mesh_vertex_count(const MmfDocument* doc, uint32_t index);

/** Number of indices in mesh at index. */
uint32_t mmf_mesh_index_count(const MmfDocument* doc, uint32_t index);

/** GeometryId for a mesh at the given index.  Returns -1 if out of range. */
int32_t mmf_mesh_geometry_id(const MmfDocument* doc, uint32_t index);

/**
 * Vertex positions as flat float array [x0,y0,z0, x1,y1,z1, ...].
 * Returns NULL if index is out of range.  Length = vertex_count * 3.
 */
const float* mmf_mesh_positions(const MmfDocument* doc, uint32_t index);

/**
 * Vertex normals as flat float array [nx0,ny0,nz0, ...].
 * Returns NULL if index is out of range.  Length = vertex_count * 3.
 */
const float* mmf_mesh_normals(const MmfDocument* doc, uint32_t index);

/**
 * Triangle indices as flat uint32 array [i0,i1,i2, ...].
 * Returns NULL if index is out of range.  Length = index_count.
 */
const uint32_t* mmf_mesh_indices(const MmfDocument* doc, uint32_t index);

/* ------------------------------------------------------------------ */
/*  Scene bounds                                                       */
/* ------------------------------------------------------------------ */

/**
 * Get the scene bounding box.
 * @param out_min  [3] float array filled with (x,y,z) min corner.
 * @param out_max  [3] float array filled with (x,y,z) max corner.
 */
void mmf_scene_bounds(const MmfDocument* doc, float* out_min, float* out_max);

/* ------------------------------------------------------------------ */
/*  Scene tree                                                         */
/* ------------------------------------------------------------------ */

/** Number of nodes in the scene tree. */
uint32_t mmf_node_count(const MmfDocument* doc);

/** Name of node at index.  Returns NULL if out of range. */
const char* mmf_node_name(const MmfDocument* doc, uint32_t index);

/** Parent node index.  Returns -1 for root nodes or if index is invalid. */
int32_t mmf_node_parent(const MmfDocument* doc, uint32_t index);

/** Whether the node at index has associated geometry. */
int mmf_node_has_geometry(const MmfDocument* doc, uint32_t index);

/** GeometryId for a node.  Returns -1 if no geometry or invalid index. */
int32_t mmf_node_geometry_id(const MmfDocument* doc, uint32_t index);

/**
 * Get the mesh index in the RenderPacket for a given node.
 * Returns -1 if the node has no geometry or index is invalid.
 * The mapping is: node → geometry_id → mesh index (sorted by GeometryId).
 */
int32_t mmf_node_mesh_index(const MmfDocument* doc, uint32_t index);

/**
 * Get the bounding box of a node.
 * @return 1 on success, 0 if index invalid or bounds empty.
 */
int mmf_node_bounds(const MmfDocument* doc, uint32_t index,
                    float* out_min, float* out_max);

/**
 * Get the geometry label for a node (e.g. "PQ-04909-A [Solid]").
 * Returns NULL if the node has no geometry.
 */
const char* mmf_node_geometry_label(const MmfDocument* doc, uint32_t index);

/* ------------------------------------------------------------------ */
/*  Render stats                                                       */
/* ------------------------------------------------------------------ */

/** Total triangle count across all meshes. */
uint32_t mmf_triangle_count(const MmfDocument* doc);

/** Number of materials. */
uint32_t mmf_material_count(const MmfDocument* doc);

/** Number of geometries in the model. */
uint32_t mmf_geometry_count(const MmfDocument* doc);

/* ------------------------------------------------------------------ */
/*  2D Drawing data                                                    */
/* ------------------------------------------------------------------ */

/** Check if the document contains a 2D drawing.  Returns 1 if yes. */
int mmf_is_2d_drawing(const MmfDocument* doc);

/** Number of 2D drawing entities.  Returns 0 if not a 2D drawing. */
uint32_t mmf_drawing_entity_count(const MmfDocument* doc);

/** Number of layers in the 2D drawing. */
uint32_t mmf_drawing_layer_count(const MmfDocument* doc);

/**
 * Get the 2D drawing bounding box.
 * @return 1 on success, 0 if not a 2D drawing.
 */
int mmf_drawing_bounds(const MmfDocument* doc,
                       double* out_min_x, double* out_min_y,
                       double* out_max_x, double* out_max_y);

/** Get layer name by index.  Returns NULL if out of range. */
const char* mmf_drawing_layer_name(const MmfDocument* doc, uint32_t index);

/** Check if layer is visible by index.  Returns 1 if visible. */
int mmf_drawing_layer_visible(const MmfDocument* doc, uint32_t index);

/* ------------------------------------------------------------------ */
/*  Draw command accessors (flat list across all layers)               */
/* ------------------------------------------------------------------ */

/** Total draw commands. */
uint32_t mmf_draw_cmd_count(const MmfDocument* doc);

/** Command type: 0=Line, 1=Circle, 2=Arc, 3=Polyline, 4=Text, -1=invalid. */
int32_t mmf_draw_cmd_type(const MmfDocument* doc, uint32_t index);

/** Layer index for a draw command.  -1 if invalid. */
int32_t mmf_draw_cmd_layer_index(const MmfDocument* doc, uint32_t index);

/** Layer name for a draw command.  NULL if invalid. */
const char* mmf_draw_cmd_layer_name(const MmfDocument* doc, uint32_t index);

/** Layer ACI color index for a draw command. */
int16_t mmf_draw_cmd_color_index(const MmfDocument* doc, uint32_t index);

/** Layer visibility for a draw command.  1=visible. */
int mmf_draw_cmd_layer_visible(const MmfDocument* doc, uint32_t index);

/** Read LINE data.  Returns 1 on success. */
int mmf_draw_cmd_line(const MmfDocument* doc, uint32_t index,
                      double* out_x0, double* out_y0,
                      double* out_x1, double* out_y1);

/** Read CIRCLE data.  Returns 1 on success. */
int mmf_draw_cmd_circle(const MmfDocument* doc, uint32_t index,
                        double* out_cx, double* out_cy, double* out_r);

/** Read ARC data.  Angles in radians.  Returns 1 on success. */
int mmf_draw_cmd_arc(const MmfDocument* doc, uint32_t index,
                     double* out_cx, double* out_cy, double* out_r,
                     double* out_start, double* out_end);

/** Polyline point count.  0 if not a polyline. */
uint32_t mmf_draw_cmd_polyline_count(const MmfDocument* doc, uint32_t index);

/** Read polyline point.  Returns 1 on success. */
int mmf_draw_cmd_polyline_point(const MmfDocument* doc,
                                uint32_t cmd_index, uint32_t point_index,
                                double* out_x, double* out_y);

/** Polyline closed flag.  1=closed. */
int mmf_draw_cmd_polyline_closed(const MmfDocument* doc, uint32_t index);

/** Read TEXT data.  Returns content string (borrowed), NULL if not text. */
const char* mmf_draw_cmd_text(const MmfDocument* doc, uint32_t index,
                              double* out_x, double* out_y,
                              double* out_height, double* out_rotation);

#ifdef __cplusplus
}
#endif

#endif /* MMFORGE_BRIDGE_H */
