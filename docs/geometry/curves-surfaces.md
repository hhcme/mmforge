# 曲线曲面算法

> 几何层的曲线曲面类型定义和参数化表示。
>
> 最后更新：2026-06-29

---

## 曲线类型

### 直线 (Line)

```
参数方程: P(t) = Origin + t × Direction
```

```rust
pub struct Line {
    pub origin: [f64; 3],
    pub direction: [f64; 3],
}
```

### 圆弧 (Circle)

```
参数方程: P(t) = Center + R × (cos(t) × U + sin(t) × V)
```

```rust
pub struct Circle {
    pub center: [f64; 3],
    pub axis: [f64; 3],      // 法线方向
    pub radius: f64,
    pub start_angle: f64,    // 起始角（弧度）
    pub end_angle: f64,      // 终止角（弧度）
}
```

### 椭圆 (Ellipse)

```rust
pub struct Ellipse {
    pub center: [f64; 3],
    pub major_axis: [f64; 3],
    pub minor_axis: [f64; 3],
    pub major_radius: f64,
    pub minor_radius: f64,
}
```

### B 样条曲线 (BSpline Curve)

```
P(t) = Σ Ni,n(t) × Pi

其中:
  Ni,n(t) = B 样条基函数
  Pi = 控制点
  n = 阶数 (degree + 1)
```

```rust
pub struct BSplineCurve {
    pub degree: u32,
    pub poles: Vec<[f64; 3]>,       // 控制点
    pub weights: Vec<f64>,           // 权重（有理 B 样条）
    pub knots: Vec<f64>,             // 节点向量
    pub multiplicities: Vec<u32>,    // 节点重数
}
```

---

## 曲面类型

### 平面 (Plane)

```
方程: n · (P - P0) = 0
```

```rust
pub struct Plane {
    pub origin: [f64; 3],
    pub normal: [f64; 3],
}
```

### 圆柱面 (Cylinder)

```
参数方程:
  P(u, v) = O + R×(cos(u)×U + sin(u)×V) + v×W
```

```rust
pub struct Cylinder {
    pub axis_origin: [f64; 3],
    pub axis_direction: [f64; 3],
    pub radius: f64,
}
```

### 圆锥面 (Cone)

```rust
pub struct Cone {
    pub axis_origin: [f64; 3],
    pub axis_direction: [f64; 3],
    pub radius: f64,
    pub semi_angle: f64,
}
```

### 球面 (Sphere)

```rust
pub struct Sphere {
    pub center: [f64; 3],
    pub radius: f64,
}
```

### 环面 (Torus)

```rust
pub struct Torus {
    pub axis_origin: [f64; 3],
    pub axis_direction: [f64; 3],
    pub major_radius: f64,
    pub minor_radius: f64,
}
```

### B 样条曲面 (BSpline Surface)

```
P(u, v) = ΣΣ Ni,m(u) × Nj,n(v) × Pi,j
```

```rust
pub struct BSplineSurface {
    pub degree_u: u32,
    pub degree_v: u32,
    pub poles: Vec<[f64; 3]>,           // 控制点网格
    pub weights: Vec<f64>,
    pub knots_u: Vec<f64>,              // U 向节点向量
    pub knots_v: Vec<f64>,              // V 向节点向量
    pub multiplicities_u: Vec<u32>,
    pub multiplicities_v: Vec<u32>,
}
```

---

## 曲面求交算法（v2.0+）

曲面求交是几何运算的核心算法：

```
输入: 两个曲面 S1(u,v), S2(s,t)
输出: 交线 C(t)

算法:
1. 网格求交（粗略）
   - 在两个曲面上分别生成网格
   - 找到网格交点
2. 牛顿迭代（精确）
   - 从网格交点出发
   - 迭代求解 S1(u,v) = S2(s,t)
3. 交线拟合
   - 将离散交点拟合为 B 样条曲线
```

---

## 参数空间与 3D 空间的映射

```
参数空间 (u, v) → 3D 空间 (x, y, z)

曲面: (u, v) → Surface.Value(u, v) = (x, y, z)
曲线: t → Curve.Value(t) = (x, y, z)
```

这个映射是 tessellation 的核心：在参数空间生成网格点，然后映射到 3D 空间。
