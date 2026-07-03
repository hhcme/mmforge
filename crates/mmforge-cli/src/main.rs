//! MMForge CLI — command-line interface for model inspection and conversion.

use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser)]
#[command(
    name = "mmforge",
    version,
    about = "Industrial 2D/3D model parser and native renderer"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Version,
    Info {
        file: PathBuf,
        #[arg(long, default_value = "text")]
        format: OutputFormat,
    },
    Validate {
        file: PathBuf,
        #[arg(long, default_value = "text")]
        format: OutputFormat,
    },
    Convert {
        file: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
        #[arg(long)]
        compress: Option<String>,
    },
    Benchmark {
        file: PathBuf,
        #[arg(short, long, default_value = "5")]
        iterations: u32,
        #[arg(long, default_value = "text")]
        format: OutputFormat,
    },
    /// Convert multiple files to .lsm/.lsmc in a single output directory.
    BatchConvert {
        /// Output directory (created if missing).
        #[arg(short, long)]
        output_dir: PathBuf,
        /// Input files.
        files: Vec<PathBuf>,
        /// Use zstd compression (outputs .lsmc).
        #[arg(long)]
        compress: Option<String>,
        /// Summary format.
        #[arg(long, default_value = "text")]
        format: OutputFormat,
        /// Continue processing remaining files on error.
        #[arg(long)]
        continue_on_error: bool,
    },
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum OutputFormat {
    Text,
    Json,
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Version => cmd_version(),
        Commands::Info { file, format } => cmd_info(&file, format),
        Commands::Validate { file, format } => cmd_validate(&file, format),
        Commands::Convert {
            file,
            output,
            compress,
        } => cmd_convert(&file, output.as_deref(), compress.as_deref()),
        Commands::Benchmark {
            file,
            iterations,
            format,
        } => cmd_benchmark(&file, iterations, format),
        Commands::BatchConvert {
            output_dir,
            files,
            compress,
            format,
            continue_on_error,
        } => cmd_batch_convert(
            &output_dir,
            &files,
            compress.as_deref(),
            format,
            continue_on_error,
        ),
    }
}

fn cmd_version() {
    println!("mmforge {}", mmforge_core::VERSION);
}

