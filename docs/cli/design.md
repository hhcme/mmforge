# CLI 工具设计文档

> MMForge 命令行工具的技术设计。
>
> 最后更新：2026-06-29

---

## 1. 职责

CLI 工具负责：
- 独立于原生客户端使用的命令行解析器
- 文件格式转换（源格式 → 渲染/交换格式；`.lsm` 持久化在格式冻结后启用）
- 模型信息查看
- 文件验证
- 批量处理

---

## 2. 架构

```
┌─────────────────────────────────────────────┐
│               mmforge CLI                   │
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │              命令行入口                   ││
│  │  clap (参数解析)                          ││
│  │  ├── info                               ││
│  │  ├── convert                            ││
│  │  ├── validate                           ││
│  │  ├── formats                            ││
│  │  └── benchmark                          ││
│  └────────────────┬────────────────────────┘│
│                   │                          │
│  ┌────────────────▼────────────────────────┐│
│  │              业务逻辑层                   ││
│  │  ├── 文件格式识别                        ││
│  │  ├── 解析流程编排                        ││
│  │  ├── 输出格式化                          ││
│  │  └── 进度显示                            ││
│  └────────────────┬────────────────────────┘│
│                   │                          │
│  ┌────────────────▼────────────────────────┐│
│  │              核心库 (mmforge-core)            ││
│  │  ├── FormatParser (各格式解析器)         ││
│  │  ├── LsmModel (数据模型)                ││
│  │  └── Tessellation                       ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

---

## 3. 命令设计

### 3.1 总览

```bash
mmforge <COMMAND> [OPTIONS]

Commands:
  info        查看模型信息
  convert     格式转换
  validate    验证文件完整性
  formats     查看支持的格式
  benchmark   性能测试

Options:
  -h, --help       显示帮助
  -V, --version    显示版本
  -v, --verbose    详细输出
  -q, --quiet      静默模式
```

### 3.2 info — 查看模型信息

```bash
mmforge info <FILE> [OPTIONS]

# 示例
mmforge info model.step
mmforge info model.gltf --json
mmforge info model.dxf --verbose
```

输出示例：

```
File:       model.step
Format:     STEP (AP214)
Size:       2.3 MB

Geometry:
  Solids:   3
  Shells:   5
  Faces:    127
  Edges:    384
  Vertices: 256

Bounding Box:
  Min: (0.0, 0.0, 0.0)
  Max: (100.0, 50.0, 30.0)
  Size: 100.0 × 50.0 × 30.0 mm

Structure:
  Products: 3
  Shape Representations: 5

Units:      millimeter
Created:    2024-01-15 10:30:00
```

JSON 输出：

```bash
mmforge info model.step --json
```

```json
{
  "file": "model.step",
  "format": "STEP",
  "version": "AP214",
  "size_bytes": 2411520,
  "geometry": {
    "solids": 3,
    "shells": 5,
    "faces": 127,
    "edges": 384,
    "vertices": 256
  },
  "bounding_box": {
    "min": [0.0, 0.0, 0.0],
    "max": [100.0, 50.0, 30.0]
  },
  "units": "millimeter"
}
```

### 3.3 convert — 格式转换

```bash
mmforge convert <INPUT> [OPTIONS]

# 源格式 → LSM
mmforge convert model.stl -o model.lsm

# 源格式 → LSMC (zstd 压缩)
mmforge convert model.stl --compress zstd -o model.lsmc

# 默认输出 (使用输入文件名)
mmforge convert model.stl                    # → model.lsm
mmforge convert model.stl --compress zstd    # → model.lsmc
```

选项：

```
-o, --output <FILE>           输出文件路径
    --compress <zstd>         使用 zstd 压缩输出 .lsmc
    --tessellation-quality    精度 (low/standard/high)  [未实现]
```

### 3.4 batch-convert — 批量转换

```bash
mmforge batch-convert -o <DIR> [--compress zstd] [--format json] [--continue-on-error] <FILES...>

# 批量转换到输出目录
mmforge batch-convert -o out/ a.stl b.stl c.stl

# 压缩批量
mmforge batch-convert -o out/ --compress zstd *.stl

# JSON 汇总
mmforge batch-convert -o out/ --format json a.stl b.stl

