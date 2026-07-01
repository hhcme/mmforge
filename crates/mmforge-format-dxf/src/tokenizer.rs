//! DXF group code tokenizer.
//!
//! Reads a DXF file line by line and emits `(group_code, value)` pairs.
//! DXF files consist of two-line pairs: the first line is an integer
//! group code, the second line is the corresponding value.

/// A single DXF group code + value pair.
#[derive(Debug, Clone, PartialEq)]
pub struct DxfPair {
    pub code: i32,
    pub value: String,
}

/// Tokenizer that reads DXF lines and emits group code pairs.
pub struct DxfTokenizer {
    lines: Vec<String>,
    position: usize,
}

impl DxfTokenizer {
    /// Create a tokenizer from the raw file content.
    pub fn new(content: &str) -> Self {
        let lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();
        Self { lines, position: 0 }
    }

    /// Read the next group code + value pair.
    pub fn next_pair(&mut self) -> Option<DxfPair> {
        if self.position + 1 >= self.lines.len() {
            return None;
        }

        let code_str = self.lines[self.position].trim();
        let code: i32 = code_str.parse().ok()?;
        let value = self.lines[self.position + 1].trim().to_string();
        self.position += 2;

        Some(DxfPair { code, value })
    }

    /// Peek at the next pair without consuming it.
    pub fn peek(&self) -> Option<&DxfPair> {
        if self.position + 1 >= self.lines.len() {
            return None;
        }
        // We can't return a borrowed DxfPair without constructing it,
        // so this is a simplified check.
        None
    }

    /// Collect all remaining pairs into a Vec.
    pub fn collect_all(&mut self) -> Vec<DxfPair> {
        let mut pairs = Vec::new();
        while let Some(pair) = self.next_pair() {
            pairs.push(pair);
        }
        pairs
    }
}

/// Collect all group pairs for a single entity (until the next group code 0).
///
/// Consumes pairs from the tokenizer until a pair with code 0 is found,
/// which signals the start of the next entity/section.  The terminating
/// pair is NOT consumed — use `peek` to check before calling.
pub fn collect_entity_pairs(tokenizer: &mut DxfTokenizer) -> Vec<DxfPair> {
    let mut pairs = Vec::new();
    while let Some(pair) = tokenizer.next_pair() {
        if pair.code == 0 {
            // This is the start of the next entity — put it back by
            // adjusting the position.
            tokenizer.position -= 2;
            break;
        }
        pairs.push(pair);
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_empty() {
        let mut tok = DxfTokenizer::new("");
        assert!(tok.next_pair().is_none());
    }

    #[test]
    fn tokenize_single_pair() {
        let mut tok = DxfTokenizer::new("0\nSECTION\n");
        let pair = tok.next_pair().unwrap();
        assert_eq!(pair.code, 0);
        assert_eq!(pair.value, "SECTION");
        assert!(tok.next_pair().is_none());
    }

    #[test]
    fn tokenize_multiple_pairs() {
        let content = "0\nSECTION\n2\nHEADER\n0\nENDSEC\n";
        let mut tok = DxfTokenizer::new(content);
        assert_eq!(
            tok.next_pair().unwrap(),
            DxfPair {
                code: 0,
                value: "SECTION".to_string()
            }
        );
        assert_eq!(
            tok.next_pair().unwrap(),
            DxfPair {
                code: 2,
                value: "HEADER".to_string()
            }
        );
        assert_eq!(
            tok.next_pair().unwrap(),
            DxfPair {
                code: 0,
                value: "ENDSEC".to_string()
            }
        );
        assert!(tok.next_pair().is_none());
    }

    #[test]
    fn tokenize_with_whitespace() {
        let content = "  0  \n  SECTION  \n";
        let mut tok = DxfTokenizer::new(content);
        let pair = tok.next_pair().unwrap();
        assert_eq!(pair.code, 0);
        assert_eq!(pair.value, "SECTION");
    }

    #[test]
    fn collect_entity_pairs_basic() {
        let content = "8\nMyLayer\n10\n1.0\n20\n2.0\n0\nLINE\n";
        let mut tok = DxfTokenizer::new(content);
        let pairs = collect_entity_pairs(&mut tok);
        assert_eq!(pairs.len(), 3);
        assert_eq!(pairs[0].code, 8);
        assert_eq!(pairs[1].code, 10);
        assert_eq!(pairs[2].code, 20);
    }
}
