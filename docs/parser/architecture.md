# 解析器架构设计

> MMForge 解析层的接口设计、格式识别算法和 crate 结构。
>
> 最后更新：2026-06-29

---

## 1. 统一接口设计

所有格式解析器实现同一个 trait：

```rust
/// 格式解析器统一接口
pub trait FormatParser: Send + Sync {
    /// 解析器名称
    fn name(&self) -> &str;

    /// 支持的文件扩展名
    fn extensions(&self) -> &[&str];

    /// 通过文件头判断是否能解析该文件
    fn can_parse(&self, header: &[u8]) -> bool;

    /// 解析文件，返回 LSM 模型
    fn parse(&self, reader: &mut dyn Read, options: &ParseOptions) -> Result<LsmModel>;

    /// 异步解析（大文件流式加载）
    fn parse_async(
        &self,
        reader: &mut dyn Read,
        options: &ParseOptions,
        progress: Option<Arc<dyn ProgressCallback>>,
    ) -> Result<LsmModel>;
}

/// 解析选项
pub struct ParseOptions {
    /// 长度单位转换目标（None = 保持原单位）
    pub target_units: Option<Units>,
    /// 是否解析几何数据（false = 只读结构树/元数据）
    pub load_geometry: bool,
    /// 是否解析材质/纹理
    pub load_materials: bool,
    /// 最大精度（用于简化大模型）
    pub max_precision: Option<f64>,
}

/// 进度回调
pub trait ProgressCallback: Send + Sync {
    fn on_progress(&self, current: u64, total: u64);
    fn on_stage(&self, stage: &str);
}
```

---

## 2. 格式识别算法

通过读取文件头部字节自动判断格式：

```rust
pub fn detect_format(header: &[u8]) -> Option<Box<dyn FormatParser>> {
    // STEP: "ISO-10303-21;"
    if header.starts_with(b"ISO-10303-21;") {
        return Some(Box::new(StepParser::new()));
    }
    // IGES: 固定列格式，第 73 列为 "S"
    if header.len() >= 80 && header[72] == b'S' {
        return Some(Box::new(IgesParser::new()));
    }
    // glTF JSON: "{"
    if header.starts_with(b"{") {
        return Some(Box::new(GltfParser::new()));
    }
    // glTF Binary (glB): 魔数 "glTF"
    if header.starts_with(b"glTF") {
        return Some(Box::new(GltfParser::new()));
    }
    // STL ASCII: "solid"
    if header.starts_with(b"solid") {
        return Some(Box::new(StlParser::new()));
    }
    // DXF: "0\nSECTION"
    if header.windows(10).any(|w| w == b"0\nSECTION\n" || w == b"  0\nSECTION") {
        return Some(Box::new(DxfParser::new()));
    }
    // DWG: "AC" + 版本号
    if header.len() >= 6 && &header[0..2] == b"AC" {
        return Some(Box::new(DwgParser::new()));
    }
    None
}
```

格式特征表：

| 格式 | 文件头特征 | 偏移 |
|------|-----------|------|
| STEP | `ISO-10303-21;` | 0 |
| IGES | 第 73 列为 `S` | 72 |
| glTF (JSON) | `{` | 0 |
| glTF (Binary) | `glTF` | 0 |
| STL (ASCII) | `solid` | 0 |
| DXF | `0\nSECTION` | 搜索 |
| DWG | `AC` + 版本号 | 0 |

---

## 3. Crate 结构

```
crates/
├── mmforge-core/              # 核心数据模型
│   ├── src/
│   │   ├── lsm/              # LSM 格式定义
│   │   │   ├── mod.rs
│   │   │   ├── header.rs
│   │   │   ├── scene.rs
│   │   │   ├── geometry.rs
│   │   │   ├── material.rs
│   │   │   ├── metadata.rs
│   │   │   └── io.rs
│   │   ├── parser.rs         # FormatParser trait
│   │   └── lib.rs
│   └── Cargo.toml
│
├── mmforge-format-step/       # STEP 解析
│   ├── src/
│   │   ├── parser.rs
│   │   ├── converter.rs
│   │   └── lib.rs
│   └── Cargo.toml
│
├── mmforge-format-gltf/       # glTF 解析
│   ├── src/
│   │   ├── parser.rs
│   │   ├── converter.rs
│   │   └── lib.rs
│   └── Cargo.toml
│
├── mmforge-format-stl/        # STL 解析
│   ├── src/
│   │   ├── ascii.rs
│   │   ├── binary.rs
│   │   ├── converter.rs
│   │   └── lib.rs
│   └── Cargo.toml
│
├── mmforge-format-dxf/        # DXF 解析
│   ├── src/
│   │   ├── parser.rs
│   │   ├── entities.rs
│   │   ├── converter.rs
│   │   └── lib.rs
│   └── Cargo.toml
│
├── mmforge-format-dwg/        # DWG 解析
│   ├── src/
│   │   ├── parser.rs
│   │   ├── converter.rs
│   │   └── lib.rs
│   └── Cargo.toml
│
└── mmforge-format-iges/       # IGES 解析
    ├── src/
    │   ├── parser.rs
    │   ├── converter.rs
    │   └── lib.rs
    └── Cargo.toml
```
