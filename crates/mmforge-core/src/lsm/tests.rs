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
}
