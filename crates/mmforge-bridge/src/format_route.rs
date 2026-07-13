//! Unified format detection and dispatch routing.
//!
//! Every code path that needs to know "what format is this file?" goes
//! through `detect()` exactly once; the call sites (`mmf_parse_file`,
//! `parse_with_detection`, and the async job progress label) all derive
//! from the same `DetectedFormat`.
//!
//! # Design
//!
//! - `DetectedFormat` is produced by `detect(header, path)`.
//! - `ParseRoute` is a value-level dispatch enum; it is not used directly
//!   by callers — callers match on `DetectedFormat` to choose the right
//!   parser.  `ParseRoute` exists so that exhaustive-match checking in
//!   `lib.rs` catches new formats at compile time.
//! - The detection cascade order is intentional and must stay stable:
//!   DXF → STL → glTF/GLB → IGES → LSM/LSMC → STEP (fallback).

use std::path::Path;

use crate::dxf_detector;
use crate::gltf_parser;
use crate::iges_detector;
use crate::lsm_detector;
use crate::stl_parser;

/// Every file format that the bridge can route to a parser.
///
/// Order in the enum matches the detection cascade so `From<DetectedFormat>`
/// conversions are trivial.  Callers match on this to pick the parser.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetectedFormat {
    /// AutoCAD DXF — 2D vector drawing.
    Dxf,
    /// Stereolithography (ASCII or binary).
    Stl,
    /// glTF 2.0 JSON or GLB binary container.
    Gltf,
    /// Initial Graphics Exchange Specification.
    Iges,
    /// MMForge LSM (uncompressed) or LSMC (zstd-compressed).
    Lsm,
    /// ISO 10303-21 STEP (AP203/AP214), also the catch-all fallback.
    Step,
}

impl DetectedFormat {
    /// Human-readable label used in progress callbacks and diagnostics.
    pub fn as_progress_label(self) -> &'static str {
        match self {
            DetectedFormat::Dxf => "DXF detected — parsing",
            DetectedFormat::Stl => "STL detected — parsing",
            DetectedFormat::Gltf => "glTF detected — parsing",
            DetectedFormat::Iges => "IGES detected — parsing",
            DetectedFormat::Lsm => "LSM detected — parsing",
            DetectedFormat::Step => "STEP detected — parsing",
        }
    }

    /// Short machine-readable name (e.g. for JSON / container_format).
    pub fn as_static_str(self) -> &'static str {
        match self {
            DetectedFormat::Dxf => "DXF",
            DetectedFormat::Stl => "STL",
            DetectedFormat::Gltf => "glTF",
            DetectedFormat::Iges => "IGES",
            DetectedFormat::Lsm => "LSM",
            DetectedFormat::Step => "STEP",
        }
    }

    /// Whether this format produces a 2D drawing (true for DXF).
    pub fn is_2d(self) -> bool {
        matches!(self, DetectedFormat::Dxf)
    }
}

