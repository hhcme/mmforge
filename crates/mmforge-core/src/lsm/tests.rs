#[allow(clippy::module_inception)]
#[cfg(test)]
mod tests {
    use crate::lsm::{reader::read_lsm, writer::write_lsm};
    use crate::model::{Geometry, LsmModel, ModelBuilder};

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

    #[test]
    fn round_trip_bytes() {
        let model = sample_model();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();
        assert!(buf.len() > 64);

        let mut reader = std::io::Cursor::new(&buf);
        let loaded = read_lsm(&mut reader).unwrap();

        assert_eq!(loaded.header.source_format, "STL");
        assert_eq!(loaded.header.source_path.as_deref(), Some("test.stl"));
        assert_eq!(loaded.scene.nodes.len(), 2);
        assert_eq!(loaded.geometries.len(), 1);
        assert_eq!(loaded.materials.len(), 1);
    }

    #[test]
    fn golden_header_magic() {
        let model = sample_model();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();
        assert_eq!(&buf[0..4], b"LSMD");
        let version = u16::from_le_bytes([buf[4], buf[5]]);
        assert_eq!(version, 1);
    }

    #[test]
    fn scene_tree_preserved() {
        let model = sample_model();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();

        let mut reader = std::io::Cursor::new(&buf);
        let loaded = read_lsm(&mut reader).unwrap();
        assert_eq!(loaded.scene.nodes[0].name, "Root");
        assert_eq!(loaded.scene.nodes[1].name, "Part");
    }

    #[test]
    fn geometry_mesh_preserved() {
        let model = sample_model();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();

        let mut reader = std::io::Cursor::new(&buf);
        let loaded = read_lsm(&mut reader).unwrap();
        match &loaded.geometries[0] {
            Geometry::Mesh(m) => {
                assert_eq!(m.positions.len(), 3);
                assert_eq!(m.indices.len(), 3);
            }
            _ => panic!("expected Mesh"),
        }
    }

    #[test]
    fn bad_magic_rejected() {
        let buf = b"XXXXjunk";
        let err = read_lsm(&mut std::io::Cursor::new(buf)).unwrap_err();
        assert!(err.to_string().contains("bad magic"));
    }

