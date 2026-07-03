# LSM 运行时模型与文件格式草案

> MMForge Model (LSM) 统一运行时模型定义，以及未来持久化文件格式草案。
>
> 最后更新：2026-06-29

---

## 1. 概述

LSM（MMForge Model）是本项目的核心运行时模型，所有源文件解析后统一转换为 LSM，渲染器只消费 LSM 数据。早期重点是稳定内存模型、查询接口和渲染数据契约；持久化 `.lsm` 文件格式在核心链路稳定后再冻结。

**设计原则：**
- 运行时优先：先服务解析、渲染、测量、标注等内存工作流
- 持久化后置：`.lsm` 文件格式等主要模块稳定后再固化
- 可扩展：支持未来添加标注、测量、PMI 等附加数据
- 版本化：格式有版本号，支持向前兼容

> 本文档中的二进制文件结构是后续持久化方向草案，不作为早期实现的稳定兼容承诺。

---

## 2. 未来文件结构草案

```
┌──────────────────────────────────┐
│           File Header            │  固定长度
├──────────────────────────────────┤
│           TOC (目录)             │  各 Section 的偏移/长度
├──────────────────────────────────┤
│         Section: Header          │  元数据
├──────────────────────────────────┤
│         Section: SceneTree       │  场景树
├──────────────────────────────────┤
│         Section: Geometry        │  几何数据（B-Rep / Mesh）
├──────────────────────────────────┤
│         Section: Materials       │  材质
├──────────────────────────────────┤
│         Section: Textures        │  纹理（可选）
├──────────────────────────────────┤
│         Section: Metadata        │  扩展元数据
└──────────────────────────────────┘
```

---

## 3. File Header（草案）

固定 64 字节：

```rust
#[repr(C, packed)]
pub struct LsmFileHeader {
    /// 魔数 "LSMD" (4 bytes)
    pub magic: [u8; 4],
    /// 格式版本 (2 bytes)
    pub version: u16,
    /// 预留 (2 bytes)
    pub reserved: u16,
    /// TOC 偏移量 (8 bytes)
    pub toc_offset: u64,
    /// TOC 条目数量 (4 bytes)
    pub toc_count: u32,
    /// 源格式标识 (4 bytes)
    pub source_format: u32,
    /// 预留 (40 bytes)
    pub reserved2: [u8; 40],
}
```

---

## 4. TOC (Table of Contents，草案)

每个 Section 在 TOC 中有一个条目：

```rust
#[repr(C, packed)]
pub struct TocEntry {
    /// Section 类型标识 (4 bytes)
    pub section_type: u32,
    /// Section 偏移量 (8 bytes)
    pub offset: u64,
    /// Section 数据长度 (8 bytes)
    pub length: u64,
}
```

Section 类型：

| ID | 名称 | 说明 |
|----|------|------|
| 0x01 | Header | 元数据 |
| 0x02 | SceneTree | 场景树 |
| 0x03 | Geometry | 几何数据 |
| 0x04 | Materials | 材质 |
| 0x05 | Textures | 纹理 |
| 0x06 | Metadata | 扩展元数据 |
| 0x10 | Annotations | 标注（v2.0+） |
| 0x11 | Measurements | 测量记录（v2.0+） |
| 0x12 | PMI | 产品制造信息（v2.0+） |

---

## 5. 数据结构定义

### 5.1 Header Section

```rust
pub struct LsmHeader {
    /// 源文件格式
    pub source_format: SourceFormat,
    /// 源文件名
    pub source_filename: String,
    /// 长度单位
    pub units: Units,
    /// 精度
    pub precision: f64,
    /// 包围盒
    pub bounding_box: BoundingBox,
    /// 创建时间
    pub created_at: u64,
    /// 工具版本
    pub tool_version: String,
}

pub enum SourceFormat {
    Step,
    Iges,
    Gltf,
    Stl,
    Dxf,
    Dwg,
    Unknown(u32),
}

pub enum Units {
    Millimeter,
    Centimeter,
    Meter,
    Inch,
    Foot,
    Custom(f64), // 自定义换算系数
}

pub struct BoundingBox {
    pub min: [f64; 3],
    pub max: [f64; 3],
}
```

### 5.2 SceneTree Section

```rust
pub struct SceneTree {
    /// 根节点列表
    pub roots: Vec<NodeId>,
    /// 所有节点（扁平存储，通过 ID 引用）
    pub nodes: Vec<SceneNode>,
}

pub struct SceneNode {
    /// 节点 ID
    pub id: NodeId,
    /// 节点名称
    pub name: String,
    /// 变换矩阵（4x4）
    pub transform: [f64; 16],
    /// 父节点 ID（None = 根节点）
    pub parent: Option<NodeId>,
    /// 子节点 ID 列表
    pub children: Vec<NodeId>,
    /// 关联的几何数据 ID（None = 无几何体）
    pub geometry: Option<GeometryId>,
    /// 图层名（2D 格式用）
    pub layer: Option<String>,
    /// 是否可见
    pub visible: bool,
    /// 颜色覆盖（None = 使用材质颜色）
    pub color_override: Option<[f32; 4]>,
}

pub struct NodeId(pub u32);
pub struct GeometryId(pub u32);
```

