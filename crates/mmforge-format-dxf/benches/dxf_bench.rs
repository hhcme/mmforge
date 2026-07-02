//! Benchmarks for the DXF parser.
//!
//! Run with: `cargo bench -p mmforge-format-dxf`

use criterion::{Criterion, criterion_group, criterion_main};
use std::path::Path;

fn bench_parse_dxf(c: &mut Criterion) {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join("test.dxf");
    assert!(fixture.exists(), "test.dxf fixture missing");

    c.bench_function("parse_dxf_test_fixture", |b| {
        b.iter(|| {
            let result = mmforge_format_dxf::parse_dxf(&fixture);
            assert!(result.is_ok());
        });
    });
}

fn bench_parse_dxf_linetypes(c: &mut Criterion) {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join("linetypes.dxf");
    assert!(fixture.exists(), "linetypes.dxf fixture missing");

    c.bench_function("parse_dxf_linetypes", |b| {
        b.iter(|| {
            let result = mmforge_format_dxf::parse_dxf(&fixture);
            assert!(result.is_ok());
        });
    });
}

fn bench_tokenizer(c: &mut Criterion) {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join("test.dxf");
    let content = std::fs::read_to_string(&fixture).unwrap();

    c.bench_function("tokenize_test_fixture", |b| {
        b.iter(|| {
            let mut tokenizer = mmforge_format_dxf::DxfTokenizer::new(&content);
            let _pairs = tokenizer.collect_all();
        });
    });
}

fn bench_build_draw_list(c: &mut Criterion) {
    use mmforge_core::drawing::Drawing2DGeometry;

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join("test.dxf");
    let (_, drawing) = mmforge_format_dxf::parse_dxf(&fixture).unwrap();

    c.bench_function("build_draw_list", |b| {
        b.iter(|| {
            let _dl = mmforge_render::draw2d::build_draw_list(&drawing);
        });
    });
}

criterion_group!(
    benches,
    bench_parse_dxf,
    bench_parse_dxf_linetypes,
    bench_tokenizer,
    bench_build_draw_list
);
criterion_main!(benches);
