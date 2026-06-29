# B-Rep 数据结构

> Boundary Representation (B-Rep) 边界表示的数据结构与遍历算法。
>
> 最后更新：2026-06-29

---

## B-Rep 拓扑层次

```
Shape (形状)
└── Solid (实体)
    └── Shell (壳)
        └── Face (面)
            ├── Surface (曲面定义)
            └── Wire (环)
                └── Edge (边)
                    ├── Curve (曲线定义)
                    └── Vertex (顶点)
                        └── Point (点)
```

层次关系：
- **Shape** — 顶层容器
- **Solid** — 由封闭 Shell 围成的实体
- **Shell** — 一组 Face 的集合
- **Face** — 由 Surface + Wire 定义的面
- **Wire** — 一组 Edge 的有序环
- **Edge** — 由 Curve + 两个 Vertex 定义的边
- **Vertex** — 空间中的一个点

---

## 拓扑遍历算法

使用 `TopExp_Explorer` 遍历 B-Rep 拓扑：

```rust
// 遍历所有 Face
let explorer = TopExp_Explorer::new(shape, TopAbs_FACE);
while explorer.more() {
    let face = TopoDS::face(&explorer.current());
    // 处理 face...
    explorer.next();
}

// 遍历所有 Edge
let explorer = TopExp_Explorer::new(shape, TopAbs_EDGE);
while explorer.more() {
    let edge = TopoDS::edge(&explorer.current());
    // 处理 edge...
    explorer.next();
}
```

---

## 朝向 (Orientation)

每个拓扑元素有朝向属性：

| 朝向 | 含义 |
|------|------|
| Forward | 正向 |
| Reversed | 反向 |

Face 的朝向决定法线方向，Edge 的朝向决定曲线参数方向。

---

## 几何查询

```rust
// 获取 Face 的曲面
let surface = BRep_Tool::surface(face)?;

// 获取 Edge 的曲线
let curve = BRep_Tool::curve(edge, &mut first, &mut last)?;

// 获取 Vertex 的坐标
let point = BRep_Tool::point(vertex)?;

// 获取包围盒
let mut bbox = BRepBndLib::new();
bbox.add(shape);
let aabb = bbox.to_aabb();
```
