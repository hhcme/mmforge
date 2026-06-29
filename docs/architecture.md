# 整体架构文档

> MMForge 系统架构总览。
>
> 最后更新：2026-06-29

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                        客户端层                              │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  macOS   │  │   iOS    │  │ Windows  │  │ Android  │   │
│  │ SwiftUI  │  │ SwiftUI  │  │  WinUI   │  │ Compose  │   │
│  │  Metal   │  │  Metal   │  │  D3D12   │  │ Vulkan   │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       └──────────────┼────────────┼──────────────┘         │
│                      │ FFI                                │
└──────────────────────┼────────────────────────────────────┘
                       │
┌──────────────────────▼────────────────────────────────────┐
│                    Rust 核心库                              │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐ │
│  │                    API 层                              │ │
│  │  对外暴露的统一接口（供各平台 FFI 调用）               │ │
│  └───────────┬────────────┬────────────┬────────────────┘ │
│              │            │            │                   │
│  ┌───────────▼───┐  ┌────▼─────┐  ┌──▼────────────────┐ │
│  │    解析层      │  │  几何层   │  │     渲染层         │ │
│  │               │  │          │  │                   │ │
│  │ FormatParser  │  │ OCCT     │  │ Tessellation      │ │
│  │ (各格式解析器) │  │ B-Rep    │  │ VBO/IBO 打包      │ │
│  │               │  │ 几何运算  │  │ 空间索引           │ │
│  └───────┬───────┘  └────┬─────┘  └────────┬──────────┘ │
│          │               │                 │             │
│          └───────┐       │       ┌─────────┘             │
│                  ▼       ▼       ▼                       │
│          ┌───────────────────────────────────┐           │
│          │         LSM 统一数据模型            │           │
│          │                                   │           │
│          │  Header / SceneTree / Geometry /   │           │
│          │  Material / Texture / Metadata     │           │
│          └───────────────────────────────────┘           │
└──────────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│                     平台渲染层                             │
│                                                          │
│  3D: Metal / Direct3D 12 / Vulkan / OpenGL ES            │
│  2D: Core Graphics / Direct2D / Native Canvas             │
└──────────────────────────────────────────────────────────┘
```

---

## 2. 分层说明

### 2.1 客户端层（Client）

> 详见 [client/README.md](client/README.md)

- 原生 UI：macOS/iOS 用 SwiftUI，Windows 用 WinUI，Android 用 Compose
- 通过 FFI 调用 Rust 核心库
- 负责：文件选择、交互操作、UI 渲染、设置管理

### 2.2 API 层

- 对外暴露的统一接口
- 跨平台兼容（通过 FFI 桥接）
- 负责：生命周期管理、错误转换、进度回调

### 2.3 解析层（Parser）

> 详见 [parser/architecture.md](parser/architecture.md)

- 每种格式一个解析器，实现统一的 `FormatParser` trait
- 依赖：OCCT（STEP/IGES）、gltf-rs、LibreDWG、自研（STL/DXF）
- 输出：LSM 统一数据模型

### 2.4 几何层（Geometry）

> 详见 [geometry/README.md](geometry/README.md)

- OCCT FFI 绑定
- B-Rep 数据结构管理
- 几何运算（求交、偏移等，v2.0+）

### 2.5 LSM 运行时模型

> 详见 [lsm/format-spec.md](lsm/format-spec.md)

- 核心运行时模型，连接解析层和渲染层
- 持久化文件格式后置，等解析与渲染契约稳定后冻结
- 支持 B-Rep 和三角网格两种几何表示

### 2.6 渲染层（Renderer）

> 详见 [renderer/README.md](renderer/README.md)

- LSM → GPU 可用数据的转换
- Tessellation、VBO/IBO 打包、空间索引
- 3D 渲染：Metal (macOS/iOS)、Direct3D (Windows)、Vulkan (Android)
- 2D 渲染：Core Graphics (macOS/iOS)、Direct2D (Windows)

---

## 3. 数据流

### 3.1 文件打开流程

```
用户选择文件
  │
  ▼
格式识别（detect_format）
  │  读取文件头，判断格式
  │
  ▼
格式解析（FormatParser::parse）
  │  每种格式各自解析
  │
  ▼
LSM 构建
  │  统一数据模型
  │
  ▼
渲染数据准备
  │  ├── 3D: Tessellation → VBO/IBO → BVH
  │  └── 2D: 几何数据 → 平台原生 Path/Canvas 数据
  │
  ▼
渲染显示
```

### 3.2 交互流程

```
用户操作（旋转/缩放/平移）
  │
  ▼
