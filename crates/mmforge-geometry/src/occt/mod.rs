//! OCCT (OpenCASCADE) safe wrapper module.
//!
//! All `unsafe` FFI code for interacting with the OpenCASCADE C++ library
//! is confined to this module.  Downstream crates (e.g. `mmforge-format-step`)
//! interact with OCCT exclusively through the safe public API exposed here.
//!
//! # Feature gate
//!
//! This module compiles in two modes:
//!
//! - **`occt` feature disabled** (default): All functions return errors
//!   indicating OCCT is not available.  The crate still compiles and
//!   CI runs without needing OCCT installed.
//!
//! - **`occt` feature enabled**: Functions call into the real OCCT C++
//!   library via FFI.  Requires OCCT to be installed and linkable.
//!
//! # Safety contract
//!
//! - Raw OCCT pointers (`TopoDS_Shape*`, `STEPControl_Reader*`, etc.)
//!   never escape this module.
//! - All handle wrappers implement `Drop` to free C++ resources.
//! - No `unsafe` code exists outside `occt/sys` or `occt/adapter`.

pub mod iges_reader;
pub mod shape;
pub mod step_reader;
pub mod sys;

// The adapter calls into sys extern functions which are only available
// when the occt feature is enabled.
#[cfg(feature = "occt")]
pub mod adapter;

/// Mutex to serialize OCCT tests.  OCCT is not thread-safe — concurrent
/// reader instances in the same process cause SIGABRT/SIGKILL.  Every
/// test that touches OCCT FFI must hold this lock.
#[cfg(test)]
pub(crate) static OCCT_TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Error type for OCCT operations.
#[derive(Debug, thiserror::Error)]
pub enum OcctError {
    /// OCCT is not available (feature not enabled or library not found).
    #[error("OCCT not available: {0}")]
    NotAvailable(String),

    /// OCCT returned an error during a STEP operation.
    #[error("STEP error: {0}")]
    StepError(String),

    /// OCCT shape operation failed.
    #[error("shape error: {0}")]
    ShapeError(String),

    /// I/O error reading the file.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}
