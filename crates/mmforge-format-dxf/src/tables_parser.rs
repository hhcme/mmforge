//! DXF TABLES section parser.
//!
//! Extracts LAYER table entries from the TABLES section.
//! Each LAYER entry has group code 2 (name), 62 (color index), and
//! 70 (flags — bit 1 = frozen).

use mmforge_core::drawing::{Layer, LineType};

use crate::tokenizer::DxfPair;

/// Parse LAYER entries from the TABLES section pairs.
pub fn parse_layers(pairs: &[DxfPair]) -> Vec<Layer> {
    let mut layers = Vec::new();
    let mut in_layer_table = false;
    let mut current_name: Option<String> = None;
    let mut current_color: i16 = 7;
    let mut current_flags: i32 = 0;
    let mut current_line_type: Option<String> = None;

    let mut i = 0;
    while i < pairs.len() {
        let pair = &pairs[i];

        // Detect TABLE start.
        if pair.code == 0
            && pair.value == "TABLE"
            && i + 1 < pairs.len()
            && pairs[i + 1].code == 2
            && pairs[i + 1].value == "LAYER"
        {
            in_layer_table = true;
            i += 2;
            continue;
        }

        // Detect TABLE end.
        if pair.code == 0 && pair.value == "ENDTAB" {
            in_layer_table = false;
            i += 1;
            continue;
        }

        if in_layer_table {
            // Detect LAYER entry start.
            if pair.code == 0 && pair.value == "LAYER" {
                // Save previous layer if any.
                if let Some(name) = current_name.take() {
                    let frozen = current_flags & 1 != 0;
                    layers.push(Layer {
                        name,
                        color_index: current_color,
                        visible: !frozen,
                        line_type: current_line_type.take(),
                    });
                }
                current_color = 7;
                current_flags = 0;
                i += 1;
                continue;
            }

            match pair.code {
                2 => current_name = Some(pair.value.clone()),
                6 => {
                    // "Continuous" is the DXF default (solid line) — treat as None.
                    if pair.value.eq_ignore_ascii_case("Continuous") {
                        current_line_type = None;
                    } else {
                        current_line_type = Some(pair.value.clone());
                    }
                }
                62 => {
                    current_color = pair.value.parse().unwrap_or(7);
                }
                70 => {
                    current_flags = pair.value.parse().unwrap_or(0);
                }
                _ => {}
            }
        }

        i += 1;
    }

    // Save last layer.
    if let Some(name) = current_name {
        let frozen = current_flags & 1 != 0;
        layers.push(Layer {
            name,
            color_index: current_color,
            visible: !frozen,
            line_type: current_line_type,
        });
    }

    layers
}

