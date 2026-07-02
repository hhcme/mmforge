//! Format-agnostic parser trait.

use crate::cancel::CancellationToken;
use crate::error::Result;
use crate::model::ParseOutput;
use crate::progress::ProgressCallback;
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

    /// Parse with progress reporting and cancellation support.
    ///
    /// The default implementation delegates to [`parse`] after checking
    /// the cancellation token once.  Parsers that support incremental
    /// progress should override this method to report progress via the
    /// callback and check the token in their inner loops.
    fn parse_with_progress(
        &self,
        path: &Path,
        progress: Option<&ProgressCallback>,
        cancel: &CancellationToken,
    ) -> Result<ParseOutput> {
        if cancel.is_cancelled() {
            return Err(crate::error::Error::Cancelled);
        }
        if let Some(cb) = progress {
            cb(&crate::progress::ParseProgress::new("parsing", 0, 0));
        }
        let result = self.parse(path);
        if let Some(cb) = progress {
            cb(&crate::progress::ParseProgress::new("parsing", 1, 1));
        }
        result
    }

    /// Whether this parser can handle the given path based on extension
    /// (quick pre-filter before reading bytes).
    fn supports_extension(&self, ext: &str) -> bool;
}
