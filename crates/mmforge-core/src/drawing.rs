//! 2D drawing types for DXF and other 2D formats.
//!
//! These types represent parsed 2D drawing data before it is converted
//! into platform-specific draw commands.  They are format-agnostic —
//! the DXF parser produces these, and the 2D renderer consumes them.

/// Top-level container for a parsed 2D drawing.
#[derive(Debug, Clone)]
pub struct Drawing2DGeometry {
    pub entities: Vec<Entity2D>,
    pub layers: Vec<Layer>,
    pub blocks: Vec<Block>,
    pub line_types: Vec<LineType>,
}

/// A single 2D drawing entity.
#[derive(Debug, Clone)]
pub enum Entity2D {
    Line {
        start: [f64; 2],
        end: [f64; 2],
        layer: String,
        line_type: Option<String>,
        line_weight: Option<f64>,
    },
    Circle {
        center: [f64; 2],
        radius: f64,
        layer: String,
        line_type: Option<String>,
        line_weight: Option<f64>,
    },
    Arc {
        center: [f64; 2],
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        layer: String,
        line_type: Option<String>,
        line_weight: Option<f64>,
    },
    Polyline {
        vertices: Vec<PolylineVertex>,
        closed: bool,
        layer: String,
        line_type: Option<String>,
        line_weight: Option<f64>,
    },
    Text {
        position: [f64; 2],
        content: String,
        height: f64,
        rotation: f64,
        layer: String,
    },
    Insert {
        block_name: String,
        insert_point: [f64; 2],
        scale: [f64; 2],
        /// Rotation in **degrees** (DXF convention). Converted to radians
        /// during `expand_inserts`.
        rotation: f64,
        layer: String,
    },
}

/// A vertex in a polyline, with optional bulge for arc segments.
///
/// `bulge = 0` means a straight segment to the next vertex.
/// `bulge != 0` means an arc segment: `theta = 4 * atan(|bulge|)`.
#[derive(Debug, Clone)]
pub struct PolylineVertex {
    pub point: [f64; 2],
    pub bulge: f64,
}

/// A drawing layer with display properties.
#[derive(Debug, Clone)]
pub struct Layer {
    pub name: String,
    /// AutoCAD Color Index (ACI).  Negative means the layer is off.
    pub color_index: i16,
    pub visible: bool,
}

/// A block definition (reusable group of entities).
#[derive(Debug, Clone)]
pub struct Block {
    pub name: String,
    pub base_point: [f64; 2],
    pub entities: Vec<Entity2D>,
}

/// A line type definition (dash/dot pattern).
#[derive(Debug, Clone)]
pub struct LineType {
    pub name: String,
    pub description: String,
    /// Dash lengths: positive = dash, negative = gap, zero = dot.
    pub dashes: Vec<f64>,
    /// Total pattern length.
    pub total_length: f64,
}

impl Drawing2DGeometry {
    /// Create an empty drawing.
    pub fn new() -> Self {
        Self {
            entities: Vec::new(),
            layers: Vec::new(),
            blocks: Vec::new(),
            line_types: Vec::new(),
        }
    }

    /// Expand all INSERT entities by cloning block entities with transforms.
    ///
    /// After expansion, no `Entity2D::Insert` variants remain.
    /// DXF INSERT rotation (degrees) is converted to radians here.
    /// Block entities are first translated by `-base_point`, then
    /// scale → rotate → translate per DXF INSERT semantics.
    pub fn expand_inserts(&mut self) {
        let blocks: std::collections::HashMap<String, (&[Entity2D], [f64; 2])> = self
            .blocks
            .iter()
            .map(|b| (b.name.clone(), (b.entities.as_slice(), b.base_point)))
            .collect();
        let mut expanded = Vec::new();
        for entity in self.entities.drain(..) {
            match &entity {
                Entity2D::Insert {
                    block_name,
                    insert_point,
                    scale,
                    rotation,
                    layer,
                } => {
                    if let Some((block_entities, base_point)) = blocks.get(block_name) {
                        let rot_rad = rotation * std::f64::consts::PI / 180.0;
                        for block_entity in *block_entities {
                            let mut cloned = block_entity.clone();
                            // First translate by -base_point (block origin).
                            shift_entity(&mut cloned, [-base_point[0], -base_point[1]]);
                            // Then scale → rotate → translate to insert point.
                            transform_entity(&mut cloned, *insert_point, rot_rad, *scale, layer);
                            expanded.push(cloned);
                        }
                    }
                    // If block not found, silently skip the INSERT.
                }
                other => expanded.push(other.clone()),
            }
        }
        self.entities = expanded;
    }

