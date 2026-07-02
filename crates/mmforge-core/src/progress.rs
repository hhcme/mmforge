//! Progress reporting for long-running parse/tessellation operations.

/// Describes the current stage and progress of a parse operation.
#[derive(Debug, Clone)]
pub struct ParseProgress {
    /// Human-readable stage name (e.g. "detecting", "parsing", "tessellating").
    pub stage: &'static str,
    /// Number of items processed so far.
    pub current: u32,
    /// Total number of items expected.  0 means indeterminate.
    pub total: u32,
}

impl ParseProgress {
    /// Create a new progress report for a given stage.
    pub fn new(stage: &'static str, current: u32, total: u32) -> Self {
        Self {
            stage,
            current,
            total,
        }
    }

    /// Progress as a fraction in [0.0, 1.0].  Returns 0.0 if total is 0.
    pub fn fraction(&self) -> f32 {
        if self.total == 0 {
            0.0
        } else {
            self.current as f32 / self.total as f32
        }
    }
}

/// Callback type for progress reporting.
///
/// The callback is invoked by parsers and tessellation loops to report
/// incremental progress.  Implementations must be `Send` because the
/// callback may be invoked from a worker thread.
pub type ProgressCallback = Box<dyn Fn(&ParseProgress) + Send + Sync>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_fraction() {
        let p = ParseProgress::new("parsing", 50, 100);
        assert!((p.fraction() - 0.5).abs() < 1e-6);
    }

    #[test]
    fn progress_fraction_indeterminate() {
        let p = ParseProgress::new("detecting", 0, 0);
        assert_eq!(p.fraction(), 0.0);
    }

    #[test]
    fn progress_fraction_complete() {
        let p = ParseProgress::new("done", 100, 100);
        assert!((p.fraction() - 1.0).abs() < 1e-6);
    }
}