# 遇错继续
mmforge batch-convert -o out/ --continue-on-error a.stl bad.stl
```

选项：

```
-o, --output-dir <DIR>        输出目录 (自动创建)
    --compress <zstd>         使用 zstd 压缩 (输出 .lsmc)
    --format <text|json>      汇总输出格式 (默认 text)
    --continue-on-error       单文件失败后继续处理后续文件
```

**退出码**: 0 = 全部成功; 1 = 有错误或冲突。

**输出冲突策略**:
- 两个不同输入映射到同一输出文件名 → status=conflict
- 输出文件已存在 → status=conflict
- 默认 (无 --continue-on-error): 所有冲突项列为 conflict，非冲突项列为 skipped，不做任何转换，退出 1
- --continue-on-error: 跳过冲突项，转换非冲突文件，最终退出 1 (如有冲突或错误)

**JSON 汇总字段**:

```json
{
  "results": [
    {"file":"a.stl","output":"out/a.lsm","status":"ok","size_bytes":561,"error":null},
    {"file":"b.stl","output":"out/b.lsm","status":"conflict","size_bytes":null,"error":"output path conflicts with ..."},
    {"file":"c.stl","output":"out/c.lsm","status":"skipped","size_bytes":null,"error":null}
  ],
  "total": 3,
  "converted": 1,
  "failed": 0,
  "conflicts": 1,
  "skipped": 1
}
```

**Status values**:
- `ok` — converted successfully
- `error` — parse or write failed
- `conflict` — output path collision or existing file
- `skipped` — not converted because another input in the batch had a conflict (only without `--continue-on-error`)

### 3.4 validate — 验证文件

```bash
mmforge validate <FILE> [OPTIONS]

# 示例
mmforge validate model.step
mmforge validate *.step --summary
```

输出示例：

```
Validating: model.step
Format:     STEP (AP214)
Parse:      OK
Geometry:   OK (127 faces, 0 degenerate)
Topology:   OK (all shells closed)
Materials:  OK (5 materials)
Result:     PASS

Validating: broken.step
Format:     STEP (AP203)
Parse:      OK
Geometry:   WARNING (3 degenerate faces)
Topology:   ERROR (shell #47 not closed)
Materials:  WARNING (2 missing material references)
Result:     FAIL

Summary: 1 passed, 1 failed
```

### 3.5 formats — 查看支持的格式

```bash
mmforge formats
```

输出：

```
Supported formats:

  3D Formats:
    STEP (.step, .stp)     P0  OCCT        Read/Write
    IGES (.iges, .igs)     P1  OCCT        Read
    glTF (.gltf, .glb)     P0  gltf-rs     Read/Write
    STL (.stl)             P0  Custom      Read/Write
    OBJ (.obj)             P1  Custom      Read/Write

  2D Formats:
    DXF (.dxf)             P0  Custom      Read
    DWG (.dwg)             P1  LibreDWG    Read

  Internal:
    LSM (.lsm)             -   Custom      Read/Write

Priority: P0 = First release, P1 = Later, P2 = Future
```

### 3.6 benchmark — 性能测试

```bash
mmforge benchmark <FILE> [OPTIONS]

# 示例
mmforge benchmark model.step
mmforge benchmark model.step --iterations 10
```

输出：

```
Benchmarking: model.step (2.3 MB)

Parse:          45.2 ms (avg of 10 iterations)
Tessellation:   128.5 ms (standard quality)
LSM Write:      12.3 ms
LSM Read:       8.7 ms

Triangles:      125,432
Memory:         18.2 MB (peak)
```

---

## 4. 实现细节

### 4.1 Crate 结构

```
crates/
├── mmforge-core/              # 核心库（被 CLI 和原生客户端共同依赖）
├── mmforge-geometry/          # 几何处理
├── mmforge-format-step/       # STEP 解析
├── mmforge-format-gltf/       # glTF 解析
├── mmforge-format-stl/        # STL 解析
├── mmforge-format-dxf/        # DXF 解析
├── mmforge-format-dwg/        # DWG 解析
├── mmforge-render/            # 渲染数据准备
│
└── mmforge-cli/               # CLI 二进制（新增）
    ├── src/
    │   ├── main.rs
    │   ├── commands/
    │   │   ├── mod.rs
    │   │   ├── info.rs
    │   │   ├── convert.rs
    │   │   ├── validate.rs
    │   │   ├── formats.rs
    │   │   └── benchmark.rs
    │   ├── output/
    │   │   ├── mod.rs
    │   │   ├── text.rs       # 文本输出格式化
    │   │   └── json.rs       # JSON 输出
    │   └── progress.rs       # 进度条显示
    └── Cargo.toml
```

### 4.2 main.rs

```rust
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "mmforge")]
#[command(version = "0.1.0")]
#[command(about = "MMForge - Industrial model parser and converter")]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// 详细输出
    #[arg(short, long, global = true)]
    verbose: bool,

    /// 静默模式
    #[arg(short, long, global = true)]
    quiet: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// 查看模型信息
    Info {
        /// 输入文件路径
        file: String,
        /// JSON 输出
        #[arg(long)]
        json: bool,
    },
    /// 格式转换
    Convert {
        /// 输入文件路径（支持多个）
        files: Vec<String>,
        /// 输出文件路径
        #[arg(short, long)]
        output: Option<String>,
        /// 输出格式
        #[arg(short, long)]
        format: Option<String>,
        /// 输出目录
        #[arg(short, long)]
        output_dir: Option<String>,
        /// 精度
        #[arg(long, default_value = "standard")]
        tessellation_quality: String,
        /// 显示进度
        #[arg(long)]
        progress: bool,
    },
    /// 验证文件
    Validate {
        /// 输入文件路径（支持多个）
        files: Vec<String>,
        /// 汇总模式
        #[arg(long)]
        summary: bool,
    },
    /// 查看支持的格式
    Formats,
    /// 性能测试
    Benchmark {
        /// 输入文件路径
        file: String,
        /// 迭代次数
        #[arg(short, long, default_value = "10")]
        iterations: usize,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Info { file, json } => {
            commands::info::run(&file, json, cli.verbose)?;
        }
        Commands::Convert { files, output, format, output_dir, tessellation_quality, progress } => {
            commands::convert::run(&files, output, format, output_dir, &tessellation_quality, progress)?;
        }
        Commands::Validate { files, summary } => {
            commands::validate::run(&files, summary)?;
        }
        Commands::Formats => {
            commands::formats::run()?;
        }
        Commands::Benchmark { file, iterations } => {
            commands::benchmark::run(&file, iterations)?;
        }
    }

    Ok(())
}
```

### 4.3 info 命令实现

```rust
// crates/mmforge-cli/src/commands/info.rs

