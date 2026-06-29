# 解析层错误处理与测试

> MMForge 解析层的错误处理策略和测试设计。
>
> 最后更新：2026-06-29

---

## 1. 错误类型定义

```rust
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("Unsupported file format")]
    UnsupportedFormat,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("STEP parse failed: {message}")]
    StepParseFailed { message: String },

    #[error("IGES parse failed: {message}")]
    IgesParseFailed { message: String },

    #[error("glTF parse failed: {0}")]
    GltfParseFailed(#[from] gltf::Error),

    #[error("STL parse failed: {message}")]
    StlParseFailed { message: String },

    #[error("DXF parse failed at line {line}: {message}")]
    DxfParseFailed { line: usize, message: String },

    #[error("DWG parse failed: {message}")]
    DwgParseFailed { message: String },

    #[error("Geometry error: {0}")]
    Geometry(#[from] GeometryError),

    #[error("Tessellation failed: {message}")]
    TessellationFailed { message: String },

    #[error("Out of memory (file too large)")]
    OutOfMemory,

    #[error("Operation cancelled by user")]
    Cancelled,
}
```

---

## 2. 错误处理策略

| 场景 | 策略 |
|------|------|
| 格式不支持 | 返回 `UnsupportedFormat`，提示用户支持的格式列表 |
| 文件损坏 | 尽可能解析已读取的部分，返回 warning + 部分结果 |
| 内存不足 | 返回 `OutOfMemory`，提示用户降低精度或使用流式加载 |
| 不支持的实体 | 跳过该实体，记录 warning，继续解析其他实体 |
| 精度问题 | 使用 f64 保持精度，记录精度损失 warning |

---

## 3. 测试策略

### 3.1 单元测试

每个解析器需要：
- 正确解析已知格式的测试文件
- 处理边界情况（空文件、损坏文件、超大文件）
- 验证 LSM 输出的完整性

### 3.2 测试文件

```
tests/
├── fixtures/
│   ├── step/
│   │   ├── simple_box.step        # 简单立方体
│   │   ├── cylinder.step          # 圆柱体
│   │   ├── assembly.step          # 装配体
│   │   └── complex_surface.step   # 复杂曲面
│   ├── gltf/
│   │   ├── triangle.gltf          # 最简单模型
│   │   ├── textured_box.gltf      # 带材质
│   │   └── duck.gltf              # 标准测试模型
│   ├── stl/
│   │   ├── ascii.stl
│   │   └── binary.stl
│   ├── dxf/
│   │   ├── lines_arcs.dxf
│   │   ├── text_dimensions.dxf
│   │   └── blocks.dxf
│   └── dwg/
│       └── basic.dwg
└── integration/
    └── format_roundtrip.rs        # 格式转换测试
```

### 3.3 性能基准测试

```rust
#[bench]
fn bench_parse_step_simple(b: &mut Bencher) {
    let data = include_bytes!("fixtures/step/simple_box.step");
    b.iter(|| parse_step(data));
}

#[bench]
fn bench_tessellate_complex(b: &mut Bencher) {
    let shape = load_test_shape("complex_surface.step");
    b.iter(|| tessellate(&shape, &TessellationOptions::default()));
}
```
