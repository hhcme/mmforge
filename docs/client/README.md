# 客户端总览

> MMForge 原生客户端应用的设计。

---

## 职责

- 原生 UI 界面
- 用户交互（手势、菜单、设置）
- 文件管理（打开、最近文件、收藏）
- 通过 FFI 调用 Rust 核心库

## 技术选型：原生开发

使用各平台官方推荐的最新稳定技术，发挥硬件最大性能。具体 SDK 版本在发布分支中锁定；主线默认跟进当前稳定工具链。

| 平台 | UI 框架 | 3D 渲染 | Rust 桥接 | 状态 |
|------|---------|---------|----------|------|
| macOS | SwiftUI | Metal | FFI (Swift-Rust) | P0 第一批 |
| iOS | SwiftUI | Metal | FFI (Swift-Rust) | P0 第一批 |
| Windows | WinUI 3 | Direct3D 12 | FFI (C++-Rust) | P1 |
| Android | Jetpack Compose | Vulkan / GLES | JNI / FFI | P1 |
| OHOS | ArkUI | OpenGL ES | NAPI | P2 |

### 原生方案原则

| 维度 | 原生策略 |
|------|----------|
| 3D 渲染性能 | 直接使用 Metal / Direct3D 12 / Vulkan / OpenGL ES |
| UI 性能 | 使用各平台官方 UI 渲染管线 |
| 原生体验 | 完整遵循平台交互、菜单、窗口、输入和辅助功能规范 |
| 包体积 | 不引入额外跨平台 UI 引擎 |
| 开发效率 | Rust 核心共享，平台 UI 和渲染适配按平台实现 |
| 代码共享 | 核心解析、几何、渲染数据准备共享；交互体验保持平台原生 |

### 代码共享策略

```
┌─────────────────────────────────────┐
│         共享层 (Rust)               │
│  mmforge-core / geometry / render   │
│  所有平台 100% 共享                  │
└──────────────┬──────────────────────┘
               │ FFI
┌──────────────┴──────────────────────┐
│         平台 UI 层                   │
│                                     │
│  macOS + iOS: SwiftUI (共享 90%)    │
│  Windows:     WinUI 3               │
│  Android:     Jetpack Compose       │
│  OHOS:        ArkUI                 │
└─────────────────────────────────────┘
```

## 模块文档

| 文档 | 内容 |
|------|------|
| [macos.md](macos.md) | macOS 客户端设计（SwiftUI + Metal） |
| [rust-ffi.md](rust-ffi.md) | Rust FFI 桥接设计 |
| [ui-design.md](ui-design.md) | UI 设计规范 |
| [gestures.md](gestures.md) | 手势交互设计 |