    /// Compute the axis-aligned bounding box of all entities.
    pub fn bounds(&self) -> BBox2D {
        let mut bbox = BBox2D::EMPTY;
        for entity in &self.entities {
            match entity {
                Entity2D::Line { start, end, .. } => {
                    bbox.extend_point(*start);
                    bbox.extend_point(*end);
                }
                Entity2D::Circle { center, radius, .. } => {
                    bbox.extend_point([center[0] - radius, center[1] - radius]);
                    bbox.extend_point([center[0] + radius, center[1] + radius]);
                }
                Entity2D::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                    ..
                } => {
                    // Bounding box of an arc: center ± radius, then clip to arc range.
                    // For simplicity, use the full circle bbox (slightly oversized).
                    let _ = (start_angle, end_angle);
                    bbox.extend_point([center[0] - radius, center[1] - radius]);
                    bbox.extend_point([center[0] + radius, center[1] + radius]);
                }
                Entity2D::Polyline { vertices, .. } => {
                    for v in vertices {
                        bbox.extend_point(v.point);
                    }
                }
                Entity2D::Text {
                    position, height, ..
                } => {
                    bbox.extend_point(*position);
                    bbox.extend_point([position[0] + height * 5.0, position[1] + *height]);
                }
                Entity2D::Insert {
                    insert_point,
                    scale,
                    ..
                } => {
                    // Approximate: insert point ± some margin for the block.
                    bbox.extend_point(*insert_point);
                    bbox.extend_point([
                        insert_point[0] + scale[0].abs() * 10.0,
                        insert_point[1] + scale[1].abs() * 10.0,
                    ]);
                }
            }
        }
        bbox
    }

    /// Number of entities.
    pub fn entity_count(&self) -> usize {
        self.entities.len()
    }

    /// Number of layers.
    pub fn layer_count(&self) -> usize {
        self.layers.len()
    }
}

impl Default for Drawing2DGeometry {
    fn default() -> Self {
        Self::new()
    }
}

/// Axis-aligned bounding box for 2D geometry.
#[derive(Debug, Clone, Copy)]
pub struct BBox2D {
    pub min: [f64; 2],
    pub max: [f64; 2],
}

impl BBox2D {
    pub const EMPTY: Self = Self {
        min: [f64::MAX, f64::MAX],
        max: [f64::MIN, f64::MIN],
    };

    pub fn is_valid(&self) -> bool {
        self.min[0] <= self.max[0] && self.min[1] <= self.max[1]
    }

    pub fn extend_point(&mut self, p: [f64; 2]) {
        self.min[0] = self.min[0].min(p[0]);
        self.min[1] = self.min[1].min(p[1]);
        self.max[0] = self.max[0].max(p[0]);
        self.max[1] = self.max[1].max(p[1]);
    }

    pub fn width(&self) -> f64 {
        self.max[0] - self.min[0]
    }

    pub fn height(&self) -> f64 {
        self.max[1] - self.min[1]
    }
}

/// Transform a 2D point by translate, rotate (radians CCW), and scale.
fn transform_point(p: [f64; 2], translate: [f64; 2], rotation: f64, scale: [f64; 2]) -> [f64; 2] {
    let sx = p[0] * scale[0];
    let sy = p[1] * scale[1];
    let cos = rotation.cos();
    let sin = rotation.sin();
    [
        sx * cos - sy * sin + translate[0],
        sx * sin + sy * cos + translate[1],
    ]
}

