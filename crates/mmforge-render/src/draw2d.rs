//! 2D draw list — platform-neutral rendering commands for 2D drawings.
//!
//! Converts [`Drawing2DGeometry`] into a flat list of draw commands
//! grouped by layer.  Platform renderers (Core Graphics, Direct2D,
//! Canvas) consume this structure to produce native 2D output.

use mmforge_core::drawing::{BBox2D, Drawing2DGeometry, Entity2D, PolylineVertex};

/// Top-level draw list for a 2D drawing.
#[derive(Debug, Clone)]
pub struct DrawingDrawList {
    pub layers: Vec<LayerDrawList>,
    pub bounds: BBox2D,
    /// Flat list of all commands with layer index, for C ABI access.
    pub flat_commands: Vec<FlatDrawCommand>,
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

/// A flattened draw command with layer index, for C ABI access.
#[derive(Debug, Clone)]
pub struct FlatDrawCommand {
    pub layer_index: u32,
    pub cmd: DrawCommand2D,
}

/// Result of bulge-to-arc conversion.
struct ArcParams {
    center: [f64; 2],
    radius: f64,
    start_angle: f64,
    end_angle: f64,
}

/// Convert a polyline bulge between two points into arc parameters.
///
/// `bulge = 0` means a straight segment.  `bulge != 0` means an arc:
/// `theta = 4 * atan(|bulge|)`.  Positive bulge = counter-clockwise.
fn bulge_to_arc(p1: [f64; 2], p2: [f64; 2], bulge: f64) -> ArcParams {
    let dx = p2[0] - p1[0];
    let dy = p2[1] - p1[1];
    let dist = (dx * dx + dy * dy).sqrt();

    if dist < 1e-10 || bulge.abs() < 1e-10 {
        // Degenerate: return a zero-radius arc at p1.
        return ArcParams {
            center: p1,
            radius: 0.0,
            start_angle: 0.0,
            end_angle: 0.0,
        };
    }

    let sagitta = bulge * dist / 2.0;
    let radius = (dist * dist / 4.0 + sagitta * sagitta) / (2.0 * sagitta.abs());

    // Midpoint of chord.
    let mx = (p1[0] + p2[0]) / 2.0;
    let my = (p1[1] + p2[1]) / 2.0;

    // Perpendicular direction (normalized).
    let nx = -dy / dist;
    let ny = dx / dist;

    // Center offset from midpoint.
    let offset = radius - sagitta;
    let cx = mx + nx * offset * bulge.signum();
    let cy = my + ny * offset * bulge.signum();

    // Start and end angles (radians).
    let start_angle = (p1[1] - cy).atan2(p1[0] - cx);
    let end_angle = (p2[1] - cy).atan2(p2[0] - cx);

    ArcParams {
        center: [cx, cy],
        radius,
        start_angle,
        end_angle,
    }
}

/// Expand a polyline with bulge values into a sequence of draw commands.
///
/// Each segment is either a straight line (bulge ≈ 0) or an arc (bulge ≠ 0).
fn expand_polyline(vertices: &[PolylineVertex], closed: bool) -> Vec<DrawCommand2D> {
    if vertices.is_empty() {
        return Vec::new();
    }

    let mut commands = Vec::new();
    let seg_count = if closed {
        vertices.len()
    } else {
        vertices.len() - 1
    };

    for i in 0..seg_count {
        let p1 = vertices[i].point;
        let p2 = vertices[(i + 1) % vertices.len()].point;
        let bulge = vertices[i].bulge;

        if bulge.abs() < 1e-10 {
            // Straight segment.
            commands.push(DrawCommand2D::Line { start: p1, end: p2 });
        } else {
            // Arc segment.
            let arc = bulge_to_arc(p1, p2, bulge);
            commands.push(DrawCommand2D::Arc {
                center: arc.center,
                radius: arc.radius,
                start_angle: arc.start_angle,
                end_angle: arc.end_angle,
            });
        }
    }

    commands
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
    let mut flat_commands = Vec::new();

    // Sort layer names for deterministic output.
    let mut layer_names: Vec<String> = layer_map.keys().cloned().collect();
    layer_names.sort();

    for (layer_idx, name) in layer_names.iter().enumerate() {
        let entities = &layer_map[name];
        let layer_meta = drawing.layers.iter().find(|l| &l.name == name);
        let visible = layer_meta.is_none_or(|l| l.visible);
        let color_index = layer_meta.map_or(7, |l| l.color_index);

        let mut commands = Vec::new();
        for entity in entities {
            match entity {
                Entity2D::Line { start, end, .. } => {
                    let cmd = DrawCommand2D::Line {
                        start: *start,
                        end: *end,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        cmd,
                    });
                }
                Entity2D::Circle { center, radius, .. } => {
                    let cmd = DrawCommand2D::Circle {
                        center: *center,
                        radius: *radius,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        cmd,
                    });
                }
                Entity2D::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                    ..
                } => {
                    let cmd = DrawCommand2D::Arc {
                        center: *center,
                        radius: *radius,
                        start_angle: *start_angle,
                        end_angle: *end_angle,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        cmd,
                    });
                }
                Entity2D::Polyline {
                    vertices, closed, ..
                } => {
                    // Expand bulge segments into line/arc commands.
                    let expanded = expand_polyline(vertices, *closed);
                    for cmd in expanded {
                        commands.push(cmd.clone());
                        flat_commands.push(FlatDrawCommand {
                            layer_index: layer_idx as u32,
                            cmd,
                        });
                    }
                }
                Entity2D::Text {
                    position,
                    content,
                    height,
                    rotation,
                    ..
                } => {
                    let cmd = DrawCommand2D::Text {
                        position: *position,
                        content: content.clone(),
                        height: *height,
                        rotation: *rotation,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        cmd,
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

    let bounds = drawing.bounds();

    DrawingDrawList {
        layers,
        bounds,
        flat_commands,
    }
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
        assert!(dl.flat_commands.is_empty());
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
        assert_eq!(dl.flat_commands.len(), 3);

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
        // Command is still in flat list (visibility is a rendering decision).
        assert_eq!(dl.flat_commands.len(), 1);
    }

    #[test]
    fn build_draw_list_unknown_layer_defaults_visible() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [1.0, 1.0],
            layer: "unknown".to_string(),
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.layers.len(), 1);
        assert!(dl.layers[0].visible);
        assert_eq!(dl.layers[0].color_index, 7);
    }

    #[test]
    fn bulge_zero_is_straight_line() {
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 0.0,
                },
                PolylineVertex {
                    point: [1.0, 0.0],
                    bulge: 0.0,
                },
            ],
            false,
        );
        assert_eq!(cmds.len(), 1);
        assert!(matches!(cmds[0], DrawCommand2D::Line { .. }));
    }

    #[test]
    fn bulge_nonzero_is_arc() {
        // bulge = 1.0 means semicircle.
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 1.0,
                },
                PolylineVertex {
                    point: [2.0, 0.0],
                    bulge: 0.0,
                },
            ],
            false,
        );
        assert_eq!(cmds.len(), 1);
        match &cmds[0] {
            DrawCommand2D::Arc { center, radius, .. } => {
                // Semicircle: center at (1, 0), radius = 1.
                assert!((center[0] - 1.0).abs() < 0.01);
                assert!((radius - 1.0).abs() < 0.01);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn closed_polyline_wraps_around() {
        let cmds = expand_polyline(
            &[
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
            true, // closed
        );
        // 3 segments for closed triangle.
        assert_eq!(cmds.len(), 3);
    }

    #[test]
    fn polyline_with_mixed_bulge() {
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 0.0,
                },
                PolylineVertex {
                    point: [1.0, 0.0],
                    bulge: 0.5,
                },
                PolylineVertex {
                    point: [2.0, 0.0],
                    bulge: 0.0,
                },
            ],
            false,
        );
        // Segment 1: straight line. Segment 2: arc.
        assert_eq!(cmds.len(), 2);
        assert!(matches!(cmds[0], DrawCommand2D::Line { .. }));
        assert!(matches!(cmds[1], DrawCommand2D::Arc { .. }));
    }

    #[test]
    fn flat_commands_match_layer_commands() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.layers.push(Layer {
            name: "L1".to_string(),
            color_index: 1,
            visible: true,
        });
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [1.0, 0.0],
            layer: "L1".to_string(),
        });
        drawing.entities.push(Entity2D::Circle {
            center: [5.0, 5.0],
            radius: 2.0,
            layer: "L1".to_string(),
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.flat_commands.len(), 2);
        assert_eq!(dl.flat_commands[0].layer_index, 0);
        assert_eq!(dl.flat_commands[1].layer_index, 0);
    }
}
