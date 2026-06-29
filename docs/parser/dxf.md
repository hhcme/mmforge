# DXF 解析器

> DXF (Drawing Exchange Format) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | 自研（无外部依赖） |
| 优先级 | P0 |
| 数据类型 | 2D 几何 |
| 特点 | Autodesk 开放格式，有公开文档 |

---

## DXF 文件结构

DXF 由"组码 + 值"对组成：

```
组码 (group code): 整数，表示数据类型
值 (value):        对应的数据
```

文件分段：

```
SECTION (HEADER)   → 全局变量（版本、单位、范围等）
SECTION (TABLES)   → 表定义（图层、线型、文字样式、标注样式）
SECTION (BLOCKS)   → 块定义（可复用的图形组）
SECTION (ENTITIES) → 图形实体（LINE, ARC, CIRCLE, TEXT, ...）
SECTION (OBJECTS)  → 非图形对象
EOF
```

---

## 解析流程

```
DXF 文件
  │
  ▼
┌─────────────────────────────────────┐
│  第一步：组码解析器（Tokenizer）      │
│  逐行读取，输出 (group_code, value)  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  第二步：段落解析器（Section Parser） │
│  ├── HEADER → 全局变量               │
│  ├── TABLES → 图层/线型/样式         │
│  ├── BLOCKS → 块定义                 │
│  └── ENTITIES → 实体列表             │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  第三步：实体解析器（Entity Parser）  │
│  ├── LINE → 起点 + 终点             │
│  ├── ARC → 圆心 + 半径 + 角度       │
│  ├── CIRCLE → 圆心 + 半径           │
│  ├── LWPOLYLINE → 顶点列表          │
│  ├── SPLINE → 控制点 + 节点向量      │
│  ├── TEXT → 内容 + 位置             │
│  ├── DIMENSION → 尺寸标注           │
│  ├── HATCH → 填充图案               │
│  └── INSERT → 块引用                │
└──────────────┬──────────────────────┘
               │
               ▼
          LSM Model (2D)
```

---

## 组码解析器

```rust
pub struct DxfTokenizer {
    lines: Vec<String>,
    position: usize,
}

impl DxfTokenizer {
    pub fn next_pair(&mut self) -> Option<(i32, String)> {
        if self.position + 1 >= self.lines.len() {
            return None;
        }
        let code: i32 = self.lines[self.position].trim().parse().ok()?;
        let value = self.lines[self.position + 1].trim().to_string();
        self.position += 2;
        Some((code, value))
    }
}
```

组码含义：

| 组码 | 含义 |
|------|------|
| 0 | 实体类型（LINE, ARC, CIRCLE, ...） |
| 1 | 主文字值 |
| 2 | 名称（段名、块名、图层名） |
| 8 | 图层名 |
| 10, 20, 30 | 第一个点 (X, Y, Z) |
| 11, 21, 31 | 第二个点 (X, Y, Z) |
| 40 | 浮点值（半径、高度等） |
| 50, 51 | 角度值 |
| 62 | 颜色号 |
| 70 | 标志位 |

---

## 实体支持

| 优先级 | 实体 | 解析难度 | 说明 |
|--------|------|----------|------|
| P0 | LINE | ⭐ | 两点确定 |
| P0 | CIRCLE | ⭐ | 圆心 + 半径 |
| P0 | ARC | ⭐ | 圆心 + 半径 + 角度 |
| P0 | LWPOLYLINE | ⭐⭐ | 顶点列表 + 可选圆弧段 |
| P0 | TEXT | ⭐⭐ | 内容 + 位置 + 样式 |
| P1 | MTEXT | ⭐⭐⭐ | 多行文字 + 格式代码 |
| P1 | SPLINE | ⭐⭐⭐ | 控制点 + 节点向量 |
| P1 | ELLIPSE | ⭐⭐ | 中心 + 轴 + 参数范围 |
| P1 | INSERT | ⭐⭐⭐ | 块引用 + 变换矩阵 |
| P1 | DIMENSION | ⭐⭐⭐⭐ | 标注 + 测量值 + 样式 |
| P1 | HATCH | ⭐⭐⭐⭐ | 边界 + 填充图案 |