原生 UI 层处理手势
  │
  ▼
调用 Rust 核心库更新相机矩阵
  │
  ▼
渲染层重新渲染
  │
  ▼
显示更新
```

---

## 4. 依赖关系图

```
mmforge-core (核心数据模型)
  │
  ├── mmforge-geometry (几何处理)
  │     └── OCCT (FFI)
  │
  ├── mmforge-format-step (STEP 解析)
  │     └── OCCT (通过 mmforge-geometry)
  │
  ├── mmforge-format-iges (IGES 解析)
  │     └── OCCT (通过 mmforge-geometry)
  │
  ├── mmforge-format-gltf (glTF 解析)
  │     └── gltf-rs
  │
  ├── mmforge-format-stl (STL 解析)
  │     └── 无外部依赖
  │
  ├── mmforge-format-dxf (DXF 解析)
  │     └── 无外部依赖
  │
  ├── mmforge-format-dwg (DWG 解析)
  │     └── LibreDWG (FFI)
  │
  └── mmforge-render (渲染数据准备)
        └── 无外部依赖
```

---

## 5. 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 核心语言 | Rust | 内存安全、跨平台、性能好 |
| 运行时模型 | LSM | 统一数据模型，解耦解析和渲染 |
| 几何内核 | OCCT | 唯一成熟的开源 B-Rep 内核 |
| 3D 渲染 | Metal/D3D12/Vulkan | 各平台原生 GPU API，性能最优 |
| 2D 渲染 | Core Graphics/Direct2D | 系统原生，无需额外依赖 |
| UI 框架 | SwiftUI/WinUI/Compose | 各平台官方推荐 |
| FFI 桥接 | Rust C ABI + 各平台原生 | 零开销，直接调用 |

---

## 6. 模块文档索引

### 解析层

| 文档 | 内容 |
|------|------|
| [parser/README.md](parser/README.md) | 解析层总览 |
| [parser/architecture.md](parser/architecture.md) | 接口设计、格式识别、crate 结构 |
| [parser/step.md](parser/step.md) | STEP 解析器详细设计 |
| [parser/iges.md](parser/iges.md) | IGES 解析器详细设计 |
| [parser/gltf.md](parser/gltf.md) | glTF 解析器详细设计 |
| [parser/stl.md](parser/stl.md) | STL 解析器详细设计 |
| [parser/dxf.md](parser/dxf.md) | DXF 解析器详细设计 |
| [parser/dwg.md](parser/dwg.md) | DWG 解析器详细设计 |
| [parser/tessellation.md](parser/tessellation.md) | 三角化算法 |
| [parser/error-handling.md](parser/error-handling.md) | 错误处理与测试 |
| [parser/performance.md](parser/performance.md) | 性能优化策略 |

### 几何层

| 文档 | 内容 |
|------|------|
| [geometry/README.md](geometry/README.md) | 几何层总览 |
| [geometry/occt-binding.md](geometry/occt-binding.md) | OCCT FFI 绑定 |
| [geometry/brep.md](geometry/brep.md) | B-Rep 数据结构 |
| [geometry/curves-surfaces.md](geometry/curves-surfaces.md) | 曲线曲面算法 |
| [geometry/spatial-indexing.md](geometry/spatial-indexing.md) | 空间索引（BVH/AABB） |

### LSM 模型

| 文档 | 内容 |
|------|------|
| [lsm/format-spec.md](lsm/format-spec.md) | LSM 运行时模型与未来文件格式草案 |

### 渲染层

| 文档 | 内容 |
|------|------|
| [renderer/README.md](renderer/README.md) | 渲染层总览 |
| [renderer/3d-native.md](renderer/3d-native.md) | 3D 原生渲染器 |
| [renderer/2d-native.md](renderer/2d-native.md) | 2D 原生渲染器 |
| [renderer/camera.md](renderer/camera.md) | 相机控制算法 |
| [renderer/optimization.md](renderer/optimization.md) | 渲染优化 |

### 客户端

| 文档 | 内容 |
|------|------|
| [client/README.md](client/README.md) | 客户端总览（原生方案） |
| [client/macos.md](client/macos.md) | macOS 客户端设计（SwiftUI + Metal） |
| [client/rust-ffi.md](client/rust-ffi.md) | Rust FFI 桥接设计 |
| [client/ui-design.md](client/ui-design.md) | UI 设计规范 |
| [client/gestures.md](client/gestures.md) | 手势交互 |

### CLI 工具

| 文档 | 内容 |
|------|------|
| [cli/design.md](cli/design.md) | CLI 工具设计 |

---

*本文档随开发持续更新。*
