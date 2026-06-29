# 2D 原生渲染器

> MMForge 2D 图纸渲染使用平台原生绘图能力，面向 DXF/DWG/SVG/PDF 等工程图纸查看、测量和标注。
>
> 最后更新：2026-06-29

---

## 技术路线

| 平台 | 2D API | 说明 |
|------|--------|------|
| macOS / iOS | Core Graphics + Metal overlay | 图纸基础绘制用 Core Graphics，高亮/交互层可用 Metal |
| Windows | Direct2D + DirectWrite | 线型、文字、DPI 缩放和打印链路成熟 |
| Android | Android Canvas / RenderNode | 与 Compose 原生 UI 集成 |
| OpenHarmony | ArkUI Canvas / OpenGL ES fallback | 后期按平台能力验证 |

---

## 分层职责

```
Drawing2DGeometry
  │
  ▼
mmforge-render-2d
  ├── PathBuilder
  ├── LineTypeResolver
  ├── TextLayoutInput
  ├── HatchBuilder
  ├── LayerDrawList
  └── SpatialIndex
       │
       ├── Core Graphics Adapter
       ├── Direct2D Adapter
       ├── Android Canvas Adapter
       └── ArkUI Canvas Adapter
```

Rust 层负责把 DXF/DWG 等实体整理为平台无关的绘制列表；平台层负责调用原生 Path、Text、Brush、Pen、Canvas API。

---

## 图纸能力

- LINE / ARC / CIRCLE / ELLIPSE / SPLINE
- LWPOLYLINE，包括 bulge 圆弧段
- TEXT / MTEXT
- INSERT / BLOCK 展开
- DIMENSION 基础显示
- HATCH 基础显示
- 图层显隐、冻结、颜色覆盖
- 线型、线宽、颜色、打印样式
- 平移、缩放、适配视图
- 距离、角度、面积测量
- 文字搜索
- 导出图片 / PDF

---

## DrawList 草案

```rust
pub struct DrawingDrawList {
    pub layers: Vec<LayerDrawList>,
    pub bounds: BoundingBox2D,
    pub spatial_index: SpatialIndex2D,
}

pub struct LayerDrawList {
    pub layer_id: u32,
    pub visible: bool,
    pub commands: Vec<DrawCommand>,
}

pub enum DrawCommand {
    Path {
        path: Path2D,
        stroke: StrokeStyle,
        fill: Option<FillStyle>,
    },
    Text {
        position: [f64; 2],
        content: String,
        style: TextStyle,
        transform: [f64; 6],
    },
    Image {
        bounds: BoundingBox2D,
        image_id: u32,
    },
}
```

---

## 性能策略

- 视口裁剪：只绘制当前视口相关实体
- 空间索引：R-tree 或 BVH 加速图纸查询
- Path 缓存：复杂 polyline、spline、hatch 预构建路径
- 文本缓存：按字体、字号、内容缓存布局结果
- 分层重绘：图层显隐和选择高亮不触发全量重建
- 大图纸分页：超大 DXF/DWG 按空间块加载和绘制

---

## 验收标准

- 同一图纸在各平台线型、颜色、文字尺寸尽量一致
- 缩放和平移保持 60 fps 目标，超大图纸允许降级但不能阻塞 UI
- 测量结果使用源文件单位并明确显示精度
- 不依赖第三方跨平台 UI/绘图引擎
