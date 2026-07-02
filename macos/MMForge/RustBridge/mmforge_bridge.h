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

/**
 * Render statistics.  All outputs are optional (pass NULL to skip).
 */
void mmf_render_stats(const MmfDocument* doc,
                      uint32_t* out_mesh_count,
                      uint32_t* out_vertex_count,
                      uint32_t* out_triangle_count,
                      uint64_t* out_memory_bytes,
                      double*   out_build_ms);

/* ------------------------------------------------------------------ */
/*  Background parsing / progress / cancellation                       */
/* ------------------------------------------------------------------ */

/** Opaque handle to a background open job. */
typedef struct OpenDocumentJob OpenDocumentJob;

/** Create a new cancellation token. */
void* mmf_cancel_token_new(void);

/** Cancel the token (safe from any thread). */
void mmf_cancel_token_cancel(const void* token);

/** Free the cancellation token. */
void mmf_cancel_token_free(void* token);

/**
 * Progress callback.  `stage` is valid only for the duration of the call —
 * copy it before dispatching to another thread.
 * `user_data` is passed through from mmf_open_async.
 */
typedef void (*mmf_progress_fn)(const char* stage, uint32_t current,
                                uint32_t total, void* user_data);

/**
 * Completion callback.  Called from a background thread.
 *
 * On success: `doc` is non-null, `error` is NULL.  Caller takes ownership
 * of `doc` via mmf_document_free().
 *
 * On failure: `doc` is NULL, `error` points to a UTF-8 error message
 * valid only for the duration of this callback.
 *
 * `user_data` is passed through from mmf_open_async.
 */
typedef void (*mmf_completion_fn)(MmfDocument* doc,
                                  const char* error,
                                  void* user_data);

/**
 * Start an async document open.  Returns a job handle.
 * The completion callback is called from a background thread.
 * On success, the caller takes ownership of the MmfDocument pointer.
 */
OpenDocumentJob* mmf_open_async(const char* path,
                                const void* cancel_token,
                                mmf_progress_fn progress_cb,
                                mmf_completion_fn completion_cb,
                                void* user_data);

/** Cancel a running job. */
void mmf_open_job_cancel(const OpenDocumentJob* job);

/**
 * Free the job handle.  Cancels the token and detaches the background
 * thread (non-blocking).  The completion callback may still fire.
 */
void mmf_open_job_free(OpenDocumentJob* job);

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

/** Get the default line type name for a layer.  NULL if Continuous. */
const char* mmf_drawing_layer_line_type(const MmfDocument* doc, uint32_t index);

/** Get the ACI color index for a layer.  Returns 7 (white) if invalid. */
int16_t mmf_drawing_layer_color_index(const MmfDocument* doc, uint32_t index);

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

/** Read ARC data.  Angles in radians.  out_ccw: 1=CCW, 0=CW.  Returns 1 on success. */
int mmf_draw_cmd_arc(const MmfDocument* doc, uint32_t index,
                     double* out_cx, double* out_cy, double* out_r,
                     double* out_start, double* out_end, int32_t* out_ccw);

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

/** Line type name for a draw command.  NULL if Continuous (default). */
const char* mmf_draw_cmd_line_type(const MmfDocument* doc, uint32_t index);

/** Line weight for a draw command in mm.  0.0 if default. */
double mmf_draw_cmd_line_weight(const MmfDocument* doc, uint32_t index);

/** Line dash pattern element count for a draw command.  0 if solid line. */
uint32_t mmf_draw_cmd_line_dash_count(const MmfDocument* doc, uint32_t index);

/**
 * Read line dash pattern data for a draw command.
 * @param out_dash   Output array of dash lengths (caller-allocated).
 * @param max_count  Max number of values to write.
 * @return Number of values written, or 0 if no dash pattern.
 */
uint32_t mmf_draw_cmd_line_dash(const MmfDocument* doc, uint32_t index,
                                double* out_dash, uint32_t max_count);

/**
 * Spatial query for viewport culling.
 * @param doc       Document handle.
 * @param min_x     Viewport min X (world coords).
 * @param min_y     Viewport min Y.
 * @param max_x     Viewport max X.
 * @param max_y     Viewport max Y.
 * @param out_indices  Output array of command indices (caller-allocated).
 * @param max_count    Max number of indices to write.
 * @return -1 if spatial index unavailable or error (caller falls back to full draw).
 *          0 if no commands visible in viewport (legitimate empty).
 *         >0 total matching indices. If total > max_count, caller should
 *            reallocate with the returned total and re-query.
 */
