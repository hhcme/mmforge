# IGES 解析器

> IGES (Initial Graphics Exchange Specification) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | OCCT (IGESControl_Reader) |
| 优先级 | P1 |
| 数据类型 | B-Rep（边界表示） |
| 特点 | 老格式（1980s），存量数据多 |

---

## IGES 文件结构

IGES 使用固定列格式，每行 80 字符：

```
      1H,,1H;,,6HMmodel,6HAuthor,32,38,6,38,15,  Start (S)
1HMmodel,1.0,2,2HMM,32,0.01,                   Global (G)
1H      1       0       0       0       0       000010001D      1
1H      2       0       0       0       0       000000001D      2
...目录条目 (D)...
110,0.0,0.0,0.0,100.0,0.0,0.0,0,0;             参数数据 (P)
...更多实体...
S      1G      6D   1234P   5678                              Terminate (T)
```

四个段：
- **Start (S)**: 文件描述
- **Global (G)**: 全局参数（单位、精度、作者）
- **Directory Entry (D)**: 每个 entity 的属性行（2 行，固定列）
- **Parameter Data (P)**: 每个 entity 的几何数据

---

## 解析流程

```
IGES 文件
  │
  ▼
┌─────────────────────────────────────┐
│  OCCT IGESControl_Reader            │
│  ├── 解析 Start Section (S)         │
│  ├── 解析 Global Section (G)        │
│  │   单位、精度、文件信息             │
│  ├── 解析 Directory Entry (D)       │
│  │   Entity 类型、属性、颜色          │
│  ├── 解析 Parameter Data (P)        │
│  │   几何数据（点、线、面）            │
│  └── 转换为 OCCT TopoDS_Shape       │
└──────────────┬──────────────────────┘
               │
               ▼
（后续与 STEP 相同：遍历 B-Rep → 转换为 LSM）
```

---

## IGES 特有挑战

| 挑战 | 说明 | 对策 |
|------|------|------|
| 固定列格式 | 每行 80 字符，列对齐严格 | OCCT 内部处理 |
| 浮点数精度 | 文本表示有精度损失 | 使用 f64 存储 |
| 规范不一致 | 很多文件不完全符合规范 | OCCT 有容错机制 |
| 老格式 | 1980s 设计，功能有限 | 只提取可用数据 |

---

## 固定列格式解析算法

### Directory Entry (D) 解析

每行 80 字符，列定义固定：

```
列 1-8:    Entity 类型号
列 9-16:   参数数据指针
列 17-24:  结构（Structure）
列 25-32:  线型（Line Font Pattern）
列 33-40:  层（Level）
列 41-48:  视图（View）
列 49-56:  变换矩阵（Transformation Matrix）
列 57-64:  标号显示（Label Display）
列 65-72:  状态号（Status Number）
列 73-80:  序列号（Sequence Number）
```

```rust
fn parse_directory_entry(line1: &str, line2: &str) -> DirectoryEntry {
    // 第一行
    let entity_type: i32 = line1[0..8].trim().parse().unwrap();
    let param_pointer: i32 = line1[8..16].trim().parse().unwrap();
    let structure: i32 = line1[16..24].trim().parse().unwrap();
    let line_font: i32 = line1[24..32].trim().parse().unwrap();
    let level: i32 = line1[32..40].trim().parse().unwrap();

    // 第二行
    let view: i32 = line2[0..8].trim().parse().unwrap();
    let transform: i32 = line2[8..16].trim().parse().unwrap();
    let label_display: i32 = line2[16..24].trim().parse().unwrap();
    let status: i32 = line2[24..32].trim().parse().unwrap();
    let sequence: i32 = line2[56..64].trim().parse().unwrap();

    DirectoryEntry { entity_type, param_pointer, level, ... }
}
```

### Parameter Data (P) 解析

参数数据以逗号分隔，分号结束：

```
110,0.0,0.0,0.0,100.0,0.0,0.0,0,0;
```

```rust
fn parse_parameter_data(line: &str) -> Vec<ParamValue> {
    let mut params = Vec::new();
    let mut current = String::new();
    let mut in_string = false;

    for ch in line.chars() {
        match ch {
            '\'' => {
                in_string = !in_string;
                current.push(ch);
            }
            ',' if !in_string => {
                params.push(parse_param_value(&current));
                current.clear();
            }
            ';' if !in_string => {
                params.push(parse_param_value(&current));
                break;
            }
            _ => current.push(ch),
        }
    }

    params
}
```