### 5.3 Geometry Section

几何数据有两种类型：B-Rep（来自 STEP/IGES）和 Mesh（来自 glTF/STL 或 tessellation 输出）。

```rust
pub struct GeometrySection {
    pub geometries: Vec<Geometry>,
}

pub enum Geometry {
    /// B-Rep 边界表示（保留完整几何信息）
    BRep(BRepGeometry),
    /// 三角网格（已 tessellation 或源格式就是网格）
    Mesh(MeshGeometry),
    /// 2D 几何（来自 DXF/DWG）
    Drawing2D(Drawing2DGeometry),
}

// ─── B-Rep 几何 ───

pub struct BRepGeometry {
    pub solids: Vec<Solid>,
}

pub struct Solid {
    pub shells: Vec<Shell>,
}

pub struct Shell {
    pub faces: Vec<Face>,
}

pub struct Face {
    /// 曲面定义
    pub surface: Surface,
    /// 边界环（外环 + 内环/孔）
    pub wires: Vec<Wire>,
    /// 朝向
    pub orientation: Orientation,
}

pub struct Wire {
    pub edges: Vec<Edge>,
    pub orientation: Orientation,
}

pub struct Edge {
    pub curve: Curve,
    pub start_vertex: VertexId,
    pub end_vertex: VertexId,
    pub orientation: Orientation,
}

pub struct Vertex {
    pub id: VertexId,
    pub point: [f64; 3],
}

pub enum Orientation {
    Forward,
    Reversed,
}

// ─── 曲面类型 ───

pub enum Surface {
    Plane {
        origin: [f64; 3],
        normal: [f64; 3],
    },
    Cylinder {
        axis_origin: [f64; 3],
        axis_direction: [f64; 3],
        radius: f64,
    },
    Cone {
        axis_origin: [f64; 3],
        axis_direction: [f64; 3],
        radius: f64,
        semi_angle: f64,
    },
    Sphere {
        center: [f64; 3],
        radius: f64,
    },
    Torus {
        axis_origin: [f64; 3],
        axis_direction: [f64; 3],
        major_radius: f64,
        minor_radius: f64,
    },
    BSplineSurface {
        degree_u: u32,
        degree_v: u32,
        poles: Vec<[f64; 3]>,      // 控制点
        weights: Vec<f64>,          // 权重
        knots_u: Vec<f64>,          // U 向节点向量
        knots_v: Vec<f64>,          // V 向节点向量
        multiplicities_u: Vec<u32>,
        multiplicities_v: Vec<u32>,
    },
    OffsetSurface {
        surface: Box<Surface>,
        offset: f64,
    },
    // ... 其他曲面类型
}

// ─── 曲线类型 ───

pub enum Curve {
    Line {
        origin: [f64; 3],
        direction: [f64; 3],
    },
    Circle {
        center: [f64; 3],
        axis: [f64; 3],
        radius: f64,
    },
    Ellipse {
        center: [f64; 3],
        major_axis: [f64; 3],
        minor_axis: [f64; 3],
        major_radius: f64,
        minor_radius: f64,
    },
    BSplineCurve {
        degree: u32,
        poles: Vec<[f64; 3]>,
        weights: Vec<f64>,
        knots: Vec<f64>,
        multiplicities: Vec<u32>,
    },
    TrimmedCurve {
        curve: Box<Curve>,
        start_parameter: f64,
        end_parameter: f64,
    },
    // ... 其他曲线类型
}

// ─── 三角网格几何 ───

pub struct MeshGeometry {
    /// 顶点位置
    pub positions: Vec<[f32; 3]>,
    /// 顶点法线
    pub normals: Vec<[f32; 3]>,
    /// 顶点 UV（可选）
    pub uvs: Option<Vec<[f32; 2]>>,
    /// 三角形索引
    pub indices: Vec<u32>,
    /// 子网格（按材质分组）
    pub sub_meshes: Vec<SubMesh>,
}

pub struct SubMesh {
    pub index_offset: u32,
    pub index_count: u32,
    pub material_id: Option<MaterialId>,
}

// ─── 2D 几何 ───

pub struct Drawing2DGeometry {
    pub entities: Vec<Entity2D>,
    pub layers: Vec<Layer>,
    pub blocks: Vec<Block>,
}

pub enum Entity2D {
    Line {
        start: [f64; 2],
        end: [f64; 2],
    },
    Arc {
        center: [f64; 2],
        radius: f64,
        start_angle: f64,
        end_angle: f64,
    },
    Circle {
        center: [f64; 2],
        radius: f64,
    },
    Polyline {
        vertices: Vec<PolylineVertex>,
        closed: bool,
    },
    Spline {
        degree: u32,
        control_points: Vec<[f64; 2]>,
        knots: Vec<f64>,
    },
    Text {
        position: [f64; 2],
        content: String,
        height: f64,
        rotation: f64,
        style_id: Option<u32>,
    },
    MText {
        position: [f64; 2],
        content: String,
        width: f64,
        height: f64,
        rotation: f64,
    },
    Dimension {
        dim_type: DimensionType,
        definition_point: [f64; 2],
        text_position: [f64; 2],
        measurement: f64,
    },
    Hatch {
        boundary: Vec<Entity2D>,
        pattern: String,
        scale: f64,
    },
    Insert {
        block_id: u32,
        position: [f64; 2],
        scale: [f64; 2],
        rotation: f64,
    },
}

pub struct PolylineVertex {
    pub point: [f64; 2],
    pub bulge: f64, // 0.0 = 直线段，非零 = 圆弧段
}

pub struct Layer {
    pub id: u32,
    pub name: String,
    pub color: [f32; 4],
    pub visible: bool,
    pub frozen: bool,
}

pub struct Block {
    pub id: u32,
    pub name: String,
    pub base_point: [f64; 2],
    pub entities: Vec<Entity2D>,
}
```