fn cmd_info(file: &std::path::Path, format: OutputFormat) {
    match detect_and_parse(file) {
        Ok(p) => match format {
            OutputFormat::Text => {
                let bb = p.model.bounds();
                println!("file    : {}", file.display());
                println!("format  : {}", p.model.header.source_format);
                println!("nodes   : {}", p.model.scene.nodes.len());
                println!("geoms   : {}", p.model.geometries.len());
                println!("mats    : {}", p.model.materials.len());
                println!("triangles: {}", p.model.total_triangle_count());
                if bb.is_valid() {
                    println!(
                        "bounds  : [{:.3},{:.3},{:.3}] – [{:.3},{:.3},{:.3}]",
                        bb.min.x, bb.min.y, bb.min.z, bb.max.x, bb.max.y, bb.max.z
                    );
                }
                println!("warnings: {}", p.warnings.len());
                for w in &p.warnings {
                    println!("  - {:?}", w);
                }
            }
            OutputFormat::Json => {
                let bb = p.model.bounds();
                let json = serde_json::json!({
                    "source_format": p.model.header.source_format,
                    "source_path": p.model.header.source_path,
                    "parser_version": p.model.header.parser_version,
                    "node_count": p.model.scene.nodes.len(),
                    "geometry_count": p.model.geometries.len(),
                    "material_count": p.model.materials.len(),
                    "triangle_count": p.model.total_triangle_count(),
                    "bounds": if bb.is_valid() {
                        serde_json::json!({"min":[bb.min.x,bb.min.y,bb.min.z],"max":[bb.max.x,bb.max.y,bb.max.z]})
                    } else { serde_json::Value::Null },
                    "metadata": {
                        "units": p.model.metadata.units,
                        "author": p.model.metadata.author,
                        "description": p.model.metadata.description,
                    },
                    "custom": p.model.metadata.custom,
                    "warnings": p.warnings.iter().map(|w| format!("{w:?}")).collect::<Vec<_>>(),
                });
                println!("{}", serde_json::to_string_pretty(&json).unwrap());
            }
        },
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}

fn cmd_validate(file: &std::path::Path, format: OutputFormat) {
    match detect_and_parse(file) {
        Ok(p) => {
            let issues = p.model.validate_references();
            match format {
                OutputFormat::Text => {
                    if issues.is_empty() {
                        println!("PASS  {}", file.display());
                    } else {
                        println!("FAIL  {} ({} issues)", file.display(), issues.len());
                        for i in &issues {
                            println!("  - {:?} {}: {}", i.kind, i.context, i.detail);
                        }
                    }
                }
                OutputFormat::Json => {
                    let json = serde_json::json!({
                        "valid": issues.is_empty(),
                        "issue_count": issues.len(),
                        "issues": issues.iter().map(|i| serde_json::json!({
                            "kind": format!("{:?}", i.kind),
                            "context": i.context,
                            "detail": i.detail,
                        })).collect::<Vec<_>>(),
                        "source_format": p.model.header.source_format,
                        "source_path": p.model.header.source_path,
                        "metadata": {
                            "units": p.model.metadata.units,
                            "author": p.model.metadata.author,
                            "description": p.model.metadata.description,
                        },
                        "custom": p.model.metadata.custom,
                        "node_count": p.model.scene.nodes.len(),
                        "triangle_count": p.model.total_triangle_count(),
                    });
                    println!("{}", serde_json::to_string_pretty(&json).unwrap());
                }
            }
            if !issues.is_empty() {
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("FAIL  {} ({e})", file.display());
            std::process::exit(1);
        }
    }
}

fn cmd_convert(file: &std::path::Path, output: Option<&std::path::Path>, compress: Option<&str>) {
    let parsed = match detect_and_parse(file) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    let default_ext = match compress {
        Some("zstd") | Some("zst") => "lsmc",
        None => "lsm",
        Some(other) => {
            eprintln!(
                "error: unknown compression method '{}' (supported: zstd)",
                other
            );
            std::process::exit(1);
        }
    };
    let out = output
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| file.with_extension(default_ext));

    // When --compress is set, output MUST be .lsmc.
    let wants_compress = compress.is_some();
    let is_lsmc = out
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("lsmc"))
        .unwrap_or(false);
    if wants_compress && !is_lsmc {
        eprintln!(
            "error: --compress requires .lsmc output extension (got {})",
            out.display()
        );
        std::process::exit(1);
    }

    let mut f = std::fs::File::create(&out).unwrap_or_else(|e| {
        eprintln!("error creating {}: {e}", out.display());
        std::process::exit(1)
    });

    let size = if is_lsmc {
        mmforge_core::lsm::lsmc::write_lsmc(&parsed.model, &mut f).unwrap_or_else(|e| {
            eprintln!("error writing LSMC: {e}");
            std::process::exit(1)
        })
    } else {
        mmforge_core::lsm::write_lsm(&parsed.model, &mut f).unwrap_or_else(|e| {
            eprintln!("error writing LSM: {e}");
            std::process::exit(1)
        })
    };
    println!("wrote {} ({size} bytes)", out.display());
}

