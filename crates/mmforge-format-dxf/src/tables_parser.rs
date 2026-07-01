//! DXF TABLES section parser.
//!
//! Extracts LAYER table entries from the TABLES section.
//! Each LAYER entry has group code 2 (name), 62 (color index), and
//! 70 (flags — bit 1 = frozen).

use mmforge_core::drawing::Layer;

use crate::tokenizer::DxfPair;

/// Parse LAYER entries from the TABLES section pairs.
pub fn parse_layers(pairs: &[DxfPair]) -> Vec<Layer> {
    let mut layers = Vec::new();
    let mut in_layer_table = false;
    let mut current_name: Option<String> = None;
    let mut current_color: i16 = 7;
    let mut current_flags: i32 = 0;

    let mut i = 0;
    while i < pairs.len() {
        let pair = &pairs[i];

        // Detect TABLE start.
        if pair.code == 0 && pair.value == "TABLE"
            && i + 1 < pairs.len() && pairs[i + 1].code == 2 && pairs[i + 1].value == "LAYER" {
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
                    });
                }
                current_color = 7;
                current_flags = 0;
                i += 1;
                continue;
            }

            match pair.code {
                2 => current_name = Some(pair.value.clone()),
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
        });
    }

    layers
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
}
