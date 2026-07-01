//! 2D draw list — platform-neutral rendering commands for 2D drawings.
//!
//! All angles in [`DrawCommand2D::Arc`] are in **radians**.
//! DXF ARC entities (which use degrees) are converted during draw-list
//! construction.  Bulge-to-arc conversion also produces radians.

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
///
/// **Angle convention**: all angles are in **radians**.
#[derive(Debug, Clone)]
pub enum DrawCommand2D {
    Line {
        start: [f64; 2],
        end: [f64; 2],
    },
    /// Circular arc.
    ///
    /// - `start_angle` / `end_angle`: in **radians**, measured from the
    ///   positive X-axis.
    /// - `ccw`: `true` = counter-clockwise from `start_angle` to
    ///   `end_angle`; `false` = clockwise.
    Arc {
        center: [f64; 2],
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        ccw: bool,
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
    pub layer_name: String,
    pub cmd: DrawCommand2D,
    /// Line type name (e.g., "Continuous", "DASHED").  None = Continuous.
    pub line_type: Option<String>,
    /// Line weight in mm.  None = default (0).
    pub line_weight: Option<f64>,
}

/// Result of bulge-to-arc conversion.
struct ArcParams {
    center: [f64; 2],
    radius: f64,
    start_angle: f64,
    end_angle: f64,
    ccw: bool,
}

/// Convert degrees to radians.
fn deg_to_rad(deg: f64) -> f64 {
    deg * std::f64::consts::PI / 180.0
}

/// Convert a polyline bulge between two points into arc parameters.
///
/// - `bulge = 0` → straight segment (caller should emit a Line).
/// - `bulge > 0` → counter-clockwise arc (CCW).
/// - `bulge < 0` → clockwise arc (CW).
/// - `|bulge| = 1` → semicircle.
/// - `|bulge| > 1` → arc > 180°.
///
/// All returned angles are in **radians**.
fn bulge_to_arc(p1: [f64; 2], p2: [f64; 2], bulge: f64) -> ArcParams {
    let dx = p2[0] - p1[0];
    let dy = p2[1] - p1[1];
    let dist = (dx * dx + dy * dy).sqrt();

    if dist < 1e-10 || bulge.abs() < 1e-10 {
        return ArcParams {
            center: p1,
            radius: 0.0,
            start_angle: 0.0,
            end_angle: 0.0,
            ccw: true,
        };
    }

    let abs_sagitta = bulge.abs() * dist / 2.0;
    let radius = (dist * dist / 4.0 + abs_sagitta * abs_sagitta) / (2.0 * abs_sagitta);

    // Midpoint of chord.
    let mx = (p1[0] + p2[0]) / 2.0;
    let my = (p1[1] + p2[1]) / 2.0;

    // Left normal of the chord (perpendicular, pointing left when looking
    // from p1 to p2).
    let nx = -dy / dist;
    let ny = dx / dist;

    // Distance from midpoint to center along the normal.
    // For |bulge| < 1 (arc < 180°): offset > 0, center on arc side.
    // For |bulge| = 1 (semicircle): offset = 0, center at midpoint.
    // For |bulge| > 1 (arc > 180°): offset < 0, center on opposite side.
    let offset = radius - abs_sagitta;

    // Positive bulge → center on left side (nx direction).
    // Negative bulge → center on right side (-nx direction).
    let sign = bulge.signum();
    let cx = mx + nx * offset * sign;
    let cy = my + ny * offset * sign;

    // Angles from center to endpoints (radians).
    let start_angle = (p1[1] - cy).atan2(p1[0] - cx);
    let end_angle = (p2[1] - cy).atan2(p2[0] - cx);

    ArcParams {
        center: [cx, cy],
        radius,
        start_angle,
        end_angle,
        ccw: bulge > 0.0,
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
            commands.push(DrawCommand2D::Line { start: p1, end: p2 });
        } else {
            let arc = bulge_to_arc(p1, p2, bulge);
            commands.push(DrawCommand2D::Arc {
                center: arc.center,
                radius: arc.radius,
                start_angle: arc.start_angle,
                end_angle: arc.end_angle,
                ccw: arc.ccw,
            });
        }
    }

    commands
}

