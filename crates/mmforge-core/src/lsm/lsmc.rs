//! `.lsmc` compressed LSM format — writer and reader.
//!
//! File layout (24-byte header + compressed payload):
//!
//! ```text
//! ┌──────────────────────────────┐
//! │ Magic: "LSMC" (4 bytes)      │
//! │ Version: u16 (1)             │
//! │ Flags: u16 (0)               │
//! │ Compression method: u8        │  1 = zstd
//! │ Reserved: [u8; 7]            │
//! │ Uncompressed size: u64       │
//! │ Compressed payload: [u8; N]  │
//! └──────────────────────────────┘
//! ```
//!
//! The payload is a complete `.lsm` v1 byte stream.  Decompressing it
//! yields a buffer that can be passed directly to [`super::reader::read_lsm`].

use std::io::{Read, Write};

/// Magic bytes: "LSMC" (4 bytes).
pub const MAGIC: [u8; 4] = *b"LSMC";

/// Current schema version for `.lsmc`.
pub const VERSION: u16 = 1;

/// Header size in bytes.
pub const HEADER_SIZE: usize = 24;

/// Compression method identifiers.
pub mod method {
    pub const ZSTD: u8 = 1;
}

/// Write an `LsmModel` as compressed `.lsmc`.
pub fn write_lsmc(model: &crate::model::LsmModel, w: &mut impl Write) -> std::io::Result<u64> {
    let mut lsm_buf = Vec::new();
    super::writer::write_lsm(model, &mut std::io::Cursor::new(&mut lsm_buf))?;

    let uncompressed_size = lsm_buf.len() as u64;
    let compressed = zstd::encode_all(&lsm_buf[..], 0).map_err(std::io::Error::other)?;

    // Header
    w.write_all(&MAGIC)?;
    w.write_all(&VERSION.to_le_bytes())?;
    w.write_all(&0u16.to_le_bytes())?; // flags
    w.write_all(&[method::ZSTD])?;
    w.write_all(&[0u8; 7])?; // reserved
    w.write_all(&uncompressed_size.to_le_bytes())?;
    w.write_all(&compressed)?;

    Ok(HEADER_SIZE as u64 + compressed.len() as u64)
}

/// Error type for `.lsmc` read operations.
#[derive(Debug)]
pub enum ReadError {
    Io(std::io::Error),
    BadMagic { found: [u8; 4] },
    BadVersion { found: u16 },
    UnknownMethod { method: u8 },
    SizeMismatch { expected: u64, got: u64 },
    DecompressError(String),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::Io(e) => write!(f, "I/O error: {e}"),
            ReadError::BadMagic { found } => {
                write!(f, "bad lsmc magic: {found:02X?} (expected {:02X?})", MAGIC)
            }
            ReadError::BadVersion { found } => {
                write!(f, "unsupported lsmc version {found}")
            }
            ReadError::UnknownMethod { method } => {
                write!(f, "unknown compression method {method}")
            }
            ReadError::SizeMismatch { expected, got } => {
                write!(
                    f,
                    "uncompressed size mismatch: expected {expected}, got {got}"
                )
            }
            ReadError::DecompressError(e) => write!(f, "decompression error: {e}"),
        }
    }
}

impl std::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ReadError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for ReadError {
    fn from(e: std::io::Error) -> Self {
        ReadError::Io(e)
    }
}

/// Result alias.
pub type Result<T> = std::result::Result<T, ReadError>;

