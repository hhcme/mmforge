# STEP 解析器

> STEP (ISO 10303) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | OCCT (STEPControl_Reader) |
| 优先级 | P0 |
| 协议 | AP203, AP214 |
| 数据类型 | B-Rep（边界表示） |

---

## STEP 文件结构

```
ISO-10303-21;
HEADER;
  FILE_DESCRIPTION(('...'),'2;1');
  FILE_NAME('model.step','2024-01-15',('Author'),'','','','');
  FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
ENDSEC;
DATA;
  #1 = ORGANIZATION_RELATIONSHIP('','',#2,#3);
  #2 = ORGANIZATION('','',#4);
  #100 = CARTESIAN_POINT('',(0.,0.,0.));
  #101 = DIRECTION('',(1.,0.,0.));
  #102 = VECTOR('',#101,1.);
  #103 = LINE('',#100,#102);
  #200 = FACE_BOUND('',#201,.T.);
  #201 = LOOP('',(#202,#203,#204,#205));
  #202 = EDGE_CURVE('',#210,#211,#212,.T.);
  ... 几千到几百万个 entity ...
ENDSEC;
END-ISO-10303-21;
```

---

## 解析流程

```
STEP 文件 (文本)
  │
  ▼
┌─────────────────────────────────────┐
│  OCCT STEPControl_Reader            │
│  ├── 词法分析                        │
│  │   解析 entity 编号 (#123)         │
│  │   解析类型 (CARTESIAN_POINT)      │
│  │   解析参数 ((0.,0.,0.))          │
│  ├── 语法分析                        │
│  │   构建 entity 引用图              │
│  │   解析前向引用                    │
│  └── 语义转换                        │
│      STEP entity → OCCT 类型         │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  OCCT TopoDS_Shape（B-Rep 拓扑）     │
│                                     │
│  TopoDS_Solid                       │
│  └── TopoDS_Shell                   │
│      └── TopoDS_Face                │
│          ├── Geom_Surface           │
│          │   ├── Geom_Plane         │
│          │   ├── Geom_Cylindrical.. │
│          │   ├── Geom_BSpline..     │
│          │   └── ...                │
│          └── TopoDS_Wire            │
│              └── TopoDS_Edge        │
│                  ├── Geom_Curve     │
│                  └── TopoDS_Vertex  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  BRepTools_Explorer 遍历             │
│  逐层提取 Face/Edge/Vertex           │
│  映射到 LSM 数据结构                  │
└──────────────┬──────────────────────┘
               │
               ▼
          LSM Model
```

---

## OCCT API 调用

```rust
fn parse_step(data: &[u8]) -> Result<LsmModel> {
    // 1. 创建 reader
    let reader = occt::STEPControl_Reader::new();

    // 2. 读取文件
    let status = reader.read_string(data)?;
    if status != IFSelect_RetDone {
        return Err(Error::ParseFailed);
    }

    // 3. 转换为 OCCT Shape
    reader.transfer_roots();
    let shape = reader.one_shape()?;

    // 4. 遍历 B-Rep 拓扑，转换为 LSM
    let mut lsm = LsmModel::new();
    convert_shape(&shape, &mut lsm)?;

    Ok(lsm)
}

fn convert_shape(shape: &TopoDS_Shape, lsm: &mut LsmModel) -> Result<()> {
    let explorer = TopExp_Explorer::new(shape, TopAbs_FACE);
    while explorer.more() {
        let face = TopoDS::face(&explorer.current());
        convert_face(&face, lsm)?;
        explorer.next();
    }
    Ok(())
}

fn convert_face(face: &TopoDS_Face, lsm: &mut LsmModel) -> Result<()> {
    let surface = BRep_Tool::surface(face)?;

    let mut wire_explorer = TopExp_Explorer::new(face, TopAbs_WIRE);
    while wire_explorer.more() {
        let wire = TopoDS::wire(&wire_explorer.current());
        convert_wire(&wire, lsm)?;
        wire_explorer.next();
    }

    let lsm_surface = match surface.type() {
        Geom_Plane => LSM::Surface::Plane { ... },
        Geom_CylindricalSurface => LSM::Surface::Cylinder { ... },
        Geom_BSplineSurface => LSM::Surface::BSpline { ... },
        _ => LSM::Surface::Other,
    };

    lsm.add_face(lsm_face);
    Ok(())
}
```

---

## Entity 类型支持

| 优先级 | Entity 类型 | 说明 |
|--------|------------|------|
| P0 | CARTESIAN_POINT, DIRECTION, VECTOR | 基础几何 |
| P0 | LINE, CIRCLE, ELLIPSE | 基础曲线 |
| P0 | PLANE, CYLINDRICAL_SURFACE, CONICAL_SURFACE | 基础曲面 |
| P0 | B_SPLINE_CURVE, B_SPLINE_SURFACE | 自由曲线/曲面 |
| P0 | FACE, SHELL, SOLID | B-Rep 拓扑 |
| P1 | PRODUCT, SHAPE_REPRESENTATION | 产品结构 |
| P1 | STYLED_ITEM, PRESENTATION_STYLE | 颜色/样式 |
| P2 | DIMENSION, GEOMETRIC_TOLERANCE | PMI 标注 |

