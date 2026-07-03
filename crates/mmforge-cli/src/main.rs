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
    },
    Benchmark {
        file: PathBuf,
        #[arg(short, long, default_value = "5")]
        iterations: u32,
        #[arg(long, default_value = "text")]
        format: OutputFormat,
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
        Commands::Convert { file, output } => cmd_convert(&file, output.as_deref()),
        Commands::Benchmark {
            file,
            iterations,
            format,
        } => cmd_benchmark(&file, iterations, format),
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
                    "node_count": p.model.scene.nodes.len(),
                    "geometry_count": p.model.geometries.len(),
                    "material_count": p.model.materials.len(),
                    "triangle_count": p.model.total_triangle_count(),
                    "bounds": if bb.is_valid() {
                        serde_json::json!({"min":[bb.min.x,bb.min.y,bb.min.z],"max":[bb.max.x,bb.max.y,bb.max.z]})
                    } else { serde_json::Value::Null },
                    "warnings": p.warnings.iter().map(|w| format!("{w:?}")).collect::<Vec<_>>(),
                });
                println!("{}", serde_json::to_string_pretty(&json).unwrap());
            }
        },
        Err(e) => eprintln!("error: {e}"),
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

fn cmd_convert(file: &std::path::Path, output: Option<&std::path::Path>) {
    let parsed = match detect_and_parse(file) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    let out = output
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| file.with_extension("lsm"));
    let mut f = std::fs::File::create(&out).unwrap_or_else(|e| {
        eprintln!("error creating {}: {e}", out.display());
        std::process::exit(1)
    });
    let size = mmforge_core::lsm::write_lsm(&parsed.model, &mut f).unwrap_or_else(|e| {
        eprintln!("error writing LSM: {e}");
        std::process::exit(1)
    });
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

    if ext == "stl" || ext == "stla" || ext == "stlb" {
        return parse_stl(path);
    }

    let header = std::fs::read(path).map_err(|e| format!("cannot read: {e}"))?;
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

fn parse_stl(path: &std::path::Path) -> Result<Parsed, String> {
    let data = std::fs::read(path).map_err(|e| format!("read: {e}"))?;
    let is_binary = data.len() >= 84
        && &data[0..5] == b"solid"
        && !std::str::from_utf8(&data[0..80])
            .unwrap_or("")
            .contains("facet");

    if is_binary {
        parse_binary_stl(&data)
    } else {
        parse_ascii_stl(&data)
    }
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