pub fn run(file: &str, json: bool, verbose: bool) -> Result<()> {
    // 1. 读取文件
    let data = std::fs::read(file)?;

    // 2. 识别格式
    let parser = detect_format(&data)
        .ok_or_else(|| anyhow!("Unsupported file format"))?;

    // 3. 解析
    let start = Instant::now();
    let model = parser.parse(&mut data.as_slice(), &ParseOptions::default())?;
    let parse_time = start.elapsed();

    // 4. 输出
    if json {
        output_json(&model, file, parse_time)?;
    } else {
        output_text(&model, file, parse_time, verbose)?;
    }

    Ok(())
}

fn output_text(model: &LsmModel, file: &str, parse_time: Duration, verbose: bool) -> Result<()> {
    println!("File:       {}", file);
    println!("Format:     {:?}", model.header.source_format);
    println!("Parse time: {:.1} ms", parse_time.as_secs_f64() * 1000.0);
    println!();

    // 几何统计
    let stats = model.geometry_stats();
    println!("Geometry:");
    println!("  Solids:   {}", stats.solids);
    println!("  Faces:    {}", stats.faces);
    println!("  Edges:    {}", stats.edges);
    println!("  Vertices: {}", stats.vertices);
    println!();

    // 包围盒
    let bbox = model.header.bounding_box;
    println!("Bounding Box:");
    println!("  Min:  ({:.2}, {:.2}, {:.2})", bbox.min[0], bbox.min[1], bbox.min[2]);
    println!("  Max:  ({:.2}, {:.2}, {:.2})", bbox.max[0], bbox.max[1], bbox.max[2]);
    println!("  Size: {:.2} × {:.2} × {:.2}",
        bbox.max[0] - bbox.min[0],
        bbox.max[1] - bbox.min[1],
        bbox.max[2] - bbox.min[2],
    );

    Ok(())
}
```

### 4.4 convert 命令实现

```rust
// crates/mmforge-cli/src/commands/convert.rs

