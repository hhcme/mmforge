# OCCT FFI 绑定

> OpenCASCADE (OCCT) 的 Rust FFI 绑定设计。
>
> 最后更新：2026-06-29

---

## 依赖方式

OCCT 通过 Rust FFI 绑定使用：

```
mmforge-geometry/
├── build.rs              # 构建脚本，编译 OCCT 或链接预编译库
├── src/
│   ├── occt/
│   │   ├── sys/          # 低级 C++ 绑定（bindgen 生成）
│   │   ├── wrapper.rs    # 安全 Rust 封装
│   │   └── mod.rs
│   ├── tessellation.rs
│   └── lib.rs
└── Cargo.toml
```

---

## OCCT 模块裁剪

减少移动端体积，只编译需要的模块：

| 模块 | 是否需要 | 说明 |
|------|---------|------|
| TKernel | ✅ 必须 | 基础内核 |
| TKMath | ✅ 必须 | 数学库 |
| TKG3d | ✅ 必须 | 3D 几何 |
| TKGeomBase | ✅ 必须 | 几何基础 |
| TKBRep | ✅ 必须 | B-Rep 数据结构 |
| TKTopAlgo | ✅ 必须 | 拓扑算法 |
| TKMesh | ✅ 必须 | 三角化 |
| TKXSBase | ✅ 必须 | 数据交换基础 |
| TKSTEP | ✅ 必须 | STEP 解析 |
| TKIGES | ✅ 必须 | IGES 解析 |
| TKShHealing | ⚠️ 可选 | 形状修复 |
| TKBO | ⚠️ 可选 | 布尔运算（v2.0+） |
| TKFillet | ⚠️ 可选 | 倒角（v2.0+） |
| TKOffset | ⚠️ 可选 | 偏移（v2.0+） |
| TKXDE | ❌ 不需要 | 扩展数据交换 |
| TKVRML | ❌ 不需要 | VRML 导出 |
| TKOpenGl | ❌ 不需要 | OCCT 自带渲染（我们用自己的） |

---

## 安全封装

```rust
/// OCCT Shape 的安全 Rust 封装
pub struct Shape {
    inner: occt_sys::TopoDS_Shape,
}

impl Shape {
    /// 从 STEP 文件读取
    pub fn from_step(data: &[u8]) -> Result<Self> { ... }

    /// 从 IGES 文件读取
    pub fn from_iges(data: &[u8]) -> Result<Self> { ... }

    /// 获取形状类型
    pub fn shape_type(&self) -> ShapeType { ... }

    /// 遍历子形状
    pub fn explore(&self, type_: ShapeType) -> ShapeExplorer { ... }

    /// 获取包围盒
    pub fn bounding_box(&self) -> BoundingBox { ... }
}

/// B-Rep 拓扑遍历器
pub struct ShapeExplorer {
    inner: occt_sys::TopExp_Explorer,
}

impl Iterator for ShapeExplorer {
    type Item = Shape;
    fn next(&mut self) -> Option<Self::Item> { ... }
}
```

---

## 曲面/曲线安全封装

```rust
pub enum Surface {
    Plane { origin: [f64; 3], normal: [f64; 3] },
    Cylinder { axis: Axis, radius: f64 },
    Cone { axis: Axis, radius: f64, semi_angle: f64 },
    Sphere { center: [f64; 3], radius: f64 },
    Torus { axis: Axis, major_radius: f64, minor_radius: f64 },
    BSpline { ... },
}

pub enum Curve {
    Line { origin: [f64; 3], direction: [f64; 3] },
    Circle { center: [f64; 3], axis: [f64; 3], radius: f64 },
    Ellipse { ... },
    BSpline { ... },
}
```
