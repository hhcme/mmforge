//! Cache-path benchmark over the real test fixtures (manual run only).
//!
//! Measures, per file: full parse (first-open), LSM cache serialization
//! size/time, and cache-hit load time (re-parse of the .lsm bytes).
//!
//! Run: cargo test --release -p mmforge-bridge --test cache_bench -- --ignored --nocapture
//!
//! When `MMFORGE_CACHE_OUT` is set, each file's serialized cache bytes are
//! also written to `<dir>/<file-name>.lsm` — used by
//! `macos/scripts/refresh-model-cache.sh` to pre-warm the app's ModelCache.

use std::ffi::CString;
use std::time::Instant;

use mmforge_bridge::{
    MmfByteBuffer, mmf_build_streaming_packet, mmf_bytes_free, mmf_cache_version,
    mmf_chunk_mesh_count, mmf_chunk_mesh_geometry_id, mmf_document_free, mmf_document_lsm_bytes,
    mmf_last_error, mmf_mesh_count, mmf_mesh_geometry_id, mmf_parse_file, mmf_triangle_count,
};

fn cpath(p: &str) -> CString {
    CString::new(p).unwrap()
}

fn parse_ms(path: &CString) -> (std::time::Duration, *mut mmforge_bridge::MmfDocument) {
    let t = Instant::now();
    let doc = mmf_parse_file(path.as_ptr());
    (t.elapsed(), doc)
}

#[test]
#[ignore]
fn bench_cache_path_all_fixtures() {
    // Integration tests run with cwd = crate dir; anchor via CARGO_MANIFEST_DIR.
    let root = std::env::var("MMFORGE_TESTFILES")
        .unwrap_or_else(|_| format!("{}/../../testfile", env!("CARGO_MANIFEST_DIR")));
    // Overridable via MMFORGE_BENCH_FILES="a.step;b.stl" (relative to root).
    let files: Vec<String> = match std::env::var("MMFORGE_BENCH_FILES") {
        Ok(list) => list
            .split(';')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        Err(_) => [
            "PQ-04909-A.STEP",
            "Z31R001-Q02-E001 LL腔腔体组件.STEP",
            "方盒子.step",
            "JY-LT-260401-OP10.stp",
            "躺板板.STEP",
            "赛车.step",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect(),
    };

    println!(
        "\n{:<28} {:>8} {:>9} {:>9} {:>9} {:>10} {:>10}",
        "file", "size(MB)", "parse(s)", "serial(s)", "cacheMB", "load(s)", "triangles"
    );
    println!("{}", "-".repeat(100));

    for name in &files {
        let path = format!("{root}/{name}");
        let size_mb = std::fs::metadata(&path)
            .map(|m| m.len() as f64 / 1e6)
            .unwrap_or(0.0);

        // 1. Full parse (first open).
        let (tp, doc) = parse_ms(&cpath(&path));
        if doc.is_null() {
            let err = unsafe { std::ffi::CStr::from_ptr(mmf_last_error()) }
                .to_str()
                .unwrap_or("?")
                .to_string();
            println!("{name:<28} PARSE FAILED: {err}");
            continue;
        }
        let triangles = unsafe { mmf_triangle_count(doc) };
        let meshes = unsafe { mmf_mesh_count(doc) };

        // 2. Cache serialization.
        let ts = Instant::now();
        let buf: MmfByteBuffer = mmf_document_lsm_bytes(doc);
        let tser = ts.elapsed();
        let cache_mb = buf.len as f64 / 1e6;
        let bytes = unsafe { std::slice::from_raw_parts(buf.ptr, buf.len) };

        // Optional: persist the serialized bytes for cache pre-warming.
        if let Ok(out_dir) = std::env::var("MMFORGE_CACHE_OUT") {
            let safe = name.replace(['/', ' '], "_");
            let out = std::path::Path::new(&out_dir).join(format!("{safe}.lsm"));
            std::fs::create_dir_all(&out_dir).unwrap();
            std::fs::write(&out, bytes).unwrap();
            // Write the cache version the refresh script needs to compute
            // the same keys the app does.
            let v = unsafe { std::ffi::CStr::from_ptr(mmf_cache_version()) }
                .to_str()
                .unwrap()
                .to_string();
            std::fs::write(std::path::Path::new(&out_dir).join(".cache_version"), v).unwrap();
        }

        // 3. Cache-hit load: write bytes to a temp .lsm and re-parse.
        let tmp = std::env::temp_dir().join(format!(
            "mmforge_bench_{}.lsm",
            name.replace(['/', ' '], "_")
        ));
        std::fs::write(&tmp, bytes).unwrap();
        mmf_bytes_free(buf);
        mmf_document_free(doc);

        let tl = Instant::now();
        let doc2 = mmf_parse_file(cpath(tmp.to_str().unwrap()).as_ptr());
        let tload = tl.elapsed();
        assert!(!doc2.is_null(), "cached LSM must re-parse: {name}");
        let triangles2 = unsafe { mmf_triangle_count(doc2) };
        let meshes2 = unsafe { mmf_mesh_count(doc2) };
        assert_eq!(
            triangles, triangles2,
            "triangles mismatch after cache: {name}"
        );
        assert_eq!(meshes, meshes2, "meshes mismatch after cache: {name}");
        mmf_document_free(doc2);
        let _ = std::fs::remove_file(&tmp);

        println!(
            "{name:<28} {:>8.1} {:>9.3} {:>9.3} {:>10.1} {:>10.3} {:>10}",
            size_mb,
            tp.as_secs_f64(),
            tser.as_secs_f64(),
            cache_mb,
            tload.as_secs_f64(),
            triangles
        );
    }
}

/// Diagnostic: verify that StreamingPacket chunk mesh indices match the
/// flat RenderPacket mesh indices (the interleaved copy fast path indexes
/// the packet by the same index the chunk uploader passes).
#[test]
#[ignore]
fn check_chunk_mesh_index_semantics() {
    let root = std::env::var("MMFORGE_TESTFILES")
        .unwrap_or_else(|_| format!("{}/../../testfile", env!("CARGO_MANIFEST_DIR")));
    let path = format!("{root}/方盒子.step");
    let doc = mmf_parse_file(cpath(&path).as_ptr());
    assert!(!doc.is_null(), "must parse 方盒子.step");

    let total = unsafe { mmf_mesh_count(doc) };
    let chunks = unsafe { mmf_build_streaming_packet(doc, 64 * 1024 * 1024) };
    println!("packet meshes: {total}, chunks: {chunks}");

    let mut mismatches = 0usize;
    for ci in 0..chunks {
        let mc = unsafe { mmf_chunk_mesh_count(doc, ci) };
        println!("chunk {ci}: {mc} meshes");
        for mi in 0..mc {
            let gid = unsafe { mmf_chunk_mesh_geometry_id(doc, ci, mi) };
            let packet_idx = (0..total).find(|i| unsafe { mmf_mesh_geometry_id(doc, *i) } == gid);
            if packet_idx != Some(mi as u32) {
                mismatches += 1;
                if mismatches <= 5 {
                    println!("  MISMATCH chunk={ci} mi={mi} gid={gid} packet_idx={packet_idx:?}");
                }
            }
        }
    }
    println!("total mismatches: {mismatches}");
    unsafe { mmf_document_free(doc) };
}
