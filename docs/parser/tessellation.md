# 三角化算法 (Tessellation)

> B-Rep 曲面转换为三角网格的算法设计。
>
> 最后更新：2026-06-29

---

## 概述

Tessellation 是把 B-Rep 的参数化曲面转换为渲染器能直接使用的三角网格。

```
B-Rep Face（曲面 + 边界）
  │
  ▼
参数空间网格生成
  │
  ▼
参数空间 → 3D 空间映射
  │
  ▼
三角形索引生成
  │
  ▼
法线计算
  │
  ▼
三角网格数据
```

---

## 算法流程

对每个 Face 执行：

```
1. 获取曲面方程 Geom_Surface
2. 获取边界 Wire（参数空间中的边界）
3. 在参数空间中生成网格点
   ├── 根据精度要求决定网格密度
   ├── 平面 → 少量三角形
   └── 曲面 → 密集三角形
4. 将参数空间网格点映射到 3D 空间
   └── (u, v) → (x, y, z) = Surface.Value(u, v)
5. 生成三角形索引（Delaunay 三角化）
6. 计算法线（曲面法线或三角形面法线）
```

---

## OCCT 实现

依赖：`BRepMesh_IncrementalMesh`

```rust
pub fn tessellate(
    shape: &TopoDS_Shape,
    options: &TessellationOptions,
) -> Result<TessellationResult> {
    // 调用 OCCT 三角化
    let mesh = BRepMesh_IncrementalMesh::new(
        shape,
        options.linear_deflection,
        options.relative,
        options.angular_deflection,
        true, // parallel
    );

    let mut positions = Vec::new();
    let mut normals = Vec::new();
    let mut indices = Vec::new();

    let explorer = TopExp_Explorer::new(shape, TopAbs_FACE);
    while explorer.more() {
        let face = TopoDS::face(&explorer.current());
        let triangulation = BRep_Tool::triangulation(&face)?;

        for i in 1..=triangulation.nb_nodes() {
            let p = triangulation.node(i);
            positions.push([p.x() as f32, p.y() as f32, p.z() as f32]);

            let n = triangulation.normal(i);
            normals.push([n.x() as f32, n.y() as f32, n.z() as f32]);
        }

        for i in 1..=triangulation.nb_triangles() {
            let tri = triangulation.triangle(i);
            indices.push(tri.get(0) as u32 - 1);
            indices.push(tri.get(1) as u32 - 1);
            indices.push(tri.get(2) as u32 - 1);
        }

        explorer.next();
    }

    Ok(TessellationResult { positions, normals, indices })
}
```

---

## 精度控制

```rust
pub struct TessellationOptions {
    /// 弦高公差（mm）：三角形边与曲面的最大距离
    pub linear_deflection: f64,
    /// 角度公差（弧度）：相邻三角形法线的最大夹角
    pub angular_deflection: f64,
    /// 是否相对模式（公差相对于模型大小）
    pub relative: bool,
}
```

### 预设精度

| 预设 | linear_deflection | angular_deflection | 适用场景 |
|------|------------------|-------------------|---------|
| 高精度 | 0.01 mm | 0.1 rad | 预览、检查 |
| 标准 | 0.1 mm | 0.5 rad | 默认 |
| 低精度 | 0.5 mm | 1.0 rad | 移动端、大模型 |

### 精度与性能的关系

```
精度越高 → 三角形越多 → 渲染越精细 → 性能越差
精度越低 → 三角形越少 → 渲染越粗糙 → 性能越好
```

---

## 性能参考

| 模型复杂度 | 面数 | 三角形数 | 耗时（标准精度） |
|-----------|------|---------|----------------|
| 简单零件 | ~10 | ~1K | <1ms |
| 中等零件 | ~100 | ~10K | 5ms |
| 复杂零件 | ~1K | ~100K | 50ms |
| 大型零件 | ~10K | ~1M | 500ms |
| 大型装配体 | ~100K | ~10M | 5s+ |

---

## 优化策略

### 1. 并行 Tessellation

OCCT 的 `BRepMesh_IncrementalMesh` 支持并行处理：

```rust
BRepMesh_IncrementalMesh::new(shape, deflection, relative, angle, true);
//                                                              ^^^^
//                                                           parallel = true
```

### 2. 按需 Tessellation

只处理可见部分：

```rust
// 只 tessellation 视锥内的 face
let visible_faces = cull_faces(all_faces, &frustum);
for face in visible_faces {
    tessellate_face(&face, &options)?;
}
```

### 3. LOD (Level of Detail)

根据距离使用不同精度：