/// Build a [`DrawingDrawList`] from parsed drawing geometry.
///
/// Groups entities by layer, resolves polyline bulge to arc segments,
/// converts DXF degrees to radians, and computes the overall bounding box.
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
            | Entity2D::Text { layer, .. }
            | Entity2D::Insert { layer, .. } => layer.as_str(),
        };
        layer_map
            .entry(layer_name.to_string())
            .or_default()
            .push(entity);
    }

    // Build LayerDrawList for each layer.
    let mut layers = Vec::new();
    let mut flat_commands = Vec::new();

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
                Entity2D::Line {
                    start,
                    end,
                    line_type,
                    line_weight,
                    ..
                } => {
                    let cmd = DrawCommand2D::Line {
                        start: *start,
                        end: *end,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        layer_name: name.clone(),
                        cmd,
                        line_type: line_type.clone(),
                        line_weight: *line_weight,
                    });
                }
                Entity2D::Circle {
                    center,
                    radius,
                    line_type,
                    line_weight,
                    ..
                } => {
                    let cmd = DrawCommand2D::Circle {
                        center: *center,
                        radius: *radius,
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        layer_name: name.clone(),
                        cmd,
                        line_type: line_type.clone(),
                        line_weight: *line_weight,
                    });
                }
                Entity2D::Arc {
                    center,
                    radius,
                    start_angle,
                    end_angle,
                    line_type,
                    line_weight,
                    ..
                } => {
                    // DXF ARC angles are in degrees → convert to radians.
                    let cmd = DrawCommand2D::Arc {
                        center: *center,
                        radius: *radius,
                        start_angle: deg_to_rad(*start_angle),
                        end_angle: deg_to_rad(*end_angle),
                        ccw: true, // DXF ARC is always CCW in DXF convention.
                    };
                    commands.push(cmd.clone());
                    flat_commands.push(FlatDrawCommand {
                        layer_index: layer_idx as u32,
                        layer_name: name.clone(),
                        cmd,
                        line_type: line_type.clone(),
                        line_weight: *line_weight,
                    });
                }
                Entity2D::Polyline {
                    vertices,
                    closed,
                    line_type,
                    line_weight,
                    ..
                } => {
                    let expanded = expand_polyline(vertices, *closed);
                    for cmd in expanded {
                        commands.push(cmd.clone());
                        flat_commands.push(FlatDrawCommand {
                            layer_index: layer_idx as u32,
                            layer_name: name.clone(),
                            cmd,
                            line_type: line_type.clone(),
                            line_weight: *line_weight,
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
                        layer_name: name.clone(),
                        cmd,
                        line_type: None,
                        line_weight: None,
                    });
                }
                Entity2D::Insert { .. } => {
                    // INSERTs should be expanded before draw list construction.
                    // If one survives, skip it silently.
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

    // ---------------------------------------------------------------
    // Draw list builder tests
    // ---------------------------------------------------------------

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
            line_type: None,
            line_weight: None,
        });
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 1.0],
            end: [1.0, 1.0],
            layer: "walls".to_string(),
            line_type: None,
            line_weight: None,
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
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        let hidden = &dl.layers[0];
        assert!(!hidden.visible);
        assert_eq!(dl.flat_commands.len(), 1);
    }

    #[test]
    fn build_draw_list_unknown_layer_defaults_visible() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Line {
            start: [0.0, 0.0],
            end: [1.0, 1.0],
            layer: "unknown".to_string(),
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.layers.len(), 1);
        assert!(dl.layers[0].visible);
        assert_eq!(dl.layers[0].color_index, 7);
    }

    // ---------------------------------------------------------------
    // DXF ARC degree → radian conversion
    // ---------------------------------------------------------------

    #[test]
    fn dxf_arc_converted_to_radians() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Arc {
            center: [0.0, 0.0],
            radius: 5.0,
            start_angle: 0.0, // degrees
            end_angle: 90.0,  // degrees
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.flat_commands.len(), 1);
        match &dl.flat_commands[0].cmd {
            DrawCommand2D::Arc {
                start_angle,
                end_angle,
                ccw,
                ..
            } => {
                // 0° → 0.0 rad, 90° → π/2 rad
                assert!((start_angle - 0.0).abs() < 1e-10);
                assert!((end_angle - std::f64::consts::FRAC_PI_2).abs() < 1e-10);
                assert!(*ccw);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn dxf_arc_180_degrees() {
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Arc {
            center: [1.0, 2.0],
            radius: 3.0,
            start_angle: 45.0,
            end_angle: 225.0,
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        match &dl.flat_commands[0].cmd {
            DrawCommand2D::Arc {
                center,
                radius,
                start_angle,
                end_angle,
                ..
            } => {
                assert_eq!(*center, [1.0, 2.0]);
                assert_eq!(*radius, 3.0);
                assert!((start_angle - deg_to_rad(45.0)).abs() < 1e-10);
                assert!((end_angle - deg_to_rad(225.0)).abs() < 1e-10);
            }
            _ => panic!("expected Arc"),
        }
    }

    // ---------------------------------------------------------------
    // Bulge-to-arc tests
    // ---------------------------------------------------------------

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
    fn bulge_positive_semicircle() {
        // bulge = 1.0 → semicircle, CCW.
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
            DrawCommand2D::Arc {
                center,
                radius,
                ccw,
                ..
            } => {
                // Semicircle: center at (1, 0), radius = 1.
                assert!((center[0] - 1.0).abs() < 1e-10);
                assert!((center[1] - 0.0).abs() < 1e-10);
                assert!((radius - 1.0).abs() < 1e-10);
                assert!(*ccw);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn bulge_negative_semicircle() {
        // bulge = -1.0 → semicircle, CW.
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: -1.0,
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
            DrawCommand2D::Arc {
                center,
                radius,
                ccw,
                ..
            } => {
                // Semicircle: center at (1, 0), radius = 1.
                assert!((center[0] - 1.0).abs() < 1e-10);
                assert!((center[1] - 0.0).abs() < 1e-10);
                assert!((radius - 1.0).abs() < 1e-10);
                assert!(!(*ccw)); // CW
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn bulge_positive_small_arc() {
        // bulge = 0.1 → small arc, CCW.
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 0.1,
                },
                PolylineVertex {
                    point: [1.0, 0.0],
                    bulge: 0.0,
                },
            ],
            false,
        );
        assert_eq!(cmds.len(), 1);
        match &cmds[0] {
            DrawCommand2D::Arc {
                center,
                radius,
                ccw,
                ..
            } => {
                // Small arc: center above the chord (CCW).
                assert!(center[1] > 0.0); // center on left side of P1→P2
                assert!(*radius > 0.5); // radius > half chord
                assert!(*ccw);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn bulge_negative_small_arc() {
        // bulge = -0.1 → small arc, CW.
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: -0.1,
                },
                PolylineVertex {
                    point: [1.0, 0.0],
                    bulge: 0.0,
                },
            ],
            false,
        );
        assert_eq!(cmds.len(), 1);
        match &cmds[0] {
            DrawCommand2D::Arc {
                center,
                radius,
                ccw,
                ..
            } => {
                // Small arc: center below the chord (CW).
                assert!(center[1] < 0.0); // center on right side of P1→P2
                assert!(*radius > 0.5);
                assert!(!(*ccw)); // CW
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn bulge_positive_large_arc() {
        // bulge = 2.0 → arc > 180°, CCW.
        let cmds = expand_polyline(
            &[
                PolylineVertex {
                    point: [0.0, 0.0],
                    bulge: 2.0,
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
            DrawCommand2D::Arc {
                center,
                radius,
                ccw,
                ..
            } => {
                // For |bulge| > 1, center is on opposite side of chord from arc.
                // Positive bulge (CCW), arc is above, center is below.
                assert!(center[1] < 0.0);
                assert!(*radius > 0.0);
                assert!(*ccw);
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
            true,
        );
        assert_eq!(cmds.len(), 3); // 3 segments for closed triangle
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
            line_type: None,
            line_weight: None,
        });
        drawing.entities.push(Entity2D::Circle {
            center: [5.0, 5.0],
            radius: 2.0,
            layer: "L1".to_string(),
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        assert_eq!(dl.flat_commands.len(), 2);
        assert_eq!(dl.flat_commands[0].layer_index, 0);
        assert_eq!(dl.flat_commands[1].layer_index, 0);
    }

    // ---------------------------------------------------------------
    // Cross-0° arc test
    // ---------------------------------------------------------------

    #[test]
    fn arc_crossing_zero_degrees() {
        // DXF ARC: start=350°, end=10° → crosses 0°.
        // In radians: start ≈ 6.108, end ≈ 0.175.
        let mut drawing = Drawing2DGeometry::new();
        drawing.entities.push(Entity2D::Arc {
            center: [0.0, 0.0],
            radius: 1.0,
            start_angle: 350.0,
            end_angle: 10.0,
            layer: "0".to_string(),
            line_type: None,
            line_weight: None,
        });

        let dl = build_draw_list(&drawing);
        match &dl.flat_commands[0].cmd {
            DrawCommand2D::Arc {
                start_angle,
                end_angle,
                ccw,
                ..
            } => {
                assert!((start_angle - deg_to_rad(350.0)).abs() < 1e-10);
                assert!((end_angle - deg_to_rad(10.0)).abs() < 1e-10);
                assert!(*ccw);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn bulge_opposite_directions_have_opposite_centers() {
        // Same chord, opposite bulge signs → centers on opposite sides.
        let p1 = [0.0, 0.0];
        let p2 = [2.0, 0.0];

        let arc_pos = bulge_to_arc(p1, p2, 0.5);
        let arc_neg = bulge_to_arc(p1, p2, -0.5);

        // Positive bulge: center above (positive Y).
        assert!(arc_pos.center[1] > 0.0);
        // Negative bulge: center below (negative Y).
        assert!(arc_neg.center[1] < 0.0);
        // Same radius.
        assert!((arc_pos.radius - arc_neg.radius).abs() < 1e-10);
        // Opposite direction.
        assert!(arc_pos.ccw);
        assert!(!arc_neg.ccw);
    }
}