fn cmd_benchmark(file: &std::path::Path, iterations: u32, format: OutputFormat) {
    let mut times: Vec<f64> = Vec::with_capacity(iterations as usize);
    for _ in 0..iterations {
        let start = std::time::Instant::now();
        if detect_and_parse(file).is_err() {
            eprintln!("error parsing");
            std::process::exit(1);
        }
        times.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let min = times.first().unwrap();
    let max = times.last().unwrap();
    let med = times[times.len() / 2];
    let avg = times.iter().sum::<f64>() / times.len() as f64;
    match format {
        OutputFormat::Text => {
            println!("benchmark: {}", file.display());
            println!("  iterations: {iterations}");
            println!("  parse (ms): min={min:.1}  max={max:.1}  median={med:.1}  avg={avg:.1}");
        }
        OutputFormat::Json => {
            let json = serde_json::json!({
                "file": file.to_string_lossy(), "iterations": iterations,
                "parse_ms_min": min, "parse_ms_max": max,
                "parse_ms_median": med, "parse_ms_avg": avg,
            });
            println!("{}", serde_json::to_string_pretty(&json).unwrap());
        }
    }
}

// ----------------------------------------------------------------
// Detection + parsing
// ----------------------------------------------------------------

#[derive(Debug)]
struct Parsed {
    model: mmforge_core::LsmModel,
    warnings: Vec<mmforge_core::ParseWarning>,
}

fn detect_and_parse(path: &std::path::Path) -> Result<Parsed, String> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    // LSM/compressed LSM — read directly by extension.
    if ext == "lsm" {
        return parse_lsm_file(path);
    }
    if ext == "lsmc" {
        return parse_lsmc_file(path);
    }

    if ext == "stl" || ext == "stla" || ext == "stlb" {
        return parse_stl(path);
    }

    let header = std::fs::read(path).map_err(|e| format!("cannot read: {e}"))?;

    // Magic detection for extension-less / unknown-extension files.
    if header.len() >= 4 {
        match &header[..4] {
            b"LSMD" => return parse_lsm_file(path),
            b"LSMC" => return parse_lsmc_file(path),
            _ => {}
        }
    }

    if header.starts_with(b"ISO-10303-21;") || ext == "step" || ext == "stp" {
        return parse_step(path);
    }
    if ext == "igs" || ext == "iges" || ext == "dxf" {
        let mut b = mmforge_core::ModelBuilder::new(if ext == "dxf" { "DXF" } else { "IGES" });
        let _root = b.add_root("Root");
        let mut model = b.build();
        model.header.source_path = Some(path.to_string_lossy().to_string());
        return Ok(Parsed {
            model,
            warnings: vec![],
        });
    }

    // Last resort: try STL
    parse_stl(path)
}

fn parse_lsm_file(path: &std::path::Path) -> Result<Parsed, String> {
    let data = std::fs::read(path).map_err(|e| format!("open: {e}"))?;
    let model = mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(&data))
        .map_err(|e| format!("lsm read: {e}"))?;
    Ok(Parsed {
        model,
        warnings: vec![],
    })
}

fn parse_lsmc_file(path: &std::path::Path) -> Result<Parsed, String> {
    let data = std::fs::read(path).map_err(|e| format!("open: {e}"))?;
    let dec = mmforge_core::lsm::lsmc::read_lsmc_decompressed(&mut std::io::Cursor::new(&data))
        .map_err(|e| format!("lsmc read: {e}"))?;
    let model = mmforge_core::lsm::read_lsm(&mut std::io::Cursor::new(&dec))
        .map_err(|e| format!("lsm read: {e}"))?;
    Ok(Parsed {
        model,
        warnings: vec![],
    })
}

fn parse_stl(path: &std::path::Path) -> Result<Parsed, String> {
    let data = std::fs::read(path).map_err(|e| format!("read: {e}"))?;

    if binary_length_valid(&data) {
        parse_binary_stl(&data)
    } else if is_probably_ascii(&data) {
        parse_ascii_stl(&data)
    } else {
        Err("not a valid STL file (neither binary nor ASCII)".into())
    }
}

/// Check if the file length matches the binary STL formula:
///   file_size == 84 + triangle_count * 50
/// with up to 80 bytes of trailing padding tolerated.
fn binary_length_valid(data: &[u8]) -> bool {
    if data.len() < 84 {
        return false;
    }
    let tri_count = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    if tri_count == 0 || tri_count >= 100_000_000 {
        return false;
    }
    let expected = 84 + tri_count * 50;
    data.len() >= expected && (data.len() - expected) <= 80
}

/// ASCII STL files start with "solid" (case-insensitive).
fn is_probably_ascii(data: &[u8]) -> bool {
    if data.len() < 5 {
        return false;
    }
    let prefix = &data[..5];
    prefix.eq_ignore_ascii_case(b"solid")
}

