//! Binary IO helpers — little-endian serialization primitives.

use std::io::{Read, Write};

pub(crate) fn write_u32(w: &mut impl Write, v: u32) -> std::io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

pub(crate) fn write_u64(w: &mut impl Write, v: u64) -> std::io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

pub(crate) fn write_u8(w: &mut impl Write, v: u8) -> std::io::Result<()> {
    w.write_all(&[v])
}

pub(crate) fn write_u16(w: &mut impl Write, v: u16) -> std::io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

pub(crate) fn write_f32(w: &mut impl Write, v: f32) -> std::io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

/// Length-prefixed UTF-8 string: `u32 len` followed by raw bytes.
pub(crate) fn write_string(w: &mut impl Write, s: &str) -> std::io::Result<()> {
    let bytes = s.as_bytes();
    write_u32(w, bytes.len() as u32)?;
    w.write_all(bytes)
}

/// Count-prefixed array of fixed-size elements.
pub(crate) fn write_array_header(w: &mut impl Write, count: u32) -> std::io::Result<()> {
    write_u32(w, count)
}

pub(crate) fn write_vec3(w: &mut impl Write, v: glam::Vec3) -> std::io::Result<()> {
    write_f32(w, v.x)?;
    write_f32(w, v.y)?;
    write_f32(w, v.z)
}

// ---- Readers ----

pub(crate) fn read_u32(r: &mut impl Read) -> std::io::Result<u32> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

pub(crate) fn read_u64(r: &mut impl Read) -> std::io::Result<u64> {
    let mut buf = [0u8; 8];
    r.read_exact(&mut buf)?;
    Ok(u64::from_le_bytes(buf))
}

pub(crate) fn read_u8(r: &mut impl Read) -> std::io::Result<u8> {
    let mut buf = [0u8; 1];
    r.read_exact(&mut buf)?;
    Ok(buf[0])
}

pub(crate) fn read_u16(r: &mut impl Read) -> std::io::Result<u16> {
    let mut buf = [0u8; 2];
    r.read_exact(&mut buf)?;
    Ok(u16::from_le_bytes(buf))
}

pub(crate) fn read_f32(r: &mut impl Read) -> std::io::Result<f32> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(f32::from_le_bytes(buf))
}

pub(crate) fn read_string(r: &mut impl Read) -> std::io::Result<String> {
    let len = read_u32(r)? as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    String::from_utf8(buf).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

pub(crate) fn read_array_count(r: &mut impl Read) -> std::io::Result<u32> {
    read_u32(r)
}

pub(crate) fn read_vec3(r: &mut impl Read) -> std::io::Result<glam::Vec3> {
    let x = read_f32(r)?;
    let y = read_f32(r)?;
    let z = read_f32(r)?;
    Ok(glam::Vec3::new(x, y, z))
}

/// Fill the remaining of a buffer with zeros (for header padding).
pub(crate) fn write_padding(w: &mut impl Write, n: usize) -> std::io::Result<()> {
    let zeros = vec![0u8; n];
    w.write_all(&zeros)
}
