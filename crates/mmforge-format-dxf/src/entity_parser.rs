//! DXF entity parser.
//!
//! Converts raw group pairs into typed [`Entity2D`] values.
//! Supports LINE, CIRCLE, ARC, LWPOLYLINE, and TEXT entities.

use mmforge_core::drawing::{Entity2D, PolylineVertex};

use crate::tokenizer::DxfPair;

/// Parse a list of entity sections into typed entities.
///
/// Each "entity" in the ENTITIES section starts with group code 0
/// containing the entity type name.  All subsequent pairs until the
/// next code 0 belong to that entity.
pub fn parse_entities(pairs: &[DxfPair]) -> Vec<Entity2D> {
    let mut entities = Vec::new();
    let mut i = 0;

    while i < pairs.len() {
        if pairs[i].code == 0 {
            let entity_type = pairs[i].value.clone();
            i += 1;

            // Collect all pairs for this entity (until next code 0).
            let mut entity_pairs = Vec::new();
            while i < pairs.len() && pairs[i].code != 0 {
                entity_pairs.push(&pairs[i]);
                i += 1;
            }

            if let Some(entity) = parse_single_entity(&entity_type, &entity_pairs) {
                entities.push(entity);
            }
        } else {
            i += 1;
        }
    }

    entities
}

fn parse_single_entity(entity_type: &str, pairs: &[&DxfPair]) -> Option<Entity2D> {
    match entity_type {
        "LINE" => parse_line(pairs),
        "CIRCLE" => parse_circle(pairs),
        "ARC" => parse_arc(pairs),
        "LWPOLYLINE" => parse_lwpolyline(pairs),
        "TEXT" => parse_text(pairs),
        _ => None, // Unsupported entity — skip.
    }
}

fn get_f64(pairs: &[&DxfPair], code: i32) -> Option<f64> {
    pairs
        .iter()
        .find(|p| p.code == code)
        .and_then(|p| p.value.parse().ok())
}

fn get_str<'a>(pairs: &[&'a DxfPair], code: i32) -> Option<&'a str> {
    pairs
        .iter()
        .find(|p| p.code == code)
        .map(|p| p.value.as_str())
}

fn get_i32(pairs: &[&DxfPair], code: i32) -> Option<i32> {
    pairs
        .iter()
        .find(|p| p.code == code)
        .and_then(|p| p.value.parse().ok())
}

fn layer_name(pairs: &[&DxfPair]) -> String {
    get_str(pairs, 8).unwrap_or("0").to_string()
}

fn parse_line(pairs: &[&DxfPair]) -> Option<Entity2D> {
    let start = [get_f64(pairs, 10)?, get_f64(pairs, 20)?];
    let end = [get_f64(pairs, 11)?, get_f64(pairs, 21)?];
    let layer = layer_name(pairs);
    Some(Entity2D::Line { start, end, layer })
}

fn parse_circle(pairs: &[&DxfPair]) -> Option<Entity2D> {
    let center = [get_f64(pairs, 10)?, get_f64(pairs, 20)?];
    let radius = get_f64(pairs, 40)?;
    let layer = layer_name(pairs);
    Some(Entity2D::Circle {
        center,
        radius,
        layer,
    })
}

fn parse_arc(pairs: &[&DxfPair]) -> Option<Entity2D> {
    let center = [get_f64(pairs, 10)?, get_f64(pairs, 20)?];
    let radius = get_f64(pairs, 40)?;
    let start_angle = get_f64(pairs, 50).unwrap_or(0.0);
    let end_angle = get_f64(pairs, 51).unwrap_or(360.0);
    let layer = layer_name(pairs);
    Some(Entity2D::Arc {
        center,
        radius,
        start_angle,
        end_angle,
        layer,
    })
}

fn parse_lwpolyline(pairs: &[&DxfPair]) -> Option<Entity2D> {
    let closed = get_i32(pairs, 70).is_some_and(|f| f & 1 != 0);
    let layer = layer_name(pairs);

    // LWPOLYLINE has multiple 10/20/42 groups for each vertex.
    let mut vertices = Vec::new();
    let mut i = 0;
    while i < pairs.len() {
        if pairs[i].code == 10 {
            let x: f64 = pairs[i].value.parse().ok()?;
            let mut y = 0.0;
            let mut bulge = 0.0;
            // Look ahead for 20 and 42 at the same vertex position.
            for p in &pairs[(i + 1)..pairs.len().min(i + 4)] {
                if p.code == 20 {
                    y = p.value.parse().ok()?;
                }
                if p.code == 42 {
                    bulge = p.value.parse().ok()?;
                }
                if p.code == 10 {
                    break; // Next vertex starts.
                }
            }
            vertices.push(PolylineVertex {
                point: [x, y],
                bulge,
            });
        }
        i += 1;
    }

    if vertices.is_empty() {
        return None;
    }

    Some(Entity2D::Polyline {
        vertices,
        closed,
        layer,
    })
}

