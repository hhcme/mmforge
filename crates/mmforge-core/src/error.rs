//! Unified error and result types for MMForge.

/// Convenience alias used across all MMForge crates.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Top-level error enum for MMForge operations.
///
/// Each variant targets a failure domain. Downstream crates can convert
/// their own errors into `Error` via `From` impls or `map_err`.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// I/O failure (file not found, permission denied, …).
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// A format parser detected an unsupported or corrupt file.
    #[error("parse error in {format}: {message}")]
    Parse {
        format: &'static str,
        message: String,
    },

    /// A referenced entity (node, geometry, material) does not exist.
    #[error("invalid reference: {message}")]
    InvalidReference { message: String },

    /// Geometry or tessellation failure.
    #[error("geometry error: {message}")]
    Geometry { message: String },

    /// The operation was cancelled by the user.
    #[error("operation cancelled")]
    Cancelled,

    /// Generic catch-all for early prototyping; should shrink over time.
    #[error("{message}")]
    Other { message: String },
}

impl Error {
    /// Helper to build a parse error quickly.
    pub fn parse(format: &'static str, message: impl Into<String>) -> Self {
        Self::Parse {
            format,
            message: message.into(),
        }
    }

    /// Helper to build a geometry error quickly.
    pub fn geometry(message: impl Into<String>) -> Self {
        Self::Geometry {
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_error_display() {
        let err = Error::parse("STEP", "unexpected entity type");
        let s = err.to_string();
        assert!(s.contains("STEP"));
        assert!(s.contains("unexpected entity type"));
    }

    #[test]
    fn io_error_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "gone");
        let err: Error = io_err.into();
        assert!(err.to_string().contains("I/O error"));
    }
}
