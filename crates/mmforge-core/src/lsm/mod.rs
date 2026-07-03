//! LSM binary file format (`.lsm` v1).
//!
//! ## File layout
//!
//! ```text
//! ┌──────────────────────────────┐
//! │ File header (64 bytes)       │  magic + version + TOC offset + flags
//! ├──────────────────────────────┤
//! │ Sections (variable length)   │  header, scene_tree, geometry, materials, metadata
//! ├──────────────────────────────┤
//! │ TOC (N × 20 bytes)          │  section_type + offset + length per entry
//! └──────────────────────────────┘
//! ```
//!
//! ## Forward compatibility
//!
//! - Unknown section types (≥ 0x10 or unrecognised in 0x01–0x0F) are silently
//!   skipped by the reader.
//! - The schema version in the file header allows a reader to reject files
//!   with a higher major version.
//!
//! ## Compression
//!
//! See [`compress::LsmCompressor`] for the pluggable interface.  Use
//! `mmf_lsm_write_compressed` / `mmf_lsm_read_compressed` when `.lsmc`
//! support is added.

mod binary;
pub mod compress;
pub mod constants;
pub mod lsmc;
pub mod reader;
#[cfg(test)]
mod tests;
pub mod writer;

pub use compress::LsmCompressor;
pub use reader::{ReadError, read_lsm};
pub use writer::write_lsm;
