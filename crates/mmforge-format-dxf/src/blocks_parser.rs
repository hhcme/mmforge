//! DXF BLOCKS section parser.
//!
//! Extracts block definitions from the BLOCKS section.  Each block
//! contains a name, base point, and a list of entities.

use mmforge_core::drawing::Block;

use crate::entity_parser::parse_entities;
use crate::tokenizer::DxfPair;

/// Parse BLOCK entries from the BLOCKS section pairs.
pub fn parse_blocks(pairs: &[DxfPair]) -> Vec<Block> {
    let mut blocks = Vec::new();
    let mut i = 0;

    while i < pairs.len() {
        // Look for BLOCK start.
        if pairs[i].code == 0 && pairs[i].value == "BLOCK" {
            i += 1;
            let mut name = String::new();
            let mut base_x = 0.0f64;
            let mut base_y = 0.0f64;
            let mut header_done = false;
            let mut block_pairs = Vec::new();

            // Collect block header fields and entity pairs until ENDBLK.
            while i < pairs.len() {
                if pairs[i].code == 0 && pairs[i].value == "ENDBLK" {
                    i += 1;
                    break;
                }
                if pairs[i].code == 0 && pairs[i].value == "BLOCK" {
                    i += 1;
                    continue;
                }

                // Header fields come before the first entity (code 0).
                if !header_done && pairs[i].code != 0 {
                    match pairs[i].code {
                        2 => name = pairs[i].value.clone(),
                        10 => base_x = pairs[i].value.parse().unwrap_or(0.0),
                        20 => base_y = pairs[i].value.parse().unwrap_or(0.0),
                        _ => {}
                    }
                } else {
                    header_done = true;
                    block_pairs.push(pairs[i].clone());
                }
                i += 1;
            }

            let entities = parse_entities(&block_pairs);

            blocks.push(Block {
                name,
                base_point: [base_x, base_y],
                entities,
            });
        } else {
            i += 1;
        }
    }

    blocks
}

#[cfg(test)]
mod tests {
    use super::*;
    use mmforge_core::drawing::Entity2D;

    fn pair(code: i32, value: &str) -> DxfPair {
        DxfPair {
            code,
            value: value.to_string(),
        }
    }

    #[test]
    fn parse_empty_blocks() {
        let blocks = parse_blocks(&[]);
        assert!(blocks.is_empty());
    }

    #[test]
    fn parse_single_block() {
        let pairs = vec![
            pair(0, "BLOCK"),
            pair(2, "DOOR"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(0, "LINE"),
            pair(8, "0"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(11, "1.0"),
            pair(21, "0.0"),
            pair(0, "ENDBLK"),
        ];
        let blocks = parse_blocks(&pairs);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].name, "DOOR");
        assert_eq!(blocks[0].base_point, [0.0, 0.0]);
        assert_eq!(blocks[0].entities.len(), 1);
        assert!(matches!(blocks[0].entities[0], Entity2D::Line { .. }));
    }

    #[test]
    fn parse_block_with_multiple_entities() {
        let pairs = vec![
            pair(0, "BLOCK"),
            pair(2, "WINDOW"),
            pair(10, "0.5"),
            pair(20, "0.5"),
            pair(0, "LINE"),
            pair(8, "0"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(11, "1.0"),
            pair(21, "0.0"),
            pair(0, "CIRCLE"),
            pair(8, "0"),
            pair(10, "0.5"),
            pair(20, "0.0"),
            pair(40, "0.25"),
            pair(0, "ENDBLK"),
        ];
        let blocks = parse_blocks(&pairs);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].name, "WINDOW");
        assert_eq!(blocks[0].base_point, [0.5, 0.5]);
        assert_eq!(blocks[0].entities.len(), 2);
    }

    #[test]
    fn parse_multiple_blocks() {
        let pairs = vec![
            pair(0, "BLOCK"),
            pair(2, "A"),
            pair(10, "0.0"),
            pair(20, "0.0"),
            pair(0, "ENDBLK"),
            pair(0, "BLOCK"),
            pair(2, "B"),
            pair(10, "1.0"),
            pair(20, "1.0"),
            pair(0, "ENDBLK"),
        ];
        let blocks = parse_blocks(&pairs);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].name, "A");
        assert_eq!(blocks[1].name, "B");
    }
}