```rust
fn select_lod(distance: f32) -> TessellationOptions {
    if distance < 10.0 {
        TessellationOptions::high()
    } else if distance < 100.0 {
        TessellationOptions::standard()
    } else {
        TessellationOptions::low()
    }
}
```

---

## Delaunay 三角化算法

OCCT 在参数空间中使用 Delaunay 三角化：

### 算法原理

```
输入: 参数空间中的点集 P = {p1, p2, ..., pn}
输出: 三角形集合 T

1. 构建超三角形（包含所有点）
2. 逐个插入点:
   a. 找到包含该点的三角形
   b. 分割为 3 个新三角形
   c. 执行 Lawson 翻转（保持 Delaunay 性质）
3. 删除超三角形的顶点
```

### Lawson 翻转

```
如果两个相邻三角形不满足 Delaunay 条件:
  - 两个三角形的外接圆包含对方的顶点
  - 则翻转共享边

  Before:        After:
    A               A
   /|\             / \
  / | \           /   \
 B--C--D         B-----D
  \ | /           \   /
   \|/             \ /
    E               E

边 CD 翻转为边 BE
```

---

## 参数空间 → 3D 空间映射

### 曲面参数化

```
平面: P(u,v) = O + u×U + v×V
圆柱面: P(u,v) = O + R×(cos(u)×X + sin(u)×Y) + v×Z
球面: P(u,v) = O + R×(cos(v)×(cos(u)×X + sin(u)×Y) + sin(v)×Z)
B样条曲面: P(u,v) = ΣΣ Ni,p(u)×Nj,q(v)×Pi,j
```

### 法线计算

```
法线 N = ∂P/∂u × ∂P/∂v (叉积)

对于 B 样条曲面:
  ∂P/∂u = ΣΣ Ni',p(u)×Nj,q(v)×Pi,j  (基函数求导)
  ∂P/∂v = ΣΣ Ni,p(u)×Nj',q(v)×Pi,j
```

```rust
fn surface_normal(surface: &Surface, u: f64, v: f64) -> [f64; 3] {
    let du = surface.derivative_u(u, v);
    let dv = surface.derivative_v(u, v);

    // 叉积
    [
        du[1] * dv[2] - du[2] * dv[1],
        du[2] * dv[0] - du[0] * dv[2],
        du[0] * dv[1] - du[1] * dv[0],
    ]
}
```

---

## 自适应细分算法

根据曲面曲率自动调整网格密度：

```
对于每个三角形:
1. 计算三个顶点处的曲面法线
2. 如果法线变化超过阈值:
   - 在三角形中心插入新点
   - 细分为 4 个子三角形
3. 递归直到满足精度
```

```rust
fn adaptive_subdivide(
    surface: &Surface,
    triangle: &Triangle,
    options: &TessellationOptions,
) -> Vec<Triangle> {
    let n0 = surface_normal(surface, triangle.uv[0][0], triangle.uv[0][1]);
    let n1 = surface_normal(surface, triangle.uv[1][0], triangle.uv[1][1]);
    let n2 = surface_normal(surface, triangle.uv[2][0], triangle.uv[2][1]);

    // 检查法线变化
    let max_angle = angle_between(n0, n1).max(angle_between(n1, n2)).max(angle_between(n2, n0));

    if max_angle > options.angular_deflection {
        // 细分
        let center_uv = [
            (triangle.uv[0][0] + triangle.uv[1][0] + triangle.uv[2][0]) / 3.0,
            (triangle.uv[0][1] + triangle.uv[1][1] + triangle.uv[2][1]) / 3.0,
        ];
        let center_3d = surface.evaluate(center_uv[0], center_uv[1]);

        let t1 = Triangle::new(triangle.vertices[0], triangle.vertices[1], center_3d);
        let t2 = Triangle::new(triangle.vertices[1], triangle.vertices[2], center_3d);
        let t3 = Triangle::new(triangle.vertices[2], triangle.vertices[0], center_3d);

        let mut result = Vec::new();
        result.extend(adaptive_subdivide(surface, &t1, options));
        result.extend(adaptive_subdivide(surface, &t2, options));
        result.extend(adaptive_subdivide(surface, &t3, options));
        result
    } else {
        vec![*triangle]
    }
}
```

---

## 退化面处理

某些面可能退化（面积为零、边重合等）：

```rust
fn tessellate_face_safe(face: &Face, options: &TessellationOptions) -> Option<TessellationResult> {
    // 检查面是否退化
    if face.is_degenerate() {
        return None;
    }

    // 检查面积
    let area = face.area();
    if area < 1e-10 {
        return None;
    }

    // 正常 tessellation
    tessellate_face(face, options).ok()
}
```
