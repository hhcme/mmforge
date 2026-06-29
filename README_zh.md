# MMForge

> 开源工业级 2D/3D 模型解析与渲染引擎，替代 HOOPS Exchange + HOOPS Visualize 的完整方案。

[English](README.md)

![项目状态](https://img.shields.io/badge/status-Phase%200%20complete--%20Phase%201%20in%20progress-orange)
![许可证](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue)

---

## 项目简介

MMForge 是一套开源工业模型解析与渲染方案，目标是构建完整的全功能链路：从文件格式解析、统一运行时模型、渲染数据准备，到跨平台原生渲染。项目核心采用宽松开源许可证，允许在开源和商业项目中使用。

> **项目状态：** Phase 0（仓库工程基础）已完成。Rust workspace、macOS SwiftUI 应用壳和 CI 流水线已可运行。Phase 1（LSM 运行时模型、OCCT 集成、Metal 渲染）正在进行中。交接报告见 [docs/progress/](docs/progress/)。

**核心特性：**
- 多格式解析（STEP、IGES、glTF、STL、DXF、DWG）
- B-Rep 几何处理（基于 OpenCASCADE）
- 高性能 3D 渲染（Metal / Direct3D 12 / Vulkan）
- 2D 图纸渲染（Core Graphics / Direct2D）
- 跨平台原生客户端（macOS、iOS、Windows、Android、OpenHarmony）
- 命令行工具，支持批量处理和自动化

---

## 架构总览

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
│                      │ FFI (C ABI)                         │
└──────────────────────┼─────────────────────────────────────┘
                       │
┌──────────────────────▼─────────────────────────────────────┐
│                    Rust 核心库                               │
│                                                             │
│  ┌────────────┐  ┌────────────┐  ┌───────────────┐         │
│  │   解析层    │  │  LSM 模型   │  │   渲染数据层   │         │
│  │            │  │            │  │               │         │
│  │ OCCT       │  │ 几何/拓扑   │  │ Tessellation  │         │
│  │ gltf-rs    │  │ 材质/颜色   │  │ VBO/IBO       │         │
│  │ LibreDWG   │  │ 场景树     │  │ 空间索引       │         │
│  │ 自研       │  │ 元数据     │  │               │         │
│  └────────────┘  └────────────┘  └───────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

---

## 技术栈

| 组件 | 技术 | 许可证 |
|------|------|--------|
| 核心语言 | Rust | MIT OR Apache 2.0 |
| 几何内核 | OpenCASCADE (OCCT) | LGPL 2.1 |
| STEP/IGES 解析 | OCCT 内置 | - |
| glTF 解析 | gltf-rs | MIT |
| STL/DXF 解析 | 自研 | - |
| DWG 解析 | 可选 LibreDWG 集成 | GPL v3 |
| macOS/iOS UI | SwiftUI | - |
| macOS/iOS 3D | Metal | - |
| Windows UI | WinUI 3 | - |
| Windows 3D | Direct3D 12 | - |
| Android UI | Jetpack Compose | - |
| Android 3D | Vulkan / OpenGL ES | - |
| CLI | clap | MIT |

---

## 支持格式

### 3D 格式

| 格式 | 优先级 | 解析方案 | 状态 |
|------|--------|---------|------|
| STEP (AP203/AP214) | P0 | OCCT | 计划中 |
| glTF 2.0 | P0 | gltf-rs | 计划中 |
| STL | P0 | 自研 | 计划中 |
| IGES | P1 | OCCT | 计划中 |
| OBJ | P1 | 自研 | 计划中 |

### 2D 格式

| 格式 | 优先级 | 解析方案 | 状态 |
|------|--------|---------|------|
| DXF | P0 | 自研 | 计划中 |
| DWG | P1 | LibreDWG | 计划中 |

---

## 项目结构

```
mmforge/
├── crates/                        # Rust 核心库
│   ├── mmforge-core/             # 核心类型、错误模型、解析器 trait、LSM 运行时模型
│   ├── mmforge-geometry/         # 几何处理（OCCT 绑定、tessellation）
│   ├── mmforge-render/           # RenderPacket、相机、渲染数据准备
│   └── mmforge-cli/              # 命令行工具
├── macos/                         # macOS 客户端（SwiftUI + Metal）
│   └── MMForge/                  # Xcode 工程
│       ├── App/                  # SwiftUI App 入口、AppDelegate
│       ├── Views/                # ContentView、Sidebar、Inspector、Viewport
│       ├── Document/             # FileDocument 类型
│       ├── Metal/                # Metal 视图占位
│       ├── RustBridge/           # Swift ↔ Rust FFI 桥接
│       ├── DesignSystem/         # 颜色 token、设计常量
│       └── Resources/            # Info.plist
├── docs/                          # 文档
│   ├── development-plan.md       # 全功能分阶段开发计划
│   ├── requirements.md           # 需求文档
│   ├── architecture.md           # 架构总览
│   ├── progress/                 # 目标完成后的交接报告
│   ├── adr/                      # 架构决策记录
│   ├── parser/                   # 解析器设计文档
│   ├── geometry/                 # 几何引擎文档
│   ├── lsm/                      # LSM 运行时模型与未来文件格式草案
│   ├── renderer/                 # 渲染器设计文档
│   ├── client/                   # 客户端设计文档
│   └── cli/                      # CLI 工具文档
├── .github/                       # CI/CD 工作流
├── README.md                     # 英文文档
├── README_zh.md                  # 本文件
├── Cargo.toml                    # Rust workspace 根配置
├── LICENSE                       # 许可证摘要
├── LICENSE-APACHE                # Apache 2.0 许可证
├── OPEN_SOURCE.md                # 开源合规说明
└── CONTRIBUTING.md               # 贡献指南
```

---

## 快速开始

### 环境要求

- **Rust** 1.85+（stable）— 通过 [rustup](https://rustup.rs/) 安装
- **Xcode** 16+（macOS 构建）— 从 Mac App Store 安装

### 构建与测试（Rust）

```bash
# 构建 workspace
cargo build --workspace

# 运行所有测试
cargo test --workspace

# 检查格式
cargo fmt --check

# 运行 linter
cargo clippy --workspace -- -D warnings

# 运行 CLI
cargo run --bin mmforge -- version
```

### 构建 macOS 应用

```bash
xcodebuild build \
  -project macos/MMForge.xcodeproj \
  -scheme MMForge \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

---

## 仓库信息

- GitHub：[hhcme/mmforge](https://github.com/hhcme/mmforge)
- 默认分支：`main`
- 当前重点：原生 macOS 基础能力、STEP 解析、LSM 运行时模型、Metal 渲染。

---

## 开发路线

| 阶段 | 周期 | 目标 |
|------|------|------|
| Phase 1 | 3-4 个月 | 原生 macOS 基础能力：STEP 解析 + Metal 渲染 |
| Phase 2 | 3-4 个月 | 更多格式 + 原生 2D 图纸支持 |
| Phase 3 | 3-4 个月 | iOS + 完整查看工作流 |
| Phase 4 | 后续 | Windows、Android、OpenHarmony |

---

## 文档索引

| 文档 | 说明 |
|------|------|
| [docs/requirements.md](docs/requirements.md) | 需求文档 |
| [docs/development-plan.md](docs/development-plan.md) | 全功能分阶段开发计划 |
| [docs/progress/](docs/progress/) | 目标完成后的交接报告 |
| [docs/architecture.md](docs/architecture.md) | 架构总览 |
| [docs/parser/](docs/parser/) | 解析器设计（STEP、glTF、STL、DXF、DWG、算法） |
| [docs/geometry/](docs/geometry/) | 几何引擎（OCCT、B-Rep、曲线曲面、空间索引） |
| [docs/lsm/format-spec.md](docs/lsm/format-spec.md) | LSM 运行时模型与未来文件格式草案 |
| [docs/renderer/](docs/renderer/) | 渲染器设计（3D、2D、相机、优化） |
| [docs/client/](docs/client/) | 客户端设计（macOS、Rust FFI、UI、手势） |
| [docs/cli/](docs/cli/) | CLI 工具设计 |

---

## AI Agent 指南

> 本节为 AI 代理（如 GitHub Copilot、Cursor、Claude 等）提供项目上下文。

### 项目基本信息

- **项目名称：** MMForge
- **核心语言：** Rust（核心库）+ Swift（macOS/iOS）+ C++（OCCT 绑定）
- **项目定位：** 开源替代 HOOPS SDK 的工业 CAD 可视化方案
- **许可证：** 核心项目采用 MIT OR Apache-2.0 双许可证。基于 LibreDWG 的可选 DWG 支持受 GPL v3 约束，需要与宽松许可证核心保持隔离。

### 核心概念

1. **LSM（MMForge Model）：** 统一运行时模型。所有解析器将源文件转换为 LSM，渲染器消费 LSM。持久化 `.lsm` 文件格式会在解析与渲染契约稳定后再固化。详见 [docs/lsm/format-spec.md](docs/lsm/format-spec.md)。

2. **FormatParser Trait：** 所有格式解析器实现 `mmforge-core` 中定义的 `FormatParser` trait。详见 [docs/parser/architecture.md](docs/parser/architecture.md)。

3. **B-Rep vs Mesh：** STEP/IGES 文件包含 B-Rep（参数化曲面），glTF/STL 文件包含三角网格。Tessellation 将 B-Rep 转换为网格用于渲染。

4. **OCCT（OpenCASCADE）：** 几何内核，用于 STEP/IGES 解析和 tessellation。是大型 C++ 库（约 2000 万行代码），通过 FFI 访问。

### 代码组织规则

- 核心逻辑放在 `crates/mmforge-core` — 不含平台特定代码
- 每个格式解析器是独立 crate：`crates/mmforge-format-*`
- 平台 UI 代码放在平台目录：`macos/`、`ios/`、`windows/`、`android/`
- 所有文档放在 `docs/`，按模块分子目录

### 添加新格式解析器时

1. 创建 `crates/mmforge-format-{name}/`
2. 实现 `mmforge-core` 中的 `FormatParser` trait
3. 在 `detect_format()` 函数中添加格式检测
4. 在 `docs/parser/{name}.md` 添加文档
5. 更新 `docs/parser/README.md` 和 `docs/architecture.md`

### 渲染相关

- macOS/iOS：直接使用 Metal
- Windows：使用 Direct3D 12
- Android：使用 Vulkan 或 OpenGL ES
- 所有平台：渲染数据在 Rust 中准备（`mmforge-render`），由平台特定渲染器消费
- 核心产品路线保持在平台原生渲染 API 上

### 性能注意事项

- 大型 STEP 文件可能几百 MB，包含百万级 entity
- 大文件使用内存映射（mmap）
- 尽可能使用流式解析
- 使用并行处理（rayon）进行 tessellation
- 使用空间索引（BVH）进行射线拾取和视锥裁剪

### 建议优先阅读的文件

1. `docs/requirements.md` — 我们在构建什么
2. `docs/architecture.md` — 如何组织
3. `docs/parser/architecture.md` — 解析器接口设计
4. `docs/lsm/format-spec.md` — 核心数据模型
5. `docs/client/macos.md` — macOS 客户端设计

---

## 贡献指南

欢迎在首批实现模块落地后参与贡献。当前最有价值的贡献包括需求审阅、架构反馈、格式专项设计建议和小型文档修正。

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请参考 [SECURITY.md](SECURITY.md)。

---

## 许可证

除非另有说明，MMForge 以 MIT License 或 Apache License 2.0 双许可证发布，使用者可任选其一。

部分可选集成可能带有独立许可证义务。特别是，如果 DWG 解析实现链接 LibreDWG，则该实现受 GPL v3 约束，应作为可选、可分离组件处理。详见 [OPEN_SOURCE.md](OPEN_SOURCE.md)。