int32_t mmf_draw_spatial_query(const MmfDocument* doc,
                               double min_x, double min_y,
                               double max_x, double max_y,
                               uint32_t* out_indices, uint32_t max_count);

/* ------------------------------------------------------------------ */
/*  Streaming / chunk-based progressive loading                        */
/* ------------------------------------------------------------------ */

/**
 * Build a streaming packet splitting the document into memory-budgeted chunks.
 * @param budget_bytes  Max GPU memory per chunk (e.g. 64 * 1024 * 1024 for 64 MB).
 * @return Number of chunks (0 if document has no render data).
 */
uint32_t mmf_build_streaming_packet(MmfDocument* doc, uint32_t budget_bytes);

/** Number of streaming chunks (0 if not built or empty). */
uint32_t mmf_chunk_count(const MmfDocument* doc);

/** Number of meshes in chunk `chunk_idx`. */
uint32_t mmf_chunk_mesh_count(const MmfDocument* doc, uint32_t chunk_idx);

/** Number of instances in chunk `chunk_idx`. */
uint32_t mmf_chunk_instance_count(const MmfDocument* doc, uint32_t chunk_idx);

/**
 * Chunk AABB.  out_min/out_max each receive 3 floats.
 * @return 1 on success, 0 if chunk index invalid.
 */
int mmf_chunk_bounds(const MmfDocument* doc, uint32_t chunk_idx,
                     float* out_min, float* out_max);

/** Number of batch groups in chunk. */
uint32_t mmf_chunk_batch_count(const MmfDocument* doc, uint32_t chunk_idx);

/** GPU memory estimate for chunk in bytes. */
uint64_t mmf_chunk_memory_bytes(const MmfDocument* doc, uint32_t chunk_idx);

/** Total GPU memory across all chunks in bytes. */
uint64_t mmf_chunk_total_memory(const MmfDocument* doc);

/** Vertex count for mesh `mesh_idx` in chunk `chunk_idx`. */
uint32_t mmf_chunk_mesh_vertex_count(const MmfDocument* doc,
                                     uint32_t chunk_idx, uint32_t mesh_idx);

/** Index count for mesh `mesh_idx` in chunk `chunk_idx`. */
uint32_t mmf_chunk_mesh_index_count(const MmfDocument* doc,
                                    uint32_t chunk_idx, uint32_t mesh_idx);

/** Geometry id for mesh `mesh_idx` in chunk (returns -1 on error). */
int32_t mmf_chunk_mesh_geometry_id(const MmfDocument* doc,
                                   uint32_t chunk_idx, uint32_t mesh_idx);

/**
 * Borrowed pointer to mesh positions in chunk.
 * Valid until mmf_document_free().  Returns NULL if invalid.
 */
const float* mmf_chunk_mesh_positions(const MmfDocument* doc,
                                      uint32_t chunk_idx, uint32_t mesh_idx);

/** Borrowed pointer to mesh normals in chunk. */
const float* mmf_chunk_mesh_normals(const MmfDocument* doc,
                                    uint32_t chunk_idx, uint32_t mesh_idx);

/** Borrowed pointer to mesh indices in chunk. */
const uint32_t* mmf_chunk_mesh_indices(const MmfDocument* doc,
                                       uint32_t chunk_idx, uint32_t mesh_idx);

/* ------------------------------------------------------------------ */
/*  Frustum culling                                                    */
/* ------------------------------------------------------------------ */

/**
 * Test whether an AABB is visible within a camera frustum.
 *
 * @param bounds_min  float[3] min corner of the AABB.
 * @param bounds_max  float[3] max corner of the AABB.
 * @param cam_target  float[3] camera look-at target.
 * @param cam_distance  Distance from target to eye.
 * @param cam_yaw     Yaw in radians.
 * @param cam_pitch   Pitch in radians.
 * @param cam_fov_y   Vertical FOV in radians.
 * @param cam_near    Near plane distance.
 * @param cam_far     Far plane distance.
 * @param aspect      Viewport width/height.
 * @return 1 if visible, 0 if culled or error.
 */
int mmf_frustum_aabb_visible(const float* bounds_min, const float* bounds_max,
                              const float* cam_target,
                              float cam_distance, float cam_yaw, float cam_pitch,
                              float cam_fov_y, float cam_near, float cam_far,
                              float aspect);

#ifdef __cplusplus
}
#endif

#endif /* MMFORGE_BRIDGE_H */