---

## LWPOLYLINE 圆弧段算法

LWPOLYLINE 的顶点可以有 `bulge` 值，表示圆弧段：

```
bulge = 0    → 直线段
bulge > 0    → 逆时针圆弧
bulge < 0    → 顺时针圆弧
|bulge| = 1  → 半圆
```

### bulge → 圆弧参数的数学推导

```
已知:
  P1, P2 = 两个端点
  bulge = 弓高 / (弦长/2)

弦长:
  d = |P2 - P1|

弓高:
  h = |bulge| × d / 2

半径:
  R = (d²/4 + h²) / (2h)

圆心角:
  θ = 4 × arctan(|bulge|)

圆心:
  中点 M = (P1 + P2) / 2
  方向 N = perpendicular(P2 - P1) / |P2 - P1|
  C = M + sign(bulge) × N × (R - h)
```

```rust
fn bulge_to_arc(p1: [f64; 2], p2: [f64; 2], bulge: f64) -> ArcParams {
    let dx = p2[0] - p1[0];
    let dy = p2[1] - p1[1];
    let dist = (dx * dx + dy * dy).sqrt();

    if dist < 1e-10 {
        return ArcParams::degenerate(p1);
    }

    let sagitta = bulge * dist / 2.0;
    let radius = (dist * dist / 4.0 + sagitta * sagitta) / (2.0 * sagitta.abs());

    // 中点
    let mx = (p1[0] + p2[0]) / 2.0;
    let my = (p1[1] + p2[1]) / 2.0;

    // 垂直方向
    let nx = -dy / dist;
    let ny = dx / dist;

    // 圆心
    let offset = radius - sagitta;
    let cx = mx + nx * offset * bulge.signum();
    let cy = my + ny * offset * bulge.signum();

    // 起始角和终止角
    let start_angle = (p1[1] - cy).atan2(p1[0] - cx);
    let end_angle = (p2[1] - cy).atan2(p2[0] - cx);

    ArcParams {
        center: [cx, cy],
        radius,
        start_angle,
        end_angle,
    }
}
```

---

## 块引用 (INSERT) 展开算法

INSERT 实体引用 BLOCK 定义，需要应用变换矩阵：

```
INSERT 实体:
  block_name = "DOOR"
  insert_point = (100, 200)
  scale = (1.5, 1.5)
  rotation = 45°

BLOCK "DOOR" 定义:
  base_point = (0, 0)
  entities = [LINE, ARC, ...]

展开后的实体:
  对 BLOCK 中每个 entity:
    1. 平移到 base_point
    2. 应用缩放 (1.5, 1.5)
    3. 旋转 45°
    4. 平移到 insert_point (100, 200)
```

```rust
fn expand_insert(insert: &Insert, blocks: &HashMap<String, Block>) -> Vec<Entity2D> {
    let block = blocks.get(&insert.block_name)?;
    let mut result = Vec::new();

    // 构建变换矩阵
    let transform = Mat3::identity()
        * Mat3::translate(insert.insert_point)
        * Mat3::rotate(insert.rotation)
        * Mat3::scale(insert.scale);

    for entity in &block.entities {
        let mut transformed = entity.clone();
        apply_transform(&mut transformed, &transform);
        result.push(transformed);
    }

    result
}
```

---

## SPLINE 解析算法

B 样条曲线的解析：

```
DXF SPLINE 实体:
  70 = 8          (闭合曲线标志)
  71 = 3          (阶数 = 3，即三次 B 样条)
  72 = 8          (节点数)
  73 = 5          (控制点数)
  40 = 0,0,0,0,1,1,1,1  (节点向量)
  10, 20, 30 = P0        (控制点)
  10, 20, 30 = P1
  ...
```

### B 样条基函数计算 (Cox-de Boor)

```
Ni,0(t) = 1  if ti ≤ t < ti+1
         0  otherwise

Ni,p(t) = ((t - ti) / (ti+p - ti)) × Ni,p-1(t)
        + ((ti+p+1 - t) / (ti+p+1 - ti+1)) × Ni+1,p-1(t)
```

