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
}

/// A single 2D drawing entity.
#[derive(Debug, Clone)]
pub enum Entity2D {
    Line {
        start: [f64; 2],
        end: [f64; 2],
        layer: String,
    },
    Circle {
        center: [f64; 2],
        radius: f64,
        layer: String,
    },
    Arc {
        center: [f64; 2],
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        layer: String,
    },
    Polyline {
        vertices: Vec<PolylineVertex>,
        closed: bool,
        layer: String,
    },
    Text {
        position: [f64; 2],
        content: String,
        height: f64,
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

impl Drawing2DGeometry {
    /// Create an empty drawing.
    pub fn new() -> Self {
        Self {
            entities: Vec::new(),
            layers: Vec::new(),
            blocks: Vec::new(),
        }
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