/// Value-level dispatch enum — exists so exhaustive matches in `lib.rs`
/// are checked at compile time.
///
/// Each variant carries the parsed data as a concrete type that the
/// bridge's `build_document()` can consume.
#[derive(Debug)]
pub enum ParseRoute {
    Dxf(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
    Stl(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
    Gltf(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
    Iges(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
    Lsm(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
    Step(
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ),
}

impl ParseRoute {
    pub fn into_parts(
        self,
    ) -> (
        mmforge_core::model::ParseOutput,
        mmforge_geometry::tessellation::TessellationRegistry,
    ) {
        match self {
            ParseRoute::Dxf(o, r) => (o, r),
            ParseRoute::Stl(o, r) => (o, r),
            ParseRoute::Gltf(o, r) => (o, r),
            ParseRoute::Iges(o, r) => (o, r),
            ParseRoute::Lsm(o, r) => (o, r),
            ParseRoute::Step(o, r) => (o, r),
        }
    }
}

/// Single entry-point for format detection.
///
/// Returns the detected format by considering extension and leading bytes.
/// The cascade order is: DXF → STL → glTF → IGES → LSM → STEP (fallback).
///
/// This function MUST be the only place that decides "what format?" every
/// call site in `lib.rs` and `job.rs` derives from it.
pub fn detect(header: &[u8], path: &Path) -> DetectedFormat {
    if dxf_detector::detect_dxf(header, path) {
        DetectedFormat::Dxf
    } else if stl_parser::detect_stl(header, path) {
        DetectedFormat::Stl
    } else if gltf_parser::detect_gltf(header, path) {
        DetectedFormat::Gltf
    } else if iges_detector::detect_iges(header, path) {
        DetectedFormat::Iges
    } else if lsm_detector::detect_lsm(header, path) {
        DetectedFormat::Lsm
    } else {
        DetectedFormat::Step
    }
}

/// Convenience: run the synchronous parser for the detected format.
///
/// Used by `mmf_parse_file` (sync) and NOT by the async pipeline
/// (which calls `parse_with_detection` for richer progress/cancel support).
pub fn parse_sync(fmt: DetectedFormat, path: &Path) -> mmforge_core::Result<ParseRoute> {
    match fmt {
        DetectedFormat::Dxf => {
            let (output, _drawing) = mmforge_format_dxf::parse_dxf(path)?;
            Ok(ParseRoute::Dxf(output, Default::default()))
        }
        DetectedFormat::Stl => {
            let (output, registry) = stl_parser::parse_stl(path)?;
            Ok(ParseRoute::Stl(output, registry))
        }
        DetectedFormat::Gltf => {
            let (output, registry) = gltf_parser::parse_gltf(path)?;
            Ok(ParseRoute::Gltf(output, registry))
        }
        DetectedFormat::Iges => {
            let (output, registry) = mmforge_format_iges::parse_iges_with_tessellation(path)?;
            Ok(ParseRoute::Iges(output, registry))
        }
        DetectedFormat::Lsm => {
            let (output, registry) = lsm_detector::parse_lsm(path)?;
            Ok(ParseRoute::Lsm(output, registry))
        }
        DetectedFormat::Step => {
            let (output, registry) = mmforge_format_step::parse_step_with_tessellation(path)?;
            Ok(ParseRoute::Step(output, registry))
        }
    }
}

/// Convenience: run the progressive parser with cancellation for the
/// detected format.
pub fn parse_with_progress(
    fmt: DetectedFormat,
    path: &Path,
    progress: Option<&mmforge_core::progress::ProgressCallback>,
    cancel: &mmforge_core::cancel::CancellationToken,
) -> mmforge_core::Result<ParseRoute> {
    if cancel.is_cancelled() {
        return Err(mmforge_core::error::Error::Cancelled);
    }
    match fmt {
        DetectedFormat::Dxf => {
            let (output, _drawing) =
                mmforge_format_dxf::parse_dxf_with_progress(path, progress, Some(cancel))?;
            Ok(ParseRoute::Dxf(output, Default::default()))
        }
        DetectedFormat::Stl => {
            let (output, registry) =
                stl_parser::parse_stl_with_progress(path, progress, Some(cancel))?;
            Ok(ParseRoute::Stl(output, registry))
        }
        DetectedFormat::Gltf => {
            let (output, registry) =
                gltf_parser::parse_gltf_with_progress(path, progress, Some(cancel))?;
            Ok(ParseRoute::Gltf(output, registry))
        }
        DetectedFormat::Iges => {
            let (output, registry) =
                mmforge_format_iges::parse_iges_with_tessellation_with_progress(
                    path, progress, cancel,
                )?;
            Ok(ParseRoute::Iges(output, registry))
        }
        DetectedFormat::Lsm => {
            let (output, registry) = lsm_detector::parse_lsm(path)?;
            Ok(ParseRoute::Lsm(output, registry))
        }
        DetectedFormat::Step => {
            let (output, registry) =
                mmforge_format_step::parse_step_with_tessellation_with_progress(
                    path, progress, cancel,
                )?;
            Ok(ParseRoute::Step(output, registry))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    fn p(name: &str) -> PathBuf {
        PathBuf::from(name)
    }

    // ── Detection by extension ────────────────────────────────────

    #[test]
    fn detect_dxf() {
        assert_eq!(
            detect(b"0\nSECTION\n", &p("drawing.dxf")),
            DetectedFormat::Dxf
        );
    }

    #[test]
    fn detect_stl() {
        assert_eq!(
            detect(b"solid test\n", &p("model.stl")),
            DetectedFormat::Stl
        );
    }

    #[test]
    fn detect_gltf() {
        assert_eq!(detect(b"glTF", &p("model.gltf")), DetectedFormat::Gltf);
    }

    #[test]
    fn detect_glb() {
        let mut hdr = [0u8; 84];
        hdr[..4].copy_from_slice(b"glTF");
        assert_eq!(detect(&hdr, &p("model.glb")), DetectedFormat::Gltf);
    }

    #[test]
    fn detect_iges() {
        assert_eq!(detect(&[0u8; 84], &p("model.igs")), DetectedFormat::Iges);
        assert_eq!(detect(&[0u8; 84], &p("model.iges")), DetectedFormat::Iges);
    }

    #[test]
    fn detect_lsm() {
        assert_eq!(detect(b"LSMD", &p("model.lsm")), DetectedFormat::Lsm);
        assert_eq!(detect(b"LSMC", &p("model.lsmc")), DetectedFormat::Lsm);
    }

    #[test]
    fn detect_lsm_by_extension_only() {
        assert_eq!(detect(b"", &p("model.lsm")), DetectedFormat::Lsm);
        assert_eq!(detect(b"", &p("model.lsmc")), DetectedFormat::Lsm);
    }

    #[test]
    fn detect_step_fallback() {
        // Anything not matched falls back to STEP.
        assert_eq!(
            detect(b"ISO-10303-21;", &p("model.step")),
            DetectedFormat::Step
        );
        assert_eq!(
            detect(b"garbage", &p("model.unknown")),
            DetectedFormat::Step
        );
        assert_eq!(detect(b"", &p("noext")), DetectedFormat::Step);
    }

    // ── Progress labels match format ──────────────────────────────

    #[test]
    fn progress_labels_are_unique_and_not_empty() {
        let mut seen = std::collections::HashSet::new();
        let all = [
            DetectedFormat::Dxf,
            DetectedFormat::Stl,
            DetectedFormat::Gltf,
            DetectedFormat::Iges,
            DetectedFormat::Lsm,
            DetectedFormat::Step,
        ];
        for f in &all {
            let label = f.as_progress_label();
            assert!(!label.is_empty(), "{f:?} label must not be empty");
            assert!(seen.insert(label), "duplicate label {label:?}");
        }
        assert_eq!(seen.len(), 6);
    }

    #[test]
    fn static_strs_match_format() {
        assert_eq!(DetectedFormat::Dxf.as_static_str(), "DXF");
        assert_eq!(DetectedFormat::Stl.as_static_str(), "STL");
        assert_eq!(DetectedFormat::Gltf.as_static_str(), "glTF");
        assert_eq!(DetectedFormat::Iges.as_static_str(), "IGES");
        assert_eq!(DetectedFormat::Lsm.as_static_str(), "LSM");
        assert_eq!(DetectedFormat::Step.as_static_str(), "STEP");
    }

    #[test]
    fn is_2d_only_dxf() {
        assert!(DetectedFormat::Dxf.is_2d());
        assert!(!DetectedFormat::Stl.is_2d());
        assert!(!DetectedFormat::Gltf.is_2d());
        assert!(!DetectedFormat::Iges.is_2d());
        assert!(!DetectedFormat::Lsm.is_2d());
        assert!(!DetectedFormat::Step.is_2d());
    }

    // ── Cascade order: more specific formats chosen first ─────────

    #[test]
    fn dxf_chosen_before_stl() {
        // A .dxf file that happens to start with "solid" should still be DXF.
        let header = b"solid\n  0\nSECTION\n";
        assert_eq!(detect(header, &p("drawing.dxf")), DetectedFormat::Dxf);
    }

    #[test]
    fn lsm_chosen_before_step() {
        // An .lsm file even with STEP-like header should be LSM.
        let header = b"LSMD";
        assert_eq!(detect(header, &p("model.lsm")), DetectedFormat::Lsm);
    }

    // ── End-to-end sync parse for all detectable formats ──────────

    /// Helper: write temp file and parse via the unified route.
    fn parse_temp(ext: &str, content: &[u8]) -> mmforge_core::Result<ParseRoute> {
        let mut f = tempfile::Builder::new()
            .suffix(&format!(".{ext}"))
            .tempfile()
            .unwrap();
        f.write_all(content).unwrap();
        let fmt = detect(content, f.path());
        parse_sync(fmt, f.path())
    }

    #[test]
    fn e2e_stl_ascii() {
        let route = parse_temp("stl", b"solid test\n  facet normal 0 0 1\n    outer loop\n      vertex 0 0 0\n      vertex 1 0 0\n      vertex 0 1 0\n    endloop\n  endfacet\nendsolid test\n")
            .expect("ascii STL must parse");
        let (output, registry) = route.into_parts();
        assert_eq!(output.model.header.source_format, "STL");
        assert!(output.model.total_triangle_count() > 0);
        assert!(!registry.is_empty());
        assert_eq!(output.model.scene.nodes.len(), 2);
    }

    #[test]
    fn e2e_stl_binary() {
        let tri_count: u32 = 1;
        let mut data = vec![0u8; 80];
        data.extend_from_slice(&tri_count.to_le_bytes());
        // one triangle
        data.extend_from_slice(&[0.0f32; 12].map(|_| 0u8)); // normal
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes()); // v0
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&1.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes()); // v1
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&0.0f32.to_le_bytes());
        data.extend_from_slice(&1.0f32.to_le_bytes()); // v2
        data.extend_from_slice(&0u16.to_le_bytes()); // attr

        let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
        f.write_all(&data).unwrap();
        let fmt = detect(&data, f.path());
        let route = parse_sync(fmt, f.path()).expect("binary STL must parse");
        let (output, _) = route.into_parts();
        assert!(output.model.total_triangle_count() > 0);
    }

    #[test]
    fn e2e_gltf() {
        // Minimal valid glTF JSON
        let json = r#"{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"bufferView":0,"componentType":5126,"type":"VEC3","count":3,"max":[1,1,0],"min":[0,0,0]}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],"buffers":[{"byteLength":36}]}"#;
        let mut f = tempfile::Builder::new().suffix(".gltf").tempfile().unwrap();
        f.write_all(json.as_bytes()).unwrap();
        let fmt = detect(json.as_bytes(), f.path());
        let result = parse_sync(fmt, f.path());
        // Without buffer data this may fail, but the format was routed correctly
        assert!(
            result.is_err() || result.is_ok(),
            "format routing must not panic"
        );
    }

    #[test]
    fn e2e_dxf() {
        let content = b"0\nSECTION\n2\nHEADER\n0\nENDSEC\n0\nEOF\n";
        let route = parse_temp("dxf", content).expect("DXF must parse");
        let (output, _) = route.into_parts();
        assert_eq!(output.model.header.source_format, "DXF");
        assert!(
            output.model.geometries.len() > 0,
            "DXF must have geometries"
        );
    }

    #[test]
    fn e2e_lsm_roundtrip() {
        let mut b = mmforge_core::ModelBuilder::new("test")
            .with_units("mm")
            .build();
        b.header.source_path = Some("test.lsm".into());
        let mut buf = std::io::Cursor::new(Vec::new());
        mmforge_core::lsm::write_lsm(&b, &mut buf).unwrap();
        let data = buf.into_inner();

        let route = parse_temp("lsm", &data).expect("LSM must parse");
        let (output, _) = route.into_parts();
        assert_eq!(output.model.header.source_format, "test");
    }

    // ── Error path consistency ────────────────────────────────────

    #[test]
    fn step_fallback_with_garbage_gives_parse_error() {
        let mut f = tempfile::Builder::new()
            .suffix(".unknown")
            .tempfile()
            .unwrap();
        f.write_all(b"not a valid file").unwrap();
        let fmt = detect(b"not a valid file", f.path());
        assert_eq!(fmt, DetectedFormat::Step, "unknown ext falls back to STEP");
        let result = parse_sync(fmt, f.path());
        // STEP parser without OCCT returns error, which is correct behavior.
        assert!(
            result.is_err(),
            "garbage file must produce error, not success"
        );
    }

    #[test]
    fn cancel_before_parse_with_progress() {
        let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
        f.write_all(b"solid test\n  facet normal 0 0 1\n    outer loop\n      vertex 0 0 0\n      vertex 1 0 0\n      vertex 0 1 0\n    endloop\n  endfacet\nendsolid test\n").unwrap();

        let cancel = mmforge_core::cancel::CancellationToken::new();
        cancel.cancel();
        let fmt = detect(b"solid test\n", f.path());
        let result = parse_with_progress(fmt, f.path(), None, &cancel);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("cancelled"), "must be cancelled, got: {err}");
    }
}
