//! IGES/IGS file format parser for MMForge.
//!
//! When the `occt` feature is enabled, parsing delegates to OCCT's
//! `IGESCAFControl_Reader` via [`mmforge_geometry::occt::iges_reader`].
//! Without OCCT, `parse()` returns an error indicating the feature
//! is not available.

pub mod detect;
pub mod parser;

pub use parser::{IgesParser, parse_iges_with_tessellation};