fn parse_text(pairs: &[&DxfPair]) -> Option<Entity2D> {
    let position = [get_f64(pairs, 10)?, get_f64(pairs, 20)?];
    let content = get_str(pairs, 1).unwrap_or("").to_string();
    let height = get_f64(pairs, 40).unwrap_or(1.0);
    let rotation = get_f64(pairs, 50).unwrap_or(0.0);
    let layer = layer_name(pairs);
    Some(Entity2D::Text {
        position,
        content,
        height,
        rotation,
        layer,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair(code: i32, value: &str) -> DxfPair {
        DxfPair {
            code,
            value: value.to_string(),
        }
    }

    #[test]
    fn parse_line_entity() {
        let pairs = vec![
            pair(8, "walls"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(11, "10.0"),
            pair(21, "5.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_line(&refs).unwrap();
        match entity {
            Entity2D::Line { start, end, layer } => {
                assert_eq!(start, [0.0, 0.0]);
                assert_eq!(end, [10.0, 5.0]);
                assert_eq!(layer, "walls");
            }
            _ => panic!("expected Line"),
        }
    }

    #[test]
    fn parse_circle_entity() {
        let pairs = vec![
            pair(8, "0"),
            pair(10, "5.0"),
            pair(20, "5.0"),
            pair(40, "3.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_circle(&refs).unwrap();
        match entity {
            Entity2D::Circle {
                center,
                radius,
                layer,
            } => {
                assert_eq!(center, [5.0, 5.0]);
                assert_eq!(radius, 3.0);
                assert_eq!(layer, "0");
            }
            _ => panic!("expected Circle"),
        }
    }

    #[test]
    fn parse_arc_entity() {
        let pairs = vec![
            pair(8, "0"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(40, "5.0"),
            pair(50, "0.0"),
            pair(51, "90.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_arc(&refs).unwrap();
        match entity {
            Entity2D::Arc {
                center,
                radius,
                start_angle,
                end_angle,
                ..
            } => {
                assert_eq!(center, [0.0, 0.0]);
                assert_eq!(radius, 5.0);
                assert_eq!(start_angle, 0.0);
                assert_eq!(end_angle, 90.0);
            }
            _ => panic!("expected Arc"),
        }
    }

    #[test]
    fn parse_lwpolyline_straight() {
        let pairs = vec![
            pair(8, "0"),
            pair(70, "0"),
            pair(90, "3"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(10, "1.0"),
            pair(20, "0.0"),
            pair(10, "1.0"),
            pair(20, "1.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_lwpolyline(&refs).unwrap();
        match entity {
            Entity2D::Polyline {
                vertices, closed, ..
            } => {
                assert_eq!(vertices.len(), 3);
                assert!(!closed);
                assert_eq!(vertices[0].point, [0.0, 0.0]);
                assert_eq!(vertices[1].point, [1.0, 0.0]);
                assert_eq!(vertices[2].point, [1.0, 1.0]);
            }
            _ => panic!("expected Polyline"),
        }
    }

    #[test]
    fn parse_lwpolyline_closed() {
        let pairs = vec![
            pair(8, "0"),
            pair(70, "1"),
            pair(90, "2"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(10, "1.0"),
            pair(20, "1.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_lwpolyline(&refs).unwrap();
        match entity {
            Entity2D::Polyline { closed, .. } => assert!(closed),
            _ => panic!("expected Polyline"),
        }
    }

    #[test]
    fn parse_text_entity() {
        let pairs = vec![
            pair(8, "text"),
            pair(10, "10.0"),
            pair(20, "20.0"),
            pair(1, "Hello World"),
            pair(40, "2.5"),
            pair(50, "45.0"),
        ];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        let entity = parse_text(&refs).unwrap();
        match entity {
            Entity2D::Text {
                position,
                content,
                height,
                rotation,
                layer,
            } => {
                assert_eq!(position, [10.0, 20.0]);
                assert_eq!(content, "Hello World");
                assert_eq!(height, 2.5);
                assert_eq!(rotation, 45.0);
                assert_eq!(layer, "text");
            }
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn parse_unknown_entity_returns_none() {
        let pairs = vec![pair(8, "0")];
        let refs: Vec<&DxfPair> = pairs.iter().collect();
        assert!(parse_single_entity("HATCH", &refs).is_none());
    }
}