fn parse_binary_stl(data: &[u8]) -> Result<Parsed, String> {
    if data.len() < 84 {
        return Err("binary STL too small".into());
    }
    let count = u32::from_le_bytes([data[80], data[81], data[82], data[83]]) as usize;
    let expected = 84 + count * 50;
    if data.len() < expected {
        return Err(format!(
            "truncated: expected {expected}, got {}",
            data.len()
        ));
    }
    let mut positions = Vec::with_capacity(count * 3);
    let mut indices = Vec::with_capacity(count * 3);
    for i in 0..count {
        let base = 84 + i * 50;
        for v in 0..3 {
            let off = base + 12 + v * 12;
            let x = f32::from_le_bytes(data[off..off + 4].try_into().unwrap());
            let y = f32::from_le_bytes(data[off + 4..off + 8].try_into().unwrap());
            let z = f32::from_le_bytes(data[off + 8..off + 12].try_into().unwrap());
            positions.push([x, y, z]);
            indices.push((i * 3 + v) as u32);
        }
    }
    let normals = vec![[0.0, 1.0, 0.0]; positions.len()];
    let mut b = mmforge_core::ModelBuilder::new("STL");
    let root = b.add_root("STL Model");
    let gid = b.add_mesh(positions, normals, indices);
    let _ = b.add_child(root, "Part", Some(gid), None);
    Ok(Parsed {
        model: b.build(),
        warnings: vec![],
    })
}

fn parse_ascii_stl(data: &[u8]) -> Result<Parsed, String> {
    let text = std::str::from_utf8(data).map_err(|_| "invalid UTF-8".to_string())?;
    let mut positions: Vec<[f32; 3]> = Vec::new();
    let mut indices: Vec<u32> = Vec::new();
    let mut idx = 0u32;
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("vertex ") || t.starts_with("vertex") {
            let parts: Vec<&str> = t.split_whitespace().collect();
            if parts.len() >= 4 {
                if let (Ok(x), Ok(y), Ok(z)) =
                    (parts[1].parse(), parts[2].parse(), parts[3].parse())
                {
                    positions.push([x, y, z]);
                    indices.push(idx);
                    idx += 1;
                }
            }
        }
    }
    if positions.is_empty() {
        return Err("no vertices found".into());
    }
    let normals = vec![[0.0, 1.0, 0.0]; positions.len()];
    let mut b = mmforge_core::ModelBuilder::new("STL");
    let root = b.add_root("STL Model");
    let gid = b.add_mesh(positions, normals, indices);
    let _ = b.add_child(root, "Part", Some(gid), None);
    Ok(Parsed {
        model: b.build(),
        warnings: vec![],
    })
}

fn parse_step(path: &std::path::Path) -> Result<Parsed, String> {
    let mut b = mmforge_core::ModelBuilder::new("STEP");
    let _root = b.add_root("Empty STEP");
    let mut model = b.build();
    model.header.source_path = Some(path.to_string_lossy().to_string());
    Ok(Parsed {
        model,
        warnings: vec![],
    })
}

// ----------------------------------------------------------------
// Batch conversion
// ----------------------------------------------------------------

#[derive(serde::Serialize)]
struct BatchResult {
    file: String,
    output: String,
    status: String,
    size: Option<u64>,
    error: Option<String>,
}

