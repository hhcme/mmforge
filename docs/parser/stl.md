# STL 解析器

> STL (Stereolithography) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | 自研（无外部依赖） |
| 优先级 | P0 |
| 数据类型 | 三角网格 |
| 特点 | 格式极简，只有三角形，无颜色/材质/结构树 |

---

## 两种格式

### ASCII STL

```
solid name
  facet normal ni nj nk
    outer loop
      vertex v1x v1y v1z
      vertex v2x v2y v2z
      vertex v3x v3y v3z
    endloop
  endfacet
endsolid name
```

### Binary STL

```
[80 bytes]  header (任意数据)
[4 bytes]   num_triangles (u32, little-endian)
[50 bytes]  × num_triangles:
  [12 bytes]  normal (3 × f32)
  [36 bytes]  vertices (9 × f32)
  [2 bytes]   attribute byte count
```

---

## 解析流程

```
STL 文件
  │
  ▼
┌─────────────────────────────────────┐
│  格式判断                            │
│  前 5 字节 == "solid"?              │
│  ├── 是 → 可能是 ASCII STL          │
│  └── 否 → Binary STL               │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌──────────────┐ ┌──────────────┐
│ ASCII 解析   │ │ Binary 解析   │
│              │ │              │
│ 逐行读取     │ │ 直接读取      │
│ 解析 vertex  │ │ 二进制偏移    │
│ 解析 normal  │ │ 批量处理      │
└──────┬───────┘ └──────┬───────┘
       │               │
       └───────┬───────┘
               ▼
          LSM Model
```

---

## 代码示例

### 格式判断

```rust
fn is_ascii_stl(data: &[u8]) -> bool {
    // 检查前 5 个字节是否为 "solid"
    data.len() >= 5 && &data[..5] == b"solid"
}
```

### Binary STL 解析

```rust
fn parse_binary_stl(data: &[u8], lsm: &mut LsmModel) -> Result<()> {
    let num_triangles = u32::from_le_bytes(data[80..84].try_into()?) as usize;

    let mut positions = Vec::with_capacity(num_triangles * 3);
    let mut normals = Vec::with_capacity(num_triangles * 3);

    for i in 0..num_triangles {
        let offset = 84 + i * 50;

        // 法线
        let nx = f32::from_le_bytes(data[offset..offset+4].try_into()?);
        let ny = f32::from_le_bytes(data[offset+4..offset+8].try_into()?);
        let nz = f32::from_le_bytes(data[offset+8..offset+12].try_into()?);

        // 三个顶点
        for v in 0..3 {
            let v_offset = offset + 12 + v * 12;
            let x = f32::from_le_bytes(data[v_offset..v_offset+4].try_into()?);
            let y = f32::from_le_bytes(data[v_offset+4..v_offset+8].try_into()?);
            let z = f32::from_le_bytes(data[v_offset+8..v_offset+12].try_into()?);
            positions.push([x, y, z]);
            normals.push([nx, ny, nz]);
        }
    }

    lsm.add_mesh(LsmMesh { positions, normals, indices: None, material_id: None });
    Ok(())
}
```

### ASCII STL 解析

```rust
fn parse_ascii_stl(data: &[u8], lsm: &mut LsmModel) -> Result<()> {
    let text = std::str::from_utf8(data)?;
    let mut positions = Vec::new();
    let mut normals = Vec::new();

    let mut current_normal = [0.0f32; 3];
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("facet normal") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            current_normal = [
                parts[2].parse()?,
                parts[3].parse()?,
                parts[4].parse()?,
            ];
        } else if line.starts_with("vertex") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            positions.push([
                parts[1].parse()?,
                parts[2].parse()?,
                parts[3].parse()?,
            ]);
            normals.push(current_normal);
        }
    }

    lsm.add_mesh(LsmMesh { positions, normals, indices: None, material_id: None });
    Ok(())
}
```

---

## 性能优化

### Binary STL 快速解析

```rust
/// 零拷贝 Binary STL 解析
fn parse_binary_stl_fast(data: &[u8]) -> Result<StlData> {
    let num_triangles = u32::from_le_bytes(data[80..84].try_into()?) as usize;

    // 直接引用原始数据，不复制
    let triangle_data = &data[84..84 + num_triangles * 50];

    Ok(StlData {
        num_triangles,
        triangle_data, // 零拷贝引用
    })
}

/// 按需提取顶点（不一次性全部解析）
fn extract_vertices(stl: &StlData, triangle_idx: usize) -> [[f32; 3]; 3] {
    let offset = triangle_idx * 50;
    let data = &stl.triangle_data[offset..offset + 50];

    unsafe {
        // 直接内存映射，最快
        std::ptr::read_unaligned(data[12..48].as_ptr() as *const [[f32; 3]; 3])
    }
}
```

### 顶点去重

STL 存储重复顶点，渲染前需要去重：

```rust
/// 顶点去重算法
fn deduplicate_vertices(
    positions: &[[f32; 3]],
    normals: &[[f32; 3]],
) -> (Vec<[f32; 3]>, Vec<[f32; 3]>, Vec<u32>) {
    let mut unique_vertices: HashMap<[u32; 3], u32> = HashMap::new();
    let mut unique_positions = Vec::new();
    let mut unique_normals = Vec::new();
    let mut indices = Vec::new();

    for (pos, normal) in positions.iter().zip(normals) {
        // 量化浮点数为整数键（处理精度问题）
        let key = [
            (pos[0] * 1000.0) as u32,
            (pos[1] * 1000.0) as u32,
            (pos[2] * 1000.0) as u32,
        ];

        if let Some(&idx) = unique_vertices.get(&key) {
            indices.push(idx);
        } else {
            let idx = unique_positions.len() as u32;
            unique_vertices.insert(key, idx);
            unique_positions.push(*pos);
            unique_normals.push(*normal);
            indices.push(idx);
        }
    }

    (unique_positions, unique_normals, indices)
}
```

### 并行解析

```rust
use rayon::prelude::*;

fn parse_stl_parallel(data: &[u8]) -> Result<LsmModel> {
    let num_triangles = u32::from_le_bytes(data[80..84].try_into()?) as usize;
    let triangle_data = &data[84..];

    // 并行解析三角形
    let results: Vec<_> = (0..num_triangles)
        .into_par_iter()
        .map(|i| {
            let offset = i * 50;
            parse_triangle(&triangle_data[offset..offset + 50])
        })
        .collect();

    // 合并结果
    let mut positions = Vec::with_capacity(num_triangles * 3);
    let mut normals = Vec::with_capacity(num_triangles * 3);
    for (pos, norm) in results {
        positions.extend_from_slice(&pos);
        normals.push(norm);
    }

    Ok(LsmModel::from_mesh(positions, normals))
}
```

---

## 局限性

| 局限 | 说明 |
|------|------|
| 无颜色/材质 | STL 只有几何，没有外观信息 |
| 无结构树 | 所有三角形在一个扁平列表中 |
| 精度低 | f32 浮点数，不如 STEP 精确 |
| 文件大 | 无压缩，每个三角形重复存储顶点 |

---

## 性能基准

| 文件大小 | 三角形数 | 解析时间 | 内存峰值 |
|---------|---------|---------|---------|
| < 1MB | < 10K | < 5ms | < 2MB |
| 1-10MB | 10K - 100K | 5 - 50ms | 2 - 20MB |
| 10-100MB | 100K - 1M | 50ms - 500ms | 20 - 200MB |
| > 100MB | > 1M | > 500ms | 需要流式加载 |