```rust
fn bspline_basis(i: usize, p: usize, t: f64, knots: &[f64]) -> f64 {
    if p == 0 {
        return if knots[i] <= t && t < knots[i + 1] { 1.0 } else { 0.0 };
    }

    let d1 = knots[i + p] - knots[i];
    let d2 = knots[i + p + 1] - knots[i + 1];

    let term1 = if d1.abs() > 1e-10 {
        ((t - knots[i]) / d1) * bspline_basis(i, p - 1, t, knots)
    } else {
        0.0
    };

    let term2 = if d2.abs() > 1e-10 {
        ((knots[i + p + 1] - t) / d2) * bspline_basis(i + 1, p - 1, t, knots)
    } else {
        0.0
    };

    term1 + term2
}

/// 计算 B 样条曲线上的点
fn bspline_point(t: f64, degree: u32, control_points: &[[f64; 2]], knots: &[f64]) -> [f64; 2] {
    let mut point = [0.0, 0.0];
    for (i, cp) in control_points.iter().enumerate() {
        let basis = bspline_basis(i, degree as usize, t, knots);
        point[0] += basis * cp[0];
        point[1] += basis * cp[1];
    }
    point
}
```

---

## 性能优化

### 1. 流式解析

DXF 是文本格式，适合流式解析：

```rust
fn parse_dxf_streaming<R: Read>(reader: R) -> Result<LsmModel> {
    let buf_reader = BufReader::new(reader);
    let mut lines = buf_reader.lines();

    let mut current_section = None;
    let mut current_entity = None;

    while let Some(Ok(line)) = lines.next() {
        let line = line.trim();
        if line.is_empty() { continue; }

        // 读取组码
        let code: i32 = match line.parse() {
            Ok(c) => c,
            Err(_) => continue,
        };

        // 读取值
        let value = match lines.next() {
            Some(Ok(v)) => v.trim().to_string(),
            _ => break,
        };

        // 处理组码对
        match (code, value.as_str()) {
            (0, "SECTION") => { /* 新段开始 */ }
            (2, name) => { current_section = Some(name.to_string()); }
            (0, "ENDSEC") => { current_section = None; }
            (0, entity_type) => {
                // 保存上一个实体，开始新实体
                if let Some(entity) = current_entity.take() {
                    save_entity(entity);
                }
                current_entity = Some(EntityBuilder::new(entity_type));
            }
            _ => {
                // 添加属性到当前实体
                if let Some(ref mut entity) = current_entity {
                    entity.add_attribute(code, &value);
                }
            }
        }
    }

    Ok(model)
}
```

### 2. 哈希表加速块查找

```rust
struct DxfParser {
    blocks: HashMap<String, Block>,      // 块名 → 块定义
    layers: HashMap<String, Layer>,      // 图层名 → 图层
    styles: HashMap<String, TextStyle>,  // 样式名 → 样式
}
```

### 3. 预分配策略

```rust
// 根据文件大小预估实体数量
let estimated_entities = file_size / 100; // 粗略估计
let mut entities = Vec::with_capacity(estimated_entities);
```

### 4. 文字解析优化

```rust
// ❌ 低效：每次都 parse
let x: f64 = value.parse().unwrap();

// ✅ 高效：快速解析（跳过错误检查）
fn fast_parse_f64(s: &str) -> f64 {
    // 使用 unsafe 或自定义解析器
    // 避免 UTF-8 验证开销
    s.parse().unwrap_or(0.0)
}
```

---

## 性能基准

| 文件大小 | 实体数量 | 预期解析时间 |
|---------|---------|------------|
| < 100KB | < 1K | < 10ms |
| 100KB - 1MB | 1K - 10K | 10 - 100ms |
| 1MB - 10MB | 10K - 100K | 100ms - 1s |
| 10MB - 100MB | 100K - 1M | 1s - 10s |
| > 100MB | > 1M | 需要流式加载 |
