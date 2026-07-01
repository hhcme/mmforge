//! DXF section parser.
//!
//! Segments a DXF file into named sections (HEADER, TABLES, BLOCKS,
//! ENTITIES, OBJECTS) based on group code 0/SECTION and 0/ENDSEC markers.

use crate::tokenizer::DxfPair;

/// A named section containing its group pairs.
#[derive(Debug, Clone)]
pub struct DxfSection {
    pub name: String,
    pub pairs: Vec<DxfPair>,
}

/// Parse a flat list of group pairs into named sections.
pub fn parse_sections(pairs: &[DxfPair]) -> Vec<DxfSection> {
    let mut sections = Vec::new();
    let mut current_name: Option<String> = None;
    let mut current_pairs = Vec::new();

    let mut i = 0;
    while i < pairs.len() {
        let pair = &pairs[i];

        if pair.code == 0 && pair.value == "SECTION" {
            // Next pair with code 2 is the section name.
            if i + 1 < pairs.len() && pairs[i + 1].code == 2 {
                current_name = Some(pairs[i + 1].value.clone());
                i += 2;
                continue;
            }
        }

        if pair.code == 0 && pair.value == "ENDSEC" {
            if let Some(name) = current_name.take() {
                sections.push(DxfSection {
                    name,
                    pairs: std::mem::take(&mut current_pairs),
                });
            }
            i += 1;
            continue;
        }

        if current_name.is_some() {
            current_pairs.push(pair.clone());
        }

        i += 1;
    }

    sections
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_empty() {
        let sections = parse_sections(&[]);
        assert!(sections.is_empty());
    }

    #[test]
    fn parse_single_section() {
        let pairs = vec![
            DxfPair {
                code: 0,
                value: "SECTION".to_string(),
            },
            DxfPair {
                code: 2,
                value: "ENTITIES".to_string(),
            },
            DxfPair {
                code: 0,
                value: "LINE".to_string(),
            },
            DxfPair {
                code: 0,
                value: "ENDSEC".to_string(),
            },
        ];
        let sections = parse_sections(&pairs);
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].name, "ENTITIES");
        assert_eq!(sections[0].pairs.len(), 1); // just the LINE pair
    }

    #[test]
    fn parse_two_sections() {
        let pairs = vec![
            DxfPair {
                code: 0,
                value: "SECTION".to_string(),
            },
            DxfPair {
                code: 2,
                value: "HEADER".to_string(),
            },
            DxfPair {
                code: 9,
                value: "$ACADVER".to_string(),
            },
            DxfPair {
                code: 0,
                value: "ENDSEC".to_string(),
            },
            DxfPair {
                code: 0,
                value: "SECTION".to_string(),
            },
            DxfPair {
                code: 2,
                value: "ENTITIES".to_string(),
            },
            DxfPair {
                code: 0,
                value: "LINE".to_string(),
            },
            DxfPair {
                code: 0,
                value: "ENDSEC".to_string(),
            },
        ];
        let sections = parse_sections(&pairs);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].name, "HEADER");
        assert_eq!(sections[1].name, "ENTITIES");
    }
}