### 5.4 Materials Section

```rust
pub struct MaterialsSection {
    pub materials: Vec<Material>,
}

pub struct Material {
    pub id: MaterialId,
    pub name: String,
    pub color: [f32; 4],          // RGBA
    pub metallic: f32,            // 0.0 - 1.0
    pub roughness: f32,           // 0.0 - 1.0
    pub emissive: [f32; 3],       // 自发光颜色
    pub alpha_mode: AlphaMode,
    pub double_sided: bool,
    pub base_color_texture: Option<TextureId>,
    pub normal_texture: Option<TextureId>,
    pub metallic_roughness_texture: Option<TextureId>,
}

pub enum MaterialId(pub u32);
pub enum TextureId(pub u32);

pub enum AlphaMode {
    Opaque,
    Mask(f32),   // 阈值
    Blend,
}
```

### 5.5 Textures Section

```rust
pub struct TexturesSection {
    pub textures: Vec<Texture>,
}

pub struct Texture {
    pub id: TextureId,
    pub width: u32,
    pub height: u32,
    pub format: TextureFormat,
    pub data: Vec<u8>,
}

pub enum TextureFormat {
    Rgba8,
    Rgb8,
    Bc1,  // DXT1
    Bc3,  // DXT5
    Etc2,
    Astc,
}
```

### 5.6 Metadata Section

```rust
pub struct MetadataSection {
    pub entries: HashMap<String, String>,
}
```

---

## 6. 序列化格式（草案）

未来 LSM 文件可以使用自定义二进制格式：

- 所有多字节数据使用 **小端序 (Little Endian)**
- 字符串使用 **UTF-8 编码**，前缀 4 字节长度
- 数组使用 **4 字节长度前缀**
- 浮点数使用 **IEEE 754**

### 6.1 编码示例

```
u8:   [1 byte]
u16:  [2 bytes, little endian]
u32:  [4 bytes, little endian]
u64:  [8 bytes, little endian]
f32:  [4 bytes, IEEE 754 LE]
f64:  [8 bytes, IEEE 754 LE]
bool: [1 byte, 0x00 = false, 0x01 = true]
string: [4 bytes length] [UTF-8 data]
array<T>: [4 bytes count] [T × count]
option<T>: [1 byte tag] [T if tag = 0x01]
```

---

## 7. 版本兼容（草案）

| 版本 | 变更 |
|------|------|
| v1.0 | 初始版本 |
| v2.0 | 新增 Annotations/Measurements/PMI Section |

- 读取器必须忽略未知的 Section 类型
- 新增字段只能追加到结构末尾
- 删除字段用 Reserved 占位

---

## 8. 文件扩展名

- `.lsm` — 标准 LSM 文件（v1, 已冻结）
- `.lsmc` — 压缩 LSM 文件（zstd 压缩，v1 已实现）。详见 `docs/progress/2026-07-03-phase7-lsmc-compression.md`。格式：24-byte header（magic `LSMC` + version 1 + zstd method=1 + uncompressed_size） + zstd-compressed `.lsm` v1 payload。

## 9. 实现状态（2026-07-03）

- `.lsm` v1 reader/writer: `crates/mmforge-core/src/lsm/{reader,writer}.rs` — 已完成，含 golden fixture + 19 个边界测试。
- `.lsmc` v1 reader/writer: `crates/mmforge-core/src/lsm/lsmc.rs` — 已完成，含 6 个单元测试 + 7 个 CLI 集成测试。
- CLI `info/validate/convert/benchmark`: 支持 `.lsm` 和 `.lsmc` 透明读写。
- 压缩方法: zstd (MIT/Apache-2.0)。LZ4 尚未实现。