fn cmd_batch_convert(
    output_dir: &std::path::Path,
    files: &[PathBuf],
    compress: Option<&str>,
    format: OutputFormat,
    continue_on_error: bool,
) {
    std::fs::create_dir_all(output_dir).unwrap_or_else(|e| {
        eprintln!("error: cannot create output directory: {e}");
        std::process::exit(1);
    });

    let compress_ext = match compress {
        Some("zstd") | Some("zst") => "lsmc",
        None => "lsm",
        Some(other) => {
            eprintln!("error: unknown compression method '{other}' (supported: zstd)");
            std::process::exit(1);
        }
    };

    let mut results: Vec<BatchResult> = Vec::new();
    let mut failed = false;

    for input in files {
        let stem = input
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("output");
        let output = output_dir.join(format!("{stem}.{compress_ext}"));

        match convert_one(input, &output, compress.is_some()) {
            Ok(size) => {
                results.push(BatchResult {
                    file: input.display().to_string(),
                    output: output.display().to_string(),
                    status: "ok".into(),
                    size: Some(size),
                    error: None,
                });
            }
            Err(e) => {
                results.push(BatchResult {
                    file: input.display().to_string(),
                    output: output.display().to_string(),
                    status: "error".into(),
                    size: None,
                    error: Some(e),
                });
                failed = true;
                if !continue_on_error {
                    break;
                }
            }
        }
    }

    match format {
        OutputFormat::Text => {
            for r in &results {
                if r.status == "ok" {
                    println!(
                        "OK    {} → {} ({} bytes)",
                        r.file,
                        r.output,
                        r.size.unwrap_or(0)
                    );
                } else {
                    println!(
                        "FAIL  {} → {} ({})",
                        r.file,
                        r.output,
                        r.error.as_deref().unwrap_or("unknown error")
                    );
                }
            }
            let ok = results.iter().filter(|r| r.status == "ok").count();
            let err = results.len() - ok;
            println!("---");
            println!("{}/{} converted ({} failed)", ok, results.len(), err);
        }
        OutputFormat::Json => {
            let json = serde_json::json!({
                "results": results.iter().map(|r| serde_json::json!({
                    "file": r.file, "output": r.output, "status": r.status,
                    "size_bytes": r.size, "error": r.error,
                })).collect::<Vec<_>>(),
                "total": results.len(),
                "converted": results.iter().filter(|r| r.status == "ok").count(),
                "failed": results.iter().filter(|r| r.status == "error").count(),
            });
            println!("{}", serde_json::to_string_pretty(&json).unwrap());
        }
    }

    if failed {
        std::process::exit(1);
    }
}

