//! Compression interface for `.lsmc` (compressed LSM) files.
//!
//! The trait is intentionally minimal — concrete codec implementations
//! (LZ4, ZSTD) can be added later without changing the format contract.

use std::io;

/// Compression/decompression engine for LSM data sections.
///
/// Implementations must be deterministic: `decompress(compress(data)) == data`.
pub trait LsmCompressor: Send + Sync {
    /// Returns the compression method identifier byte ([`super::constants::compression`]).
    fn method_id(&self) -> u8;

    /// Compress `input` into a new byte buffer.
    fn compress(&self, input: &[u8]) -> io::Result<Vec<u8>>;

    /// Decompress `input` (previously produced by `compress`) into a new byte buffer.
    fn decompress(&self, input: &[u8]) -> io::Result<Vec<u8>>;
}

/// Pass-through compressor (no compression).
///
/// Used as the default when no codec is specified.  Each `.lsmc` section
/// header records the method id so readers can select the right decompressor.
pub struct NoCompression;

impl LsmCompressor for NoCompression {
    fn method_id(&self) -> u8 {
        super::constants::compression::NONE
    }

    fn compress(&self, input: &[u8]) -> io::Result<Vec<u8>> {
        Ok(input.to_vec())
    }

    fn decompress(&self, input: &[u8]) -> io::Result<Vec<u8>> {
        Ok(input.to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_compression_round_trip() {
        let c = NoCompression;
        assert_eq!(c.method_id(), 0);
        let data = b"hello lsm compressed data";
        let compressed = c.compress(data).unwrap();
        let decompressed = c.decompress(&compressed).unwrap();
        assert_eq!(decompressed, data);
    }
}