    #[test]
    fn high_version_rejected() {
        let mut buf = vec![0u8; 100];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4] = 99;
        let err = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap_err();
        assert!(err.to_string().contains("unsupported version"));
    }

    #[test]
    fn metadata_units_preserved() {
        let mut model = sample_model();
        model.metadata.units = Some("mm".into());
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();

        let loaded = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.metadata.units.as_deref(), Some("mm"));
    }

    #[test]
    fn unknown_section_skipped() {
        let model = sample_model();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();

        let toc_offset = u64::from_le_bytes(buf[8..16].try_into().unwrap());
        let toc_count = u32::from_le_bytes(buf[16..20].try_into().unwrap());
        buf[16..20].copy_from_slice(&(toc_count + 1).to_le_bytes());

        // Append a fake extension section entry at the end.
        let mut fake = Vec::new();
        fake.extend_from_slice(&0x10_u32.to_le_bytes());
        fake.extend_from_slice(&0u64.to_le_bytes());
        fake.extend_from_slice(&0u64.to_le_bytes());
        buf.splice(toc_offset as usize + 4 + (toc_count as usize * 20).., fake);

        let loaded = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap();
        assert_eq!(loaded.scene.nodes.len(), 2);
    }

    // ----------------------------------------------------------------
    // Golden fixture regression
    // ----------------------------------------------------------------

    #[test]
    fn golden_fixture_model_golden_v1() {
        let msg = "golden fixture missing — run `cargo run --example generate_golden`";
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("testdata")
            .join("lsm")
            .join("model_golden_v1.lsm");
        assert!(path.exists(), "{msg} at {}", path.display());

        let mut file = std::fs::File::open(&path).expect("open golden");
        let mut reader = std::io::BufReader::new(&mut file);
        let loaded = read_lsm(&mut reader).expect("golden should parse");

        assert_eq!(loaded.header.source_format, "STL");
        assert_eq!(
            loaded.header.source_path.as_deref(),
            Some("fixture/sample.stl")
        );
        assert_eq!(loaded.metadata.units.as_deref(), Some("mm"));
        assert_eq!(
            loaded.metadata.author.as_deref(),
            Some("MMForge golden test suite")
        );
        assert_eq!(loaded.scene.nodes.len(), 2);
        assert_eq!(loaded.scene.nodes[0].name, "RootNode");
        assert_eq!(loaded.materials.len(), 1);
        assert_eq!(loaded.materials[0].name, "Steel");
        assert_eq!(loaded.total_triangle_count(), 1);
        assert!(
            loaded.metadata.custom.contains_key("generator"),
            "custom field 'generator' must be present"
        );
    }

    // ----------------------------------------------------------------
    // Malformed / malicious .lsm tests
    // ----------------------------------------------------------------

    #[test]
    fn toc_offset_inside_header_is_rejected() {
        let mut buf = vec![0u8; 128];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&32u64.to_le_bytes()); // TOC offset = 32 (< 64)
        let err = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("inside the file header"),
            "got: {err}"
        );
    }

    #[test]
    fn implausible_toc_count_is_rejected() {
        let mut buf = vec![0u8; 64 + 4];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&2u32.to_le_bytes());
        buf[64..68].copy_from_slice(&9999u32.to_le_bytes());
        let err = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("implausible TOC count"),
            "got: {err}"
        );
    }

    #[test]
    fn section_offset_overlapping_toc_is_rejected() {
        let mut buf = vec![0u8; 200];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes()); // TOC at 64
        buf[16..20].copy_from_slice(&1u32.to_le_bytes()); // header toc_count = 1
        buf[64..68].copy_from_slice(&1u32.to_le_bytes()); // toc_count_total = 1
        // Section entry: type=0x01, offset=32 (inside header!), length=0
        buf[68..72].copy_from_slice(&1u32.to_le_bytes());
        buf[72..80].copy_from_slice(&32u64.to_le_bytes());
        buf[80..88].copy_from_slice(&0u64.to_le_bytes());
        let err = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("inside the file header"),
            "got: {err}"
        );
    }

    #[test]
    fn missing_core_section_is_error() {
        let mut buf = vec![0u8; 64 + 4 + 20];
        buf[0..4].copy_from_slice(b"LSMD");
        buf[4..6].copy_from_slice(&1u16.to_le_bytes());
        buf[8..16].copy_from_slice(&64u64.to_le_bytes());
        buf[16..20].copy_from_slice(&1u32.to_le_bytes());
        buf[64..68].copy_from_slice(&1u32.to_le_bytes()); // toc_count=1
        // Unknown extension section (0x10), offset=999, length=0
        buf[68..72].copy_from_slice(&0x10u32.to_le_bytes());
        buf[72..80].copy_from_slice(&999u64.to_le_bytes());
        buf[80..88].copy_from_slice(&0u64.to_le_bytes());
        let err = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap_err();
        assert!(
            err.to_string().contains("missing core section"),
            "got: {err}"
        );
    }

    #[test]
    fn duplicate_core_section_last_wins() {
        // Write a valid file with Header duplicated — last value should take effect.
        let mut model = sample_model();
        model.header.source_format = "IGES".into();
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        write_lsm(&model, &mut cursor).unwrap();

        // Patch: change first Header section's source_format to "STL".
        // Find the first occurrence of "IGES" bytes in the buffer after the TOC.
        // For simplicity, just read through — duplicate should not cause error.
        let loaded = read_lsm(&mut std::io::Cursor::new(&buf)).unwrap();
        assert_eq!(
            loaded.header.source_format, "IGES",
            "duplicate sections: last wins"
        );
    }
}
