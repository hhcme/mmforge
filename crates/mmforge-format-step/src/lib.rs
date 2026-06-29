//! STEP file parser for MMForge.
//!
//! This crate implements [`FormatParser`] for ISO 10303-21 (STEP) files.
//!
//! # Architecture
//!
//! - Format detection reads the file header for the `ISO-10303-21;` magic.
//! - Parsing delegates to the OCCT `STEPControl_Reader` via
//!   [`mmforge_geometry::occt`].
//! - The `occt` feature must be enabled for actual parsing.  Without it,
//!   `detect()` still works but `parse()` returns an error.
//!
//! # Safety
//!
//! All OCCT FFI is confined to `mmforge-geometry::occt`.  This crate
//! never touches raw C++ pointers.

pub mod detect;
pub mod parser;

pub use parser::StepParser;
