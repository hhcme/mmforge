# glTF 解析器

> glTF (GL Transmission Format) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | gltf-rs (MIT) |
| 优先级 | P0 |
| 数据类型 | 三角网格（Mesh） |
| 特点 | 现代格式，已经是三角网格，不需要 tessellation |

---

## glTF 文件结构

两种形式：

**glTF (JSON + .bin)**:
```json
{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [{ "nodes": [0] }],
  "nodes": [
    { "mesh": 0, "matrix": [...] },
    { "children": [1, 2] }
  ],
  "meshes": [{
    "primitives": [{
      "attributes": { "POSITION": 0, "NORMAL": 1 },
      "indices": 2,
      "material": 0
    }]
  }],
  "accessors": [...],
  "bufferViews": [...],
  "buffers": [{ "uri": "data.bin" }],
  "materials": [...]
}
```

**glB (二进制)**:
- 魔数: `glTF`
- JSON chunk + Binary chunk 嵌入单个文件

---

## 解析流程

```
glTF 文件 (.gltf JSON + .bin / .glb 二进制)
  │
  ▼
┌─────────────────────────────────────┐
│  gltf-rs 解析                       │
│  ├── 解析 JSON → Gltf 结构          │
│  ├── 加载 buffer                    │
│  │   (.bin 文件或 embedded base64)   │
│  ├── 解析 accessor                  │
│  │   → 提取顶点/索引数据             │
│  ├── 解析 node → 场景树             │
│  ├── 解析 mesh → 几何数据           │
│  ├── 解析 material → PBR 材质       │
│  └── 解析 texture → 纹理图片        │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  转换为 LSM                         │
│  ├── Node → LSM::SceneNode         │
│  ├── Mesh → LSM::Mesh              │
│  │   (已经是三角网格)                │
│  ├── Material → LSM::Material       │
│  └── Texture → LSM::Texture         │
└──────────────┬──────────────────────┘
               │
               ▼
          LSM Model
```

---

## 代码示例

```rust
fn parse_gltf(data: &[u8]) -> Result<LsmModel> {
    let gltf = gltf::Gltf::from_slice(data)?;
    let buffers = load_buffers(&gltf, data)?;

    let mut lsm = LsmModel::new();

    for scene in gltf.scenes() {
        for node in scene.nodes() {
            process_node(&node, &buffers, &mut lsm)?;
        }
    }

    Ok(lsm)
}

fn process_node(
    node: &gltf::Node,
    buffers: &[gltf::buffer::Data],
    lsm: &mut LsmModel,
) -> Result<()> {
    let transform = node.transform().matrix();

    if let Some(mesh) = node.mesh() {
        for primitive in mesh.primitives() {
            let positions = read_positions(&primitive, buffers)?;
            let normals = read_normals(&primitive, buffers)?;
            let indices = read_indices(&primitive, buffers)?;

            lsm.add_mesh(LsmMesh {
                positions,
                normals,
                indices,
                material_id: primitive.material().index(),
            });
        }
    }

    for child in node.children() {
        process_node(&child, buffers, lsm)?;
    }

    Ok(())
}
```

---

## Buffer 解析算法

### Accessor → 实际数据

glTF 的数据访问链：

```
Buffer (原始二进制数据)
  │
  ▼
BufferView (切片：offset + length + stride)
  │
  ▼
Accessor (类型化解释：componentType + count + min/max)
  │
  ▼
实际数据 (Vec<f32> / Vec<u32> / ...)
```

```rust
fn read_accessor<T: Copy>(
    accessor: &gltf::Accessor,
    buffers: &[gltf::buffer::Data],
) -> Vec<T> {
    let view = accessor.view().unwrap();
    let buffer = &buffers[view.buffer().index()];
    let start = view.offset() + accessor.offset();
    let stride = view.stride().unwrap_or(std::mem::size_of::<T>());

    let mut result = Vec::with_capacity(accessor.count());

    for i in 0..accessor.count() {
        let offset = start + i * stride;
        let value = unsafe {
            std::ptr::read_unaligned(buffer[offset..].as_ptr() as *const T)
        };
        result.push(value);
    }

    result
}
```