---

## 性能优化

### STEP 解析的性能瓶颈

```
STEP 文件 (500MB, 200万 entity)
  │
  ▼
词法分析 (CPU 密集)
  │  文本解析：#123 = TYPE('param',#456);
  │  浮点数解析：0.123456789012345
  │
  ▼
引用解析 (内存密集)
  │  构建 entity 引用图
  │  解析 #456 → 指向哪个 entity
  │
  ▼
B-Rep 构建 (CPU 密集)
  │  拓扑验证：壳是否封闭？
  │  几何验证：面是否有效？
  │
  ▼
LSM 转换
  │  构建运行时模型；未来可选择写入 LSM 缓存文件
```

### OCCT 内部优化

OCCT 自身已经做了很多优化：

| 优化 | 说明 |
|------|------|
| 延迟求值 | 只在访问时才计算几何 |
| 共享实体 | 相同几何只存储一次 |
| 索引查找 | entity 编号 → 内存地址的哈希表 |
| 批量转换 | `transfer_roots()` 批量处理 |

### 大文件处理策略

```rust
/// 分步解析：先读结构，再按需加载几何
fn parse_step_staged(data: &[u8]) -> Result<LsmModel> {
    // 第一步：只读结构树（快速）
    let structure = read_step_structure(data)?;

    // 第二步：按需加载几何（用户点击时）
    for product in &structure.products {
        if user_wants_to_see(product) {
            let shape = load_product_geometry(data, product)?;
            let mesh = tessellate(&shape, &options)?;
            lsm.add_mesh(mesh);
        }
    }

    Ok(lsm)
}
```

### 内存优化

```rust
/// 对于超大 STEP 文件，使用磁盘缓存
fn parse_step_large(path: &Path) -> Result<LsmModel> {
    let mmap = unsafe { Mmap::map(&File::open(path)?)? };

    // 使用临时文件存储中间结果
    let temp_dir = tempfile::tempdir()?;
    let lsm_path = temp_dir.path().join("model.lsm");

    // 流式解析，边解析边构建 LSM 运行时模型
    let mut lsm_writer = LsmWriter::new(&lsm_path)?;
    let reader = STEPControl_Reader::new();

    // ... 解析并写入

    // 未来可以返回 LSM 缓存句柄；早期优先返回运行时模型
    LsmModel::from_cache(&lsm_path)
}
```

---

## 性能基准

| 文件大小 | Entity 数量 | 解析时间 | 内存峰值 |
|---------|------------|---------|---------|
| < 1MB | < 1K | < 100ms | < 10MB |
| 1-10MB | 1K - 10K | 100ms - 1s | 10 - 100MB |
| 10-100MB | 10K - 100K | 1s - 10s | 100MB - 1GB |
| > 100MB | > 100K | > 10s | 需要流式处理 |

---

## OCCT STEP 解析器的工作原理

### 词法分析

STEP 文件是文本格式，每行一个 entity：

```
#123 = CARTESIAN_POINT('',(1.0,2.0,3.0));
│     │                  │
│     │                  └── 参数列表
│     └── entity 类型
└── entity 编号
```

OCCT 的词法分析器：
1. 识别 `#数字` → entity 引用
2. 识别 `TYPE(...)` → entity 类型
3. 识别 `'字符串'` → 字符串参数
4. 识别 `数字.数字` → 浮点数
5. 识别 `.TRUE.` / `.FALSE.` → 布尔值

### 引用解析

STEP 支持前向引用：

```
#1 = LINE('',#2,#3);    ← 引用 #2 和 #3
#2 = CARTESIAN_POINT(...);
#3 = DIRECTION(...);
```

OCCT 的引用解析：
1. 第一遍：扫描所有 entity，建立 编号→位置 映射
2. 第二遍：解析 entity，遇到 #N 引用时查找映射表
3. 处理循环引用（B-Rep 中常见）

### B-Rep 构建

STEP 的 B-Rep 数据是自底向上构建的：

```
CARTESIAN_POINT → 点
DIRECTION → 方向
LINE / CIRCLE / B_SPLINE_CURVE → 曲线
EDGE_CURVE → 边（曲线 + 两个顶点）
FACE_BOUND → 面边界（边的环）
ADVANCED_FACE → 面（曲面 + 边界）
CLOSED_SHELL → 壳（面的集合）
MANIFOLD_SOLID_BREP → 实体（壳的集合）
```

OCCT 自底向上构建 TopoDS_Shape：
1. 先创建所有 Vertex
2. 再创建 Edge（引用 Vertex + Curve）
3. 再创建 Wire（引用 Edge）
4. 再创建 Face（引用 Wire + Surface）
5. 再创建 Shell（引用 Face）
6. 最后创建 Solid（引用 Shell）
