# 渲染层总览

> MMForge 渲染层负责将 LSM 数据渲染为屏幕上的图像。

---

## 职责

- LSM 数据 → GPU 可用数据的转换
- 3D 模型渲染（Metal / Direct3D 12 / Vulkan / OpenGL ES）
- 2D 图纸渲染（Core Graphics / Direct2D / Android Canvas / ArkUI Canvas）
- 渲染优化（LOD、裁剪、实例化）

## 架构

```
┌─────────────────────────────────────────────┐
│                  渲染层                       │
│                                              │
│  ┌─────────────────┐  ┌──────────────────┐  │
│  │    3D 原生渲染器  │  │   2D 原生渲染器   │  │
│  │ Metal/D3D/Vulkan│  │ CG/D2D/Canvas    │  │
│  └────────┬────────┘  └────────┬─────────┘  │
│           │                    │             │
│  ┌────────▼────────────────────▼─────────┐  │
│  │          渲染数据准备层                  │  │
│  │  MeshBuilder / MaterialMapper / BVH   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## 模块文档

| 文档 | 内容 |
|------|------|
| [3d-native.md](3d-native.md) | 3D 原生渲染器设计 |
| [2d-native.md](2d-native.md) | 2D 原生渲染器设计 |
| [camera.md](camera.md) | 相机控制算法 |
| [optimization.md](optimization.md) | 渲染优化（LOD/裁剪/实例化） |