/// Apply translate/rotate/scale transform to an entity in-place.
///
/// The transform order matches DXF INSERT semantics:
/// 1. Scale relative to block base point (already subtracted).
/// 2. Rotate around origin.
/// 3. Translate to insert point.
///
/// `rotation` is in **radians**.
pub fn transform_entity(
    entity: &mut Entity2D,
    translate: [f64; 2],
    rotation: f64,
    scale: [f64; 2],
    override_layer: &str,
) {
    // Override layer if the entity's layer is the default "0".
    let apply_layer = |layer: &mut String| {
        if layer == "0" && override_layer != "0" {
            *layer = override_layer.to_string();
        }
    };

    match entity {
        Entity2D::Line {
            start, end, layer, ..
        } => {
            apply_layer(layer);
            *start = transform_point(*start, translate, rotation, scale);
            *end = transform_point(*end, translate, rotation, scale);
        }
        Entity2D::Circle {
            center,
            radius,
            layer,
            ..
        } => {
            apply_layer(layer);
            *center = transform_point(*center, translate, rotation, scale);
            *radius *= scale[0].max(scale[1]);
        }
        Entity2D::Arc {
            center,
            radius,
            start_angle,
            end_angle,
            layer,
            ..
        } => {
            apply_layer(layer);
            *center = transform_point(*center, translate, rotation, scale);
            *radius *= scale[0].max(scale[1]);
            // Arc angles are in DXF degrees; rotation is radians.
            *start_angle += rotation.to_degrees();
            *end_angle += rotation.to_degrees();
        }
        Entity2D::Polyline {
            vertices, layer, ..
        } => {
            apply_layer(layer);
            for v in vertices {
                v.point = transform_point(v.point, translate, rotation, scale);
            }
        }
        Entity2D::Text {
            position,
            rotation: text_rot,
            layer,
            ..
        } => {
            apply_layer(layer);
            *position = transform_point(*position, translate, rotation, scale);
            *text_rot += rotation.to_degrees();
        }
        Entity2D::Insert { layer, .. } => {
            apply_layer(layer);
            // Nested INSERTs are not expanded recursively here;
            // the caller should run expand_inserts() iteratively if needed.
        }
    }
}

/// Shift all geometry in an entity by a constant offset (for base_point subtraction).
fn shift_entity(entity: &mut Entity2D, offset: [f64; 2]) {
    match entity {
        Entity2D::Line { start, end, .. } => {
            start[0] += offset[0];
            start[1] += offset[1];
            end[0] += offset[0];
            end[1] += offset[1];
        }
        Entity2D::Circle { center, .. } => {
            center[0] += offset[0];
            center[1] += offset[1];
        }
        Entity2D::Arc { center, .. } => {
            center[0] += offset[0];
            center[1] += offset[1];
        }
        Entity2D::Polyline { vertices, .. } => {
            for v in vertices {
                v.point[0] += offset[0];
                v.point[1] += offset[1];
            }
        }
        Entity2D::Text { position, .. } => {
            position[0] += offset[0];
            position[1] += offset[1];
        }
        Entity2D::Insert { insert_point, .. } => {
            insert_point[0] += offset[0];
            insert_point[1] += offset[1];
        }
    }
}

/// Map DXF AutoCAD Color Index (ACI) to RGBA.
pub fn aci_to_rgba(index: i16) -> [f32; 4] {
    match index.abs() {
        1 => [1.0, 0.0, 0.0, 1.0], // red
        2 => [1.0, 1.0, 0.0, 1.0], // yellow
        3 => [0.0, 1.0, 0.0, 1.0], // green
        4 => [0.0, 1.0, 1.0, 1.0], // cyan
        5 => [0.0, 0.0, 1.0, 1.0], // blue
        6 => [1.0, 0.0, 1.0, 1.0], // magenta
        _ => [1.0, 1.0, 1.0, 1.0], // white (default)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_drawing_bounds() {
        let drawing = Drawing2DGeometry::new();
        let bbox = drawing.bounds();
        assert!(!bbox.is_valid());
    }

    #[test]
    fn line_bounds() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [10.0, 5.0],
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });
        let bbox = drawing.bounds();
        assert!(bbox.is_valid());
        assert_eq!(bbox.min, [0.0, 0.0]);
        assert_eq!(bbox.max, [10.0, 5.0]);
    }

    #[test]
    fn circle_bounds() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Circle {
            center: [5.0, 5.0],
            radius: 3.0,
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });
        let bbox = drawing.bounds();
        assert_eq!(bbox.min, [2.0, 2.0]);
        assert_eq!(bbox.max, [8.0, 8.0]);
    }

    #[test]
    fn polyline_bounds() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Polyline {
            vertices: vec![
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 0.0,
                },
                PolylineVertex {
                    point: [1.0, 0.0],
                    bulge: 0.0,
                },
                PolylineVertex {
                    point: [1.0, 1.0],
                    bulge: 0.0,
                },
            ],
            closed: true,
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });
        let bbox = drawing.bounds();
        assert_eq!(bbox.min, [0.0, 0.0]);
        assert_eq!(bbox.max, [1.0, 1.0]);
    }

    #[test]
    fn aci_colors() {
        assert_eq!(aci_to_rgba(1), [1.0, 0.0, 0.0, 1.0]);
        assert_eq!(aci_to_rgba(7), [1.0, 1.0, 1.0, 1.0]);
        assert_eq!(aci_to_rgba(0), [1.0, 1.0, 1.0, 1.0]);
    }
}
