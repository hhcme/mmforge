//! MMForge Core — foundational types, error model, and parser traits.
//!
//! This crate is the bottom of the dependency graph. It must not depend on
//! any platform, UI, GPU, or OCCT types.

pub mod error;
pub mod ids;
pub mod math;
pub mod model;
pub mod parser;
pub mod version;

pub use error::{Error, Result};
pub use version::{VERSION, Version};