fn convert_one(
    input: &std::path::Path,
    output: &std::path::Path,
    compress: bool,
) -> Result<u64, String> {
    let parsed = detect_and_parse(input)?;
    let mut f = std::fs::File::create(output).map_err(|e| format!("create: {e}"))?;
    if compress {
        mmforge_core::lsm::lsmc::write_lsmc(&parsed.model, &mut f).map_err(|e| format!("lsmc: {e}"))
    } else {
        mmforge_core::lsm::write_lsm(&parsed.model, &mut f).map_err(|e| format!("lsm: {e}"))
    }
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_temp_stl_ascii() -> tempfile::NamedTempFile {
        let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
        f.write_all(
            b"solid test\n  facet normal 0 0 1\n    outer loop\n      vertex 0 0 0\n      vertex 1 0 0\n      vertex 0 1 0\n    endloop\n  endfacet\nendsolid test\n",
        )
        .unwrap();
        f
    }

    fn write_temp_stl_binary(tri_count: u32) -> tempfile::NamedTempFile {
        let mut f = tempfile::Builder::new().suffix(".stl").tempfile().unwrap();
        let mut data = vec![0u8; 80]; // header
        data[0..9].copy_from_slice(b"binarystl");
        data.extend_from_slice(&tri_count.to_le_bytes());
        for _ in 0..tri_count {
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
        }
        f.write_all(&data).unwrap();
        f
    }

    #[allow(dead_code)]
    fn write_lsm_triangle() -> tempfile::NamedTempFile {
        let mut f = tempfile::Builder::new().suffix(".lsm").tempfile().unwrap();
        let mut b = mmforge_core::ModelBuilder::new("STL")
            .with_units("mm")
            .build();
        b.header.source_path = Some("test.stl".into());
        let mut cursor = std::io::Cursor::new(Vec::new());
        mmforge_core::lsm::write_lsm(&b, &mut cursor).unwrap();
        f.write_all(cursor.get_ref()).unwrap();
        f
    }

    // ----------------------------------------------------------------

    #[test]
    fn detect_ascii_stl() {
        let f = write_temp_stl_ascii();
        let p = detect_and_parse(f.path()).unwrap();
        assert_eq!(p.model.header.source_format, "STL");
        assert_eq!(p.model.total_triangle_count(), 1);
    }

    #[test]
    fn detect_binary_stl() {
        let f = write_temp_stl_binary(2);
        let p = detect_and_parse(f.path()).unwrap();
        assert_eq!(p.model.header.source_format, "STL");
        assert_eq!(p.model.total_triangle_count(), 2);
    }

    /// Full round-trip: binary STL → convert → .lsm → info → validate.
    #[test]
    fn binary_stl_to_lsm_round_trip() {
        let stl = write_temp_stl_binary(3);

        // Convert
        let lsm_path = stl.path().with_extension("lsm");
        cmd_convert(stl.path(), Some(&lsm_path), None);
        assert!(lsm_path.exists());

        // Info on LSM
        let p = detect_and_parse(&lsm_path).unwrap();
        assert_eq!(p.model.header.source_format, "STL");
        assert_eq!(p.model.total_triangle_count(), 3);
        assert_eq!(p.model.scene.nodes.len(), 2);

        // Validate LSM
        let issues = p.model.validate_references();
        assert!(issues.is_empty(), "LSM should have no validation issues");

        // Benchmark .lsm
        cmd_benchmark(&lsm_path, 2, OutputFormat::Text);
    }

    /// LSM info prints JSON stably.
    #[test]
    fn lsm_info_json_output() {
        let f = write_temp_stl_ascii();
        let lsm_path = f.path().with_extension("lsm");
        cmd_convert(f.path(), Some(&lsm_path), None);

        let p = detect_and_parse(&lsm_path).unwrap();
        let bb = p.model.bounds();
        let json = serde_json::json!({
            "source_format": p.model.header.source_format,
            "node_count": p.model.scene.nodes.len(),
            "triangle_count": p.model.total_triangle_count(),
            "bounds": {"min":[bb.min.x,bb.min.y,bb.min.z],"max":[bb.max.x,bb.max.y,bb.max.z]},
        });
        assert!(json["source_format"].as_str() == Some("STL"));
        assert!(json["triangle_count"].as_u64() == Some(1));
        assert!(json["bounds"]["min"].is_array());
    }

    /// LSM validate finds no issues on well-formed model.
    #[test]
    fn lsm_validate_clean() {
        let f = write_temp_stl_ascii();
        let lsm_path = f.path().with_extension("lsm");
        cmd_convert(f.path(), Some(&lsm_path), None);

        let p = detect_and_parse(&lsm_path).unwrap();
        assert!(p.model.validate_references().is_empty());
    }

    /// Bad magic in LSM file returns error.
    #[test]
    fn lsm_bad_magic_error() {
        let mut f = tempfile::Builder::new().suffix(".lsm").tempfile().unwrap();
        f.write_all(b"XXXXjunkdata").unwrap();

        let err = detect_and_parse(f.path()).unwrap_err();
        assert!(
            err.contains("lsm read"),
            "expected lsm read error, got: {err}"
        );
    }

    /// LSM file with unsupported version returns error.
    #[test]
    fn lsm_high_version_error() {
        let mut f = tempfile::Builder::new().suffix(".lsm").tempfile().unwrap();
        let mut data = vec![0u8; 100];
        data[0..4].copy_from_slice(b"LSMD");
        data[4] = 99; // version 99
        f.write_all(&data).unwrap();

        let err = detect_and_parse(f.path()).unwrap_err();
        assert!(err.contains("unsupported version"));
    }

    /// Non-STL, non-LSM file without extension falls back to STL parser.
    #[test]
    fn unknown_file_falls_back_to_stl() {
        let mut f = tempfile::Builder::new()
            .suffix(".unknown")
            .tempfile()
            .unwrap();
        f.write_all(b"garbage").unwrap();

        let err = detect_and_parse(f.path()).unwrap_err();
        assert!(
            err.contains("not a valid STL") || err.contains("invalid UTF-8"),
            "expected STL parse error, got: {err}"
        );
    }
}