---

## IGES Entity 类型

常用 Entity 类型：

| 类型号 | 名称 | 说明 |
|--------|------|------|
| 100 | Circular Arc | 圆弧 |
| 102 | Composite Curve | 复合曲线 |
| 104 | Conic Arc | 圆锥曲线 |
| 106 | Copious Data | 大量数据点 |
| 108 | Plane | 平面 |
| 110 | Line | 直线 |
| 112 | Parametric Spline Curve | 参数样条曲线 |
| 114 | Parametric Spline Surface | 参数样条曲面 |
| 116 | Point | 点 |
| 118 | Ruled Surface | 直纹面 |
| 120 | Surface of Revolution | 旋转面 |
| 122 | Tabulated Cylinder | 柱面 |
| 124 | Transformation Matrix | 变换矩阵 |
| 126 | Rational B-Spline Curve | 有理 B 样条曲线 |
| 128 | Rational B-Spline Surface | 有理 B 样条曲面 |
| 140 | Offset Surface | 偏移曲面 |
| 141 | Boundary | 边界 |
| 142 | Curve on a Parametric Surface | 曲面上的曲线 |
| 143 | Bounded Surface | 有界曲面 |
| 144 | Trimmed Parametric Surface | 裁剪曲面 |

---

## B-Spline 曲线解析算法

IGES 类型 126（Rational B-Spline Curve）的解析：

```
参数:
  K = 阶数 (degree + 1)
  M = 控制点数
  N = K + M - 1 (节点数)

数据:
  T(0)..T(N) = 节点向量
  W(0)..W(M-1) = 权重
  P(0)..P(M-1) = 控制点 (X, Y, Z)
```

### NURBS 曲线公式

```
         Σ Wi × Ni,p(t) × Pi
C(t) = ─────────────────────────
         Σ Wi × Ni,p(t)

其中:
  Wi = 权重
  Ni,p(t) = B 样条基函数
  Pi = 控制点
  p = 阶数 (K-1)
```

```rust
fn nurbs_point(
    t: f64,
    degree: usize,
    control_points: &[[f64; 3]],
    weights: &[f64],
    knots: &[f64],
) -> [f64; 3] {
    let mut numerator = [0.0; 3];
    let mut denominator = 0.0;

    for (i, (cp, &w)) in control_points.iter().zip(weights).enumerate() {
        let basis = bspline_basis(i, degree, t, knots);
        let wb = w * basis;

        numerator[0] += wb * cp[0];
        numerator[1] += wb * cp[1];
        numerator[2] += wb * cp[2];
        denominator += wb;
    }

    [
        numerator[0] / denominator,
        numerator[1] / denominator,
        numerator[2] / denominator,
    ]
}
```

---

## 性能优化

### 固定列解析优化

```rust
// ❌ 低效：每次都 trim + parse
let value: f64 = line[0..20].trim().parse()?;

// ✅ 高效：直接解析，跳过空格
fn fast_parse_f64_fixed(s: &[u8]) -> f64 {
    let mut result = 0.0;
    let mut sign = 1.0;
    let mut i = 0;

    // 跳过前导空格
    while i < s.len() && s[i] == b' ' { i += 1; }

    // 符号
    if i < s.len() && s[i] == b'-' { sign = -1.0; i += 1; }

    // 整数部分
    while i < s.len() && s[i].is_ascii_digit() {
        result = result * 10.0 + (s[i] - b'0') as f64;
        i += 1;
    }

    // 小数部分
    if i < s.len() && s[i] == b'.' {
        i += 1;
        let mut frac = 0.1;
        while i < s.len() && s[i].is_ascii_digit() {
            result += (s[i] - b'0') as f64 * frac;
            frac *= 0.1;
            i += 1;
        }
    }

    sign * result
}
```

### 内存优化

```rust
// IGES 文件通常比 STEP 小，但仍需注意内存
// 使用引用而非复制
struct IgesEntity<'a> {
    entity_type: i32,
    params: &'a str,  // 引用原始数据
}
```

---

## IGES vs STEP

| 维度 | IGES | STEP |
|------|------|------|
| 年代 | 1980s | 1990s+ |
| 格式 | 固定列文本 | 自由文本 |
| Entity 类型 | ~400 种 | ~3000 种 |
| 精度 | 文本浮点（有损） | 高精度 |
| 产品结构 | 有限 | 完整 |
| 推荐度 | 存量数据兼容 | 优先使用 |
