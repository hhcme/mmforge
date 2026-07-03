#[allow(clippy::module_inception)]
#[cfg(test)]
mod tests {
    use crate::lsm::{reader::read_lsm, writer::write_lsm};
    use crate::model::{Geometry, LsmModel, ModelBuilder};
    use std::hash::{Hash, Hasher};
    use std::io::Cursor;

    fn sample_model() -> LsmModel {
        let mut b = ModelBuilder::new("STL");
        let root = b.add_root("Root");
        let geom_id = b.add_mesh(
            vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            vec![[0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
            vec![0, 1, 2],
        );
        let mat_id = b.add_material("Steel", [0.7, 0.7, 0.7, 1.0]);
        let _child = b.add_child(root, "Part", Some(geom_id), Some(mat_id));
        let mut model = b.with_units("mm").build();
        model.header.source_path = Some("test.stl".into());
        model.metadata.author = Some("test-suite".into());
        model
            .metadata
            .custom
            .insert("engine".into(), "mmforge".into());
        model
    }

    fn golden_model() -> LsmModel {
        let mut b = ModelBuilder::new("STL");
        let root = b.add_root("RootNode");
        let geom_id = b.add_mesh(
            vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            vec![[0.0, 0.0, 1.0], [0.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
            vec![0, 1, 2],
        );
        let mat_id = b.add_material("Steel", [0.7, 0.7, 0.7, 1.0]);
        let _child = b.add_child(root, "Part_001", Some(geom_id), Some(mat_id));
        let mut model = b.with_units("mm").build();
        model.header.source_path = Some("fixture/sample.stl".into());
        model.header.parser_version = "mmforge-cli 0.1.0".into();
        model.metadata.author = Some("MMForge golden test suite".into());
        model.metadata.description = Some("Golden LSM v1 fixture for regression testing".into());
        model
            .metadata
            .custom
            .insert("generator".into(), "mmforge-golden-gen".into());
        model
    }

    fn hash_bytes(data: &[u8]) -> u64 {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        data.hash(&mut h);
        h.finish()
    }

    // ----------------------------------------------------------------
    // Round-trip
    // ----------------------------------------------------------------

    #[test]
    fn round_trip_bytes() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        assert!(buf.len() > 64);
        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.header.source_format, "STL");
        assert_eq!(loaded.scene.nodes.len(), 2);
        assert_eq!(loaded.geometries.len(), 1);
        assert_eq!(loaded.materials.len(), 1);
    }

    #[test]
    fn golden_header_magic() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        assert_eq!(&buf[0..4], b"LSMD");
    }

    #[test]
    fn scene_tree_preserved() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.scene.nodes[0].name, "Root");
        assert_eq!(loaded.scene.nodes[1].name, "Part");
    }

    #[test]
    fn geometry_mesh_preserved() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        match &loaded.geometries[0] {
            Geometry::Mesh(m) => {
                assert_eq!(m.positions.len(), 3);
                assert_eq!(m.indices.len(), 3);
            }
            _ => panic!("expected Mesh"),
        }
    }

    #[test]
    fn metadata_units_preserved() {
        let mut model = sample_model();
        model.metadata.units = Some("mm".into());
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.metadata.units.as_deref(), Some("mm"));
    }

    // ----------------------------------------------------------------
    // Golden fixture — byte-for-byte stable hash
    // ----------------------------------------------------------------

    #[test]
    fn golden_fixture_stable_binary() {
        let model = golden_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();

        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("testdata")
            .join("lsm")
            .join("model_golden_v1.lsm");
        assert!(path.exists(), "golden fixture missing");
        let committed = std::fs::read(&path).unwrap();

        let h1 = hash_bytes(&buf);
        let h2 = hash_bytes(&committed);
        assert_eq!(
            h1, h2,
            "rewritten bytes differ from committed golden fixture — binary format has changed"
        );
    }

    // ----------------------------------------------------------------
    // Error: magic / version
    // ----------------------------------------------------------------

    #[test]
    fn bad_magic_rejected() {
        let err = read_lsm(&mut Cursor::new(b"XXXX")).unwrap_err();
        assert!(err.to_string().contains("bad magic"));
    }

    #[test]
    fn high_version_rejected() {
        let mut buf = vec![0u8; 100];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4] = 99;
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("unsupported version"));
    }

    // ----------------------------------------------------------------
    // Error: TOC bounds
    // ----------------------------------------------------------------

    #[test]
    fn toc_offset_inside_header_rejected() {
        let mut buf = vec![0u8; 128];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&32u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("out of bounds"));
    }

    #[test]
    fn implausible_toc_count_rejected() {
        let mut buf = vec![0u8; 64 + 8];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&9999u32.to_le_bytes());
        buf[68..72].copy_from_slice(&0u32.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("implausible TOC count"));
    }

    #[test]
    fn section_offset_inside_header_rejected() {
        let mut buf = vec![0u8; 200];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes());
        buf[68..72].copy_from_slice(&1u32.to_le_bytes());
        buf[72..80].copy_from_slice(&32u64.to_le_bytes());
        buf[80..88].copy_from_slice(&0u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("inside the file header"));
    }

    #[test]
    fn section_offset_crossing_into_toc_rejected() {
        let mut buf = vec![0u8; 200];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes());
        // Section at offset 64 (where TOC starts) — rejected
        buf[68..72].copy_from_slice(&1u32.to_le_bytes());
        buf[72..80].copy_from_slice(&64u64.to_le_bytes());
        buf[80..88].copy_from_slice(&0u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("starts inside TOC"), "got: {err}");
    }

    #[test]
    fn section_starts_before_toc_extends_into_it_rejected() {
        // TOC at 128, section at 64 with len=80 → 64+80=144 > 128.
        let mut buf = vec![0u8; 256];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&128u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[128..132].copy_from_slice(&1u32.to_le_bytes());
        // Section 0x10 at offset 64, length 80 (extends past TOC at 128)
        buf[132..136].copy_from_slice(&0x10u32.to_le_bytes());
        buf[136..144].copy_from_slice(&64u64.to_le_bytes());
        buf[144..152].copy_from_slice(&80u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("crosses into TOC"), "got: {err}");
    }

    #[test]
    fn section_offset_plus_length_exceeds_file() {
        let mut buf = vec![0u8; 200];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes());
        // Section at offset 128, length = 99999 (exceeds file)
        buf[68..72].copy_from_slice(&1u32.to_le_bytes());
        buf[72..80].copy_from_slice(&128u64.to_le_bytes());
        buf[80..88].copy_from_slice(&99999u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("exceeds file size"), "got: {err}");
    }

    #[test]
    fn section_offset_plus_length_overflow() {
        let mut buf = vec![0u8; 300];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes());
        // offset = u64::MAX - 10, length = 20 → overflow
        buf[68..72].copy_from_slice(&1u32.to_le_bytes());
        buf[72..80].copy_from_slice(&(u64::MAX - 10).to_le_bytes());
        buf[80..88].copy_from_slice(&20u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("exceeds file size"), "got: {err}");
    }

    // ----------------------------------------------------------------
    // Duplicate core section rejection
    // ----------------------------------------------------------------

    #[test]
    fn duplicate_core_section_rejected() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();

        // Patch: change the second TOC entry's section_type to Header (0x01)
        // so there are two Header entries — should be rejected.
        let toc_offset = u64::from_le_bytes(buf[8..16].try_into().unwrap());
        let pos = toc_offset as usize + 4; // skip count
        let hdr_section_type = u32::from_le_bytes(buf[pos..pos + 4].try_into().unwrap());
        assert_eq!(hdr_section_type, 0x01); // first entry is Header
        // Second entry (pos+20) has some type; change it to Header
        buf[pos + 20..pos + 24].copy_from_slice(&0x01u32.to_le_bytes());

        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("duplicate core section"),
            "got: {err}"
        );
    }

    // ----------------------------------------------------------------
    // Unknown section / missing core
    // ----------------------------------------------------------------

    #[test]
    fn unknown_section_skipped() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();

        let toc_offset = u64::from_le_bytes(buf[8..16].try_into().unwrap());
        let toc_count = u32::from_le_bytes(buf[16..20].try_into().unwrap());
        buf[16..20].copy_from_slice(&(toc_count + 1).to_le_bytes());

        let mut fake = Vec::new();
        fake.extend_from_slice(&0x10u32.to_le_bytes());
        fake.extend_from_slice(&0u64.to_le_bytes());
        fake.extend_from_slice(&0u64.to_le_bytes());
        buf.splice(toc_offset as usize + 4 + (toc_count as usize * 20).., fake);

        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.scene.nodes.len(), 2);
    }

    #[test]
    fn missing_core_section_is_error() {
        let mut buf = vec![0u8; 256];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes());
        // Extension section at offset 128, length 0 — valid offset, but no core sections.
        buf[68..72].copy_from_slice(&0x10u32.to_le_bytes());
        buf[72..80].copy_from_slice(&128u64.to_le_bytes());
        buf[80..88].copy_from_slice(&0u64.to_le_bytes());
        let err = read_lsm(&mut Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("missing core section"));
    }

    // ----------------------------------------------------------------
    // LimitedReader defense
    // ----------------------------------------------------------------

    #[test]
    fn section_limited_reader_stops_at_boundary() {
        let model = sample_model();
        let mut buf = Vec::new();
        write_lsm(&model, &mut Cursor::new(&mut buf)).unwrap();
        // Should parse fine with correct lengths.
        let loaded = read_lsm(&mut Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.total_triangle_count(), 1);
    }
}
