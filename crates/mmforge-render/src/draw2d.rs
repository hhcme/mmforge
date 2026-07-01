//! 2D draw list — platform-neutral rendering commands for 2D drawings.
//!
//! Converts [`Drawing2DGeometry`] into a flat list of draw commands
//! grouped by layer.  Platform renderers (Core Graphics, Direct2D,
//! Canvas) consume this structure to produce native 2D output.

use mmforge_core::drawing::{BBox2D, Drawing2DGeometry, Entity2D};

/// Top-level draw list for a 2D drawing.
#[derive(Debug, Clone)]
pub struct DrawingDrawList {
    pub layers: Vec<LayerDrawList>,
    pub bounds: BBox2D,
}

/// Draw commands for a single layer.
#[derive(Debug, Clone)]
pub struct LayerDrawList {
    pub layer_name: String,
    pub visible: bool,
    pub color_index: i16,
    pub commands: Vec<DrawCommand2D>,
}

/// A single 2D draw command.
#[derive(Debug, Clone)]
pub enum DrawCommand2D {
    Line {
        start: [f64; 2],
        end: [f64; 2],
    },
    Arc {
        center: [f64; 2],
        radius: f64,
        start_angle: f64,
        end_angle: f64,
    },
    Circle {
        center: [f64; 2],
        radius: f64,
    },
    Polyline {
        points: Vec<[f64; 2]>,
        closed: bool,
    },
    Text {
        position: [f64; 2],
        content: String,
        height: f64,
        rotation: f64,
    },
}

/// Build a [`DrawingDrawList`] from parsed drawing geometry.
///
/// Groups entities by layer, resolves polyline bulge to arc segments,
/// and computes the overall bounding box.
pub fn build_draw_list(drawing: &Drawing2DGeometry) -> DrawingDrawList {
    // Group entities by layer.
    let mut layer_map: std::collections::HashMap<String, Vec<&Entity2D>> =
        std::collections::HashMap::new();
    for entity in &drawing.entities {
        let layer_name = match entity {
            Entity2D::Line { layer, .. }
            | Entity2D::Circle { layer, .. }
            | Entity2D::Arc { layer, .. }
            | Entity2D::Polyline { layer, .. }
            | Entity2D::Text { layer, .. } => layer.as_str(),
        };
        layer_map
            .entry(layer_name.to_string())
            .or_default()
            .push(entity);
    }

    // Build LayerDrawList for each layer.
    let mut layers = Vec::new();
    for (name, entities) in &layer_map {
        // Find layer metadata.
        let layer_meta = drawing.layers.iter().find(|l| &l.name == name);
        let visible = layer_meta.is_none_or(|l| l.visible);
        let color_index = layer_meta.map_or(7, |l| l.color_index);

        let mut commands = Vec::new();
        for entity in entities {
            match entity {
                Entity2D::Line { start, end, .. } => {
                    commands.push(DrawCommand2D::Line {
                        start: *start,
                        end: *end,
                    });
                }
                Entity2D::Circle { center, radius, .. } => {
                    commands.push(DrawCommand2D::Circle {
                        center: *center,
                        radius: *radius,
                    });
                }
                Entity2D::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                    ..
                } => {
                    commands.push(DrawCommand2D::Arc {
                        center: *center,
                        radius: *radius,
                        start_angle: *start_angle,
                        end_angle: *end_angle,
                    });
                }
                Entity2D::Polyline {
                    vertices, closed, ..
                } => {
                    let points: Vec<[f64; 2]> = vertices.iter().map(|v| v.point).collect();
                    commands.push(DrawCommand2D::Polyline {
                        points,
                        closed: *closed,
                    });
                }
                Entity2D::Text {
                    position,
                    content,
                    height,
                    rotation,
                    ..
                } => {
                    commands.push(DrawCommand2D::Text {
                        position: *position,
                        content: content.clone(),
                        height: *height,
                        rotation: *rotation,
                    });
                }
            }
        }

        layers.push(LayerDrawList {
            layer_name: name.clone(),
            visible,
            color_index,
            commands,
        });
    }

    // Sort layers by name for deterministic output.
    layers.sort_by(|a, b| a.layer_name.cmp(&b.layer_name));

    let bounds = drawing.bounds();

    DrawingDrawList { layers, bounds }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mmforge_core::drawing::{Drawing2DGeometry, Entity2D, Layer, PolylineVertex};

    #[test]
    fn build_empty_draw_list() {
        let drawing = Drawing2DGeometry::new();
        let dl = build_draw_list(&drawing);
        assert!(dl.layers.is_empty());
        assert!(!dl.bounds.is_valid());
    }

    #[test]
    fn build_draw_list_groups_by_layer() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.layers.push(Layer {
            name: "walls".to_string(),
            color_index: 1,
            visible: true,
        });
        drawing.layers.push(Layer {
            name: "text".to_string(),
            color_index: 7,
            visible: true,
        });
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [1.0, 0.0],
            layer: "walls".to_string(),
        });
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 1.0],
            end: [1.0, 1.0],
            layer: "walls".to_string(),
        });
        drawing.entities.push(Entity2D::Text {
            position: [0.5, 0.5],
            content: "Hello".to_string(),
            height: 0.1,
            rotation: 0.0,
            layer: "text".to_string(),
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.layers.len(), 2);

        let walls = dl.layers.iter().find(|l| l.layer_name == "walls").unwrap();
        assert_eq!(walls.commands.len(), 2);
        assert_eq!(walls.color_index, 1);

        let text = dl.layers.iter().find(|l| l.layer_name == "text").unwrap();
        assert_eq!(text.commands.len(), 1);
    }

    #[test]
    fn build_draw_list_hidden_layer() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.layers.push(Layer {
            name: "hidden".to_string(),
            color_index: 7,
            visible: false,
        });
        drawing.entities.push(Entity2D::Circle {
            center: [0.0, 0.0],
            radius: 1.0,
            layer: "hidden".to_string(),
        });

        let dl = build_draw_list(&drawing);
        let hidden = &dl.layers[0];
        assert!(!hidden.visible);
    }

    #[test]
    fn build_draw_list_unknown_layer_defaults_visible() {
        let mut drawing = Drawing2DGeometry::new();
        // Entity references layer "unknown" which is not in the layers list.
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [1.0, 1.0],
            layer: "unknown".to_string(),
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.layers.len(), 1);
        assert!(dl.layers[0].visible);
        assert_eq!(dl.layers[0].color_index, 7); // default white
    }
}
