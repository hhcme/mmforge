//! Format-agnostic parser trait.

use crate::error::Result;
use crate::model::ParseOutput;
use std::path::Path;

/// Describes the confidence of a format detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DetectionConfidence {
    /// Strong magic bytes match — very likely the correct format.
    High,
    /// Weak heuristic match — needs parser confirmation.
    Medium,
    /// Only file-extension / metadata hint.
    Low,
}

/// Result of a format detection probe.
#[derive(Debug, Clone)]
pub struct DetectionResult {
    pub format_tag: &'static str,
    pub confidence: DetectionConfidence,
}

/// Trait implemented by every format parser.
///
/// The parser receives a file path or byte stream and returns a
/// [`ParseOutput`] containing the LSM runtime model, warnings, and stats.
pub trait FormatParser: Send + Sync {
    /// Human-readable format name (e.g. `"STEP"`, `"glTF"`, `"DXF"`).
    fn format_tag(&self) -> &'static str;

    /// Probe the first few KB of a file to estimate whether this parser
    /// can handle it.  Used by the format-detection pipeline.
    fn detect(&self, header: &[u8], path: &Path) -> Option<DetectionResult>;

    /// Full parse.  The implementation must:
    ///
    /// * Never panic on malformed input.
    /// * Return `Err` for fatal errors.
    /// * Collect recoverable issues in `ParseOutput::warnings`.
    fn parse(&self, path: &Path) -> Result<ParseOutput>;

    /// Whether this parser can handle the given path based on extension
    /// (quick pre-filter before reading bytes).
    fn supports_extension(&self, ext: &str) -> bool;
}