/// Read a compressed `.lsmc` file and return the decompressed `.lsm` bytes.
///
/// The returned `Vec<u8>` can be passed to [`super::reader::read_lsm`].
pub fn read_lsmc_decompressed(r: &mut impl Read) -> Result<Vec<u8>> {
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(ReadError::BadMagic { found: magic });
    }
    let mut ver = [0u8; 2];
    r.read_exact(&mut ver)?;
    let version = u16::from_le_bytes(ver);
    if version != VERSION {
        return Err(ReadError::BadVersion { found: version });
    }
    let mut flags_buf = [0u8; 2];
    r.read_exact(&mut flags_buf)?;
    let _flags = u16::from_le_bytes(flags_buf);

    let mut method_buf = [0u8; 1];
    r.read_exact(&mut method_buf)?;
    let method = method_buf[0];
    if method != method::ZSTD {
        return Err(ReadError::UnknownMethod { method });
    }

    let mut reserved = [0u8; 7];
    r.read_exact(&mut reserved)?;

    let mut size_buf = [0u8; 8];
    r.read_exact(&mut size_buf)?;
    let expected_size = u64::from_le_bytes(size_buf);
    if expected_size > 1024 * 1024 * 1024 {
        return Err(ReadError::DecompressError(format!(
            "implausible uncompressed size {expected_size}"
        )));
    }

    // Read remaining bytes as compressed payload.
    let mut compressed = Vec::new();
    r.read_to_end(&mut compressed)?;

    let decompressed =
        zstd::decode_all(&compressed[..]).map_err(|e| ReadError::DecompressError(e.to_string()))?;

    let actual_size = decompressed.len() as u64;
    if actual_size != expected_size {
        return Err(ReadError::SizeMismatch {
            expected: expected_size,
            got: actual_size,
        });
    }

    Ok(decompressed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ModelBuilder;
    use std::io::Cursor;

    fn sample_written_lsmc() -> Vec<u8> {
        let mut b = ModelBuilder::new("STL");
        let root = b.add_root("Root");
        let gid = b.add_mesh(
            vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            vec![[0.0, 0.0, 1.0]; 3],
            vec![0, 1, 2],
        );
        b.add_child(root, "Part", Some(gid), None);
        let model = b.with_units("mm").build();
        let mut buf = Vec::new();
        write_lsmc(&model, &mut buf).unwrap();
        buf
    }

    #[test]
    fn round_trip_compressed() {
        let data = sample_written_lsmc();
        let decompressed = read_lsmc_decompressed(&mut Cursor::new(&data)).unwrap();
        let model = crate::lsm::read_lsm(&mut Cursor::new(&decompressed)).unwrap();
        assert_eq!(model.header.source_format, "STL");
        assert_eq!(model.total_triangle_count(), 1);
        assert_eq!(model.scene.nodes.len(), 2);
    }

    #[test]
    fn bad_magic_rejected() {
        let err = read_lsmc_decompressed(&mut Cursor::new(b"XXXX")).unwrap_err();
        assert!(err.to_string().contains("bad lsmc magic"));
    }

    #[test]
    fn unknown_method_rejected() {
        let mut buf = vec![0u8; 64];
        buf[0..4].copy_from_slice(b"LSMC");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8] = 99; // unknown method
        let err = read_lsmc_decompressed(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("unknown compression method"));
    }

    #[test]
    fn truncated_payload_error() {
        let mut buf = vec![0u8; 32];
        buf[0..4].copy_from_slice(b"LSMC");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8] = 1; // zstd
        buf[16..24].copy_from_slice(&100u64.to_le_bytes()); // expect 100 bytes decompressed
        let err = read_lsmc_decompressed(&mut Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("decompression error")
                || err.to_string().contains("size mismatch"),
            "got: {err}"
        );
    }

    #[test]
    fn size_mismatch_error() {
        let data = sample_written_lsmc();
        // Corrupt the uncompressed_size field.
        let mut buf = data.clone();
        buf[16..24].copy_from_slice(&(data.len() as u64 + 999).to_le_bytes());
        let err = read_lsmc_decompressed(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("size mismatch"), "got: {err}");
    }

    #[test]
    fn compressed_smaller_than_uncompressed() {
        let data = sample_written_lsmc();
        let lsm_size = u64::from_le_bytes(data[16..24].try_into().unwrap());
        let compressed_size = (data.len() - HEADER_SIZE) as u64;
        assert!(
            compressed_size <= lsm_size + 100,
            "zstd should not expand significantly for tiny payload"
        );
    }
}