/// Parse LINETYPE entries from the TABLES section pairs.
pub fn parse_line_types(pairs: &[DxfPair]) -> Vec<LineType> {
    let mut line_types = Vec::new();
    let mut in_ltype_table = false;
    let mut in_entry = false;
    let mut current_name: Option<String> = None;
    let mut current_desc = String::new();
    let mut current_dashes: Vec<f64> = Vec::new();
    let mut current_total: f64 = 0.0;

    /// Save the current entry if it has a name.
    macro_rules! save_entry {
        () => {
            if let Some(name) = current_name.take() {
                line_types.push(LineType {
                    name,
                    description: std::mem::take(&mut current_desc),
                    dashes: std::mem::take(&mut current_dashes),
                    total_length: current_total,
                });
            }
        };
    }

    let mut i = 0;
    while i < pairs.len() {
        let pair = &pairs[i];

        if pair.code == 0
            && pair.value == "TABLE"
            && i + 1 < pairs.len()
            && pairs[i + 1].code == 2
            && pairs[i + 1].value == "LTYPE"
        {
            in_ltype_table = true;
            i += 2;
            continue;
        }

        if pair.code == 0 && pair.value == "ENDTAB" {
            // Save last entry before leaving the table.
            if in_entry {
                save_entry!();
                in_entry = false;
            }
            in_ltype_table = false;
            i += 1;
            continue;
        }

        if in_ltype_table {
            if pair.code == 0 && pair.value == "LTYPE" {
                // Save previous entry before starting a new one.
                if in_entry {
                    save_entry!();
                }
                in_entry = true;
                i += 1;
                continue;
            }

            if in_entry {
                match pair.code {
                    2 => current_name = Some(pair.value.clone()),
                    3 => current_desc = pair.value.clone(),
                    40 => current_total = pair.value.parse().unwrap_or(0.0),
                    49 => {
                        if let Ok(v) = pair.value.parse::<f64>() {
                            current_dashes.push(v);
                        }
                    }
                    _ => {}
                }
            }
        }

        i += 1;
    }

    // Save last entry if we're still inside one.
    if in_entry {
        save_entry!();
    }

    line_types
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
    fn parse_empty_tables() {
        let layers = parse_layers(&[]);
        assert!(layers.is_empty());
    }

    #[test]
    fn parse_single_layer() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LAYER"),
            pair(0, "LAYER"),
            pair(2, "walls"),
            pair(62, "1"),
            pair(70, "0"),
            pair(0, "ENDTAB"),
        ];
        let layers = parse_layers(&pairs);
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].name, "walls");
        assert_eq!(layers[0].color_index, 1);
        assert!(layers[0].visible);
        assert!(layers[0].line_type.is_none());
    }

    #[test]
    fn parse_frozen_layer() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LAYER"),
            pair(0, "LAYER"),
            pair(2, "hidden"),
            pair(62, "7"),
            pair(70, "1"),
            pair(0, "ENDTAB"),
        ];
        let layers = parse_layers(&pairs);
        assert_eq!(layers.len(), 1);
        assert!(!layers[0].visible);
    }

    #[test]
    fn parse_multiple_layers() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LAYER"),
            pair(0, "LAYER"),
            pair(2, "walls"),
            pair(62, "1"),
            pair(70, "0"),
            pair(0, "LAYER"),
            pair(2, "text"),
            pair(62, "7"),
            pair(70, "0"),
            pair(0, "LAYER"),
            pair(2, "dims"),
            pair(62, "3"),
            pair(70, "0"),
            pair(0, "ENDTAB"),
        ];
        let layers = parse_layers(&pairs);
        assert_eq!(layers.len(), 3);
        assert_eq!(layers[0].name, "walls");
        assert_eq!(layers[1].name, "text");
        assert_eq!(layers[2].name, "dims");
    }

    #[test]
    fn parse_layer_with_line_type() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LAYER"),
            pair(0, "LAYER"),
            pair(2, "dashed_layer"),
            pair(6, "DASHED"),
            pair(62, "1"),
            pair(70, "0"),
            pair(0, "ENDTAB"),
        ];
        let layers = parse_layers(&pairs);
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].name, "dashed_layer");
        assert_eq!(layers[0].line_type.as_deref(), Some("DASHED"));
    }

    #[test]
    fn ignore_non_layer_tables() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "STYLE"),
            pair(0, "STYLE"),
            pair(2, "standard"),
            pair(0, "ENDTAB"),
        ];
        let layers = parse_layers(&pairs);
        assert!(layers.is_empty());
    }

    // ---------------------------------------------------------------
    // LTYPE tests
    // ---------------------------------------------------------------

    #[test]
    fn parse_single_ltype() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LTYPE"),
            pair(0, "LTYPE"),
            pair(2, "DASHED"),
            pair(3, "Dashed __ __ __ __"),
            pair(40, "12.0"),
            pair(49, "6.0"),
            pair(49, "-6.0"),
            pair(0, "ENDTAB"),
        ];
        let ltypes = parse_line_types(&pairs);
        assert_eq!(ltypes.len(), 1);
        assert_eq!(ltypes[0].name, "DASHED");
        assert_eq!(ltypes[0].dashes, vec![6.0, -6.0]);
        assert!((ltypes[0].total_length - 12.0).abs() < 1e-10);
    }

    #[test]
    fn parse_multiple_ltypes() {
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LTYPE"),
            pair(0, "LTYPE"),
            pair(2, "DASHED"),
            pair(3, "Dashed"),
            pair(40, "12.0"),
            pair(49, "6.0"),
            pair(49, "-6.0"),
            pair(0, "LTYPE"),
            pair(2, "DASHDOT"),
            pair(3, "Dash dot"),
            pair(40, "16.0"),
            pair(49, "6.0"),
            pair(49, "-3.0"),
            pair(49, "1.0"),
            pair(49, "-3.0"),
            pair(0, "LTYPE"),
            pair(2, "Continuous"),
            pair(3, "Solid line"),
            pair(40, "0.0"),
            pair(0, "ENDTAB"),
        ];
        let ltypes = parse_line_types(&pairs);
        assert_eq!(ltypes.len(), 3);
        assert_eq!(ltypes[0].name, "DASHED");
        assert_eq!(ltypes[0].dashes, vec![6.0, -6.0]);
        assert_eq!(ltypes[1].name, "DASHDOT");
        assert_eq!(ltypes[1].dashes, vec![6.0, -3.0, 1.0, -3.0]);
        assert_eq!(ltypes[2].name, "Continuous");
        assert!(ltypes[2].dashes.is_empty());
    }

    #[test]
    fn ltype_with_dot_pattern() {
        // Zero-length dash = dot in DXF convention.
        let pairs = vec![
            pair(0, "TABLE"),
            pair(2, "LTYPE"),
            pair(0, "LTYPE"),
            pair(2, "DOTTED"),
            pair(3, "Dotted"),
            pair(40, "4.0"),
            pair(49, "0.0"),
            pair(49, "-4.0"),
            pair(0, "ENDTAB"),
        ];
        let ltypes = parse_line_types(&pairs);
        assert_eq!(ltypes.len(), 1);
        assert_eq!(ltypes[0].dashes, vec![0.0, -4.0]);
    }
}
