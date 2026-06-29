# 3D 原生渲染器

> MMForge 3D 渲染层使用各平台原生 GPU API，避免跨平台渲染引擎带来的抽象开销。
>
> 最后更新：2026-06-29

---

## 技术路线

| 平台 | 3D API | UI 框架 | 说明 |
|------|--------|---------|------|
| macOS / iOS | Metal | SwiftUI | 优先使用当前稳定 SDK，Metal 4 能力按平台可用性启用 |
| Windows | Direct3D 12 | WinUI 3 | 面向高性能桌面 CAD 查看场景 |
| Android | Vulkan / OpenGL ES fallback | Jetpack Compose | Vulkan 优先，低端设备保留 fallback |
| OpenHarmony | OpenGL ES / 平台图形 API | ArkUI | 后期验证平台能力后落地 |

---

## 分层职责

```
LSM Runtime Model
  │
  ▼
mmforge-render
  ├── MeshBuilder
  ├── MaterialMapper
  ├── Batching / Instancing
  ├── BVH / AABB
  └── RenderPacket（平台无关）
       │
       ├── Metal Adapter
       ├── D3D12 Adapter
       ├── Vulkan Adapter
       └── GLES Adapter
```

Rust 层负责生成平台无关的 `RenderPacket`：顶点、索引、材质、实例、包围盒和渲染排序信息。平台层只负责把这些数据上传到对应 GPU API，并执行绘制命令。

---

## 渲染能力

- 实体渲染
- 线框渲染
- 实体 + 线框叠加
- 透明渲染
- 剖切面
- 截面填充
- 选择高亮
- 零件/图层显隐
- PBR 材质与工程材质两套风格
- 大装配体实例化渲染
- LOD、视锥裁剪、遮挡剔除

---

## RenderPacket 草案

```rust
pub struct RenderPacket {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    pub batches: Vec<RenderBatch>,
    pub bounds: BoundingBox,
}

pub struct RenderMesh {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Option<Vec<[f32; 2]>>,
    pub indices: Vec<u32>,
    pub bounds: BoundingBox,
}

pub struct RenderInstance {
    pub mesh_id: u32,
    pub material_id: u32,
    pub transform: [f32; 16],
    pub node_id: u32,
    pub visible: bool,
}

pub struct RenderBatch {
    pub material_id: u32,
    pub mesh_ids: Vec<u32>,
    pub instance_range: std::ops::Range<u32>,
}
```

---

## Metal 适配器

macOS / iOS 的第一条落地路径使用 Metal：

- `MTKView` 负责 swapchain 和帧调度
- `MTLBuffer` 存储顶点、索引、实例数据
- `MTLRenderPipelineState` 区分实体、线框、透明、选择高亮
- `MTLArgumentBuffer` 或 bindless-like 方案用于材质/纹理扩展
- 可用时启用 Metal 4 相关能力；必须保留稳定 fallback

---

## Windows 适配器

Windows 使用 Direct3D 12：

- WinUI 3 承载渲染视图
- D3D12 resource heap 管理大模型 GPU 资源
- command list / command queue 分离上传和渲染
- descriptor heap 管理材质与纹理

---

## Android 适配器

Android 使用 Vulkan 优先：

- Compose 负责 UI
- Vulkan Surface 负责 3D 渲染
- 大模型资源上传放到后台线程
- OpenGL ES 作为兼容 fallback

---

## 验收标准

每个平台的原生渲染适配器都必须满足：

- 能加载同一份 `RenderPacket`
- 相机、选择、显隐、剖切行为一致
- 支持渲染统计：fps、draw calls、triangles、GPU memory
- 支持可复现截图测试
- 不依赖第三方跨平台渲染引擎
