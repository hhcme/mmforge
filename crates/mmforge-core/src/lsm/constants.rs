//! LSM binary file format v1 — constants, magic, section types.

/// Magic bytes at the start of every `.lsm` file: "LSMD" (4 bytes).
pub const MAGIC: [u8; 4] = *b"LSMD";

/// Current schema version.
pub const SCHEMA_VERSION: u16 = 1;

/// Size of the file header in bytes.
pub const FILE_HEADER_SIZE: usize = 64;

/// Size of each TOC entry in bytes.
pub const TOC_ENTRY_SIZE: usize = 20; // section_type: u32 + offset: u64 + length: u64

/// Section type identifiers.
///
/// Registered types ≤ 0x0F are core (must be understood by all readers).
/// Types ≥ 0x10 are extensions (readers MUST skip unknown entries).
pub mod section {
    pub const HEADER: u32 = 0x01;
    pub const SCENE_TREE: u32 = 0x02;
    pub const GEOMETRY: u32 = 0x03;
    pub const MATERIALS: u32 = 0x04;
    pub const TEXTURES: u32 = 0x05;
    pub const METADATA: u32 = 0x06;

    /// Maximum known core section type.
    pub const CORE_MAX: u32 = 0x0F;

    /// Sections ≥ this value are extensions (annotations, PMI, …).
    pub const EXT_BASE: u32 = 0x10;
}

/// Compression method identifiers for `.lsmc`.
pub mod compression {
    pub const NONE: u8 = 0;
    pub const ZSTD: u8 = 1;
    pub const LZ4: u8 = 2;
}

/// Source format identifiers.
pub mod source_format {
    pub const UNKNOWN: u32 = 0;
    pub const STEP: u32 = 1;
    pub const IGES: u32 = 2;
    pub const STL: u32 = 3;
    pub const GLTF: u32 = 4;
    pub const DXF: u32 = 5;
}

/// Feature flags (bitmask in the file header).
pub mod feature_flags {
    /// No flags set.
    pub const NONE: u16 = 0;
    /// File contains compressed sections (`.lsmc`).
    pub const COMPRESSED: u16 = 0x0001;
    /// Geometry section uses double-precision floats.
    pub const DOUBLE_PRECISION: u16 = 0x0002;
}