pub fn run(
    files: &[String],
    output: Option<String>,
    format: Option<String>,
    output_dir: Option<String>,
    tessellation_quality: &str,
    show_progress: bool,
) -> Result<()> {
    for file in files {
        println!("Converting: {}", file);

        // 读取 & 解析
        let data = std::fs::read(file)?;
        let parser = detect_format(&data)
            .ok_or_else(|| anyhow!("Unsupported format: {}", file))?;

        let model = if show_progress {
            let pb = ProgressBar::new(data.len() as u64);
            pb.set_style(ProgressStyle::default_bar()
                .template("{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {bytes}/{total_bytes}"));
            parser.parse(&mut data.as_slice(), &ParseOptions::default())?
        } else {
            parser.parse(&mut data.as_slice(), &ParseOptions::default())?
        };

        // 确定输出路径
        let out_path = match (&output, &output_dir) {
            (Some(o), _) => PathBuf::from(o),
            (_, Some(dir)) => {
                let stem = Path::new(file).file_stem().unwrap();
                let ext = format.as_deref().unwrap_or("lsm");
                PathBuf::from(dir).join(format!("{}.{}", stem.to_str().unwrap(), ext))
            }
            _ => {
                let stem = Path::new(file).file_stem().unwrap();
                PathBuf::from(format!("{}.lsm", stem.to_str().unwrap()))
            }
        };

        // 写入输出
        match format.as_deref() {
            Some("lsm") | None => {
                model.write_to_file(&out_path)?;
            }
            Some("gltf") => {
                convert_to_gltf(&model, &out_path)?;
            }
            Some("stl") => {
                let opts = tessellation_options(tessellation_quality);
                convert_to_stl(&model, &out_path, &opts)?;
            }
            _ => {
                return Err(anyhow!("Unsupported output format: {}", format.unwrap()));
            }
        }

        println!("  → {} ({:.1} ms)", out_path.display(), start.elapsed().as_secs_f64() * 1000.0);
    }

    Ok(())
}
```

---

## 5. 依赖

```toml
# crates/mmforge-cli/Cargo.toml
[package]
name = "mmforge-cli"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "mmforge"
path = "src/main.rs"

[dependencies]
mmforge-core = { path = "../mmforge-core" }
mmforge-format-step = { path = "../mmforge-format-step" }
mmforge-format-gltf = { path = "../mmforge-format-gltf" }
mmforge-format-stl = { path = "../mmforge-format-stl" }
mmforge-format-dxf = { path = "../mmforge-format-dxf" }
mmforge-format-dwg = { path = "../mmforge-format-dwg" }
mmforge-geometry = { path = "../mmforge-geometry" }

clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
indicatif = "0.17"  # 进度条
colored = "2"       # 终端颜色
```

---

## 6. 安装方式

```bash
# 从源码编译
cargo install --path crates/mmforge-cli

# 从 crates.io 安装（发布后）
cargo install mmforge-cli

# 预编译二进制（GitHub Releases）
# macOS
curl -L https://github.com/.../mmforge-macos -o /usr/local/bin/mmforge

# Linux
curl -L https://github.com/.../mmforge-linux -o /usr/local/bin/mmforge

# Windows
# 下载 mmforge.exe
```

---

## 7. 与原生客户端的关系

```
┌─────────────────────────────────────────────┐
│                                             │
│   mmforge-core (库)                              │
│   ├── 所有解析逻辑                           │
│   ├── LSM 数据模型                          │
│   └── Tessellation                          │
│                                             │
│   两个消费者：                                │
│                                             │
│   ┌─────────────┐    ┌──────────────────┐  │
│   │   mmforge-cli    │    │ Native Clients   │  │
│   │   (二进制)   │    │   (FFI 桥接)     │  │
│   │             │    │                  │  │
│   │  命令行使用   │    │  GUI 使用        │  │
│   │  批量处理    │    │  交互式查看       │  │
│   │  CI/CD 集成  │    │  移动端/桌面端    │  │
│   └─────────────┘    └──────────────────┘  │
│                                             │
└─────────────────────────────────────────────┘
```

- **核心代码只写一份**，在 `mmforge-core` 库中
- CLI 和原生客户端都是消费层，不包含解析逻辑
- CLI 适合：开发者、批量处理、自动化流水线
- 原生客户端适合：终端用户、交互式查看、平台深度集成

---

*本文档随开发持续更新。*