### 变换矩阵组合

glTF 节点的变换可以是 matrix 或 TRS 分解：

```rust
fn node_transform(node: &gltf::Node) -> [[f32; 4]; 4] {
    match node.transform() {
        gltf::scene::Transform::Matrix { matrix } => matrix,
        gltf::scene::Transform::Decomposed {
            translation,
            rotation,
            scale,
        } => {
            let t = Mat4::translate(translation);
            let r = Mat4::from_quat(rotation);
            let s = Mat4::scale(scale);
            (t * r * s).into()
        }
    }
}

/// 组合父节点变换
fn world_transform(node: &gltf::Node, parent_transform: &Mat4) -> Mat4 {
    let local = node_transform(node);
    parent_transform * local
}
```

---

## PBR 材质解析

glTF 使用 metallic-roughness 工作流：

```rust
fn parse_material(material: &gltf::Material) -> LsmMaterial {
    let pbr = material.pbr_metallic_roughness();

    LsmMaterial {
        base_color_factor: pbr.base_color_factor(),
        metallic_factor: pbr.metallic_factor(),
        roughness_factor: pbr.roughness_factor(),
        base_color_texture: pbr.base_color_texture()
            .map(|t| load_texture(&t.texture())),
        normal_texture: material.normal_texture()
            .map(|t| load_texture(&t.texture())),
        emissive_factor: material.emissive_factor(),
        alpha_mode: match material.alpha_mode() {
            gltf::material::AlphaMode::Opaque => AlphaMode::Opaque,
            gltf::material::AlphaMode::Mask => AlphaMode::Mask(material.alpha_cutoff()),
            gltf::material::AlphaMode::Blend => AlphaMode::Blend,
        },
        double_sided: material.double_sided(),
    }
}
```

---

## 性能优化

### 零拷贝 Buffer 访问

```rust
// ❌ 低效：复制数据
let positions: Vec<[f32; 3]> = read_accessor(&accessor, &buffers);

// ✅ 高效：直接引用 buffer 数据
fn positions_slice<'a>(
    accessor: &gltf::Accessor,
    buffers: &'a [gltf::buffer::Data],
) -> &'a [[f32; 3]] {
    let view = accessor.view().unwrap();
    let buffer = &buffers[view.buffer().index()];
    let start = view.offset() + accessor.offset();
    let count = accessor.count();

    unsafe {
        std::slice::from_raw_parts(
            buffer[start..].as_ptr() as *const [f32; 3],
            count,
        )
    }
}
```

### 纹理异步加载

```rust
async fn load_textures_parallel(
    materials: &[gltf::Material],
    buffers: &[gltf::buffer::Data],
) -> Vec<Texture> {
    let futures: Vec<_> = materials.iter()
        .flat_map(|m| m.pbr_metallic_roughness().base_color_texture())
        .map(|t| load_texture_async(&t.texture(), buffers))
        .collect();

    futures::future::join_all(futures).await
}
```

---

## glTF 特点

| 特点 | 说明 |
|------|------|
| 三角网格 | 不需要 B-Rep 转换，直接可用 |
| PBR 材质 | metallic-roughness workflow |
| 场景树 | 支持层级结构、变换矩阵 |
| 纹理 | 支持嵌入或外部引用 |
| 动画/骨骼 | 首个完整查看器版本暂不需要，后续可扩展 |
| Rust 生态 | gltf-rs 成熟稳定 |

---

## 性能基准

| 模型大小 | 三角形数 | 解析时间 | 内存峰值 |
|---------|---------|---------|---------|
| < 1MB | < 10K | < 10ms | < 5MB |
| 1-10MB | 10K - 100K | 10 - 50ms | 5 - 50MB |
| 10-100MB | 100K - 1M | 50ms - 500ms | 50 - 500MB |
| > 100MB | > 1M | > 500ms | 需要流式加载 |
