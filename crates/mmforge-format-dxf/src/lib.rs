//! DXF file format parser for MMForge.
//!
//! Parses AutoCAD DXF files (R12-R2018) into the LSM runtime model.
//! Supports LINE, CIRCLE, ARC, LWPOLYLINE, TEXT entities and the
//! LAYER table.

pub mod detect;
pub mod entity_parser;
pub mod parser;
pub mod section_parser;
pub mod tables_parser;
pub mod tokenizer;

pub use parser::{DxfParser, parse_dxf};
