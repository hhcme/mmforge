# MMForge

> Open-source industrial-grade 2D/3D model parser and renderer. An alternative to HOOPS Exchange + HOOPS Visualize.

[中文文档](README_zh.md)

![Project Status](https://img.shields.io/badge/status-macOS%20Alpha%20Trialable-brightgreen)
![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue)

---

## Overview

MMForge is an open-source industrial model parsing and rendering solution. It targets a complete, full-featured pipeline from file format parsing to cross-platform native rendering, with a permissively licensed core that can be used in both open-source and commercial projects.

> **Project status:** Phase 1 (macOS 3D main pipeline) is complete with 52+ acceptance tests. Phase 2 (multi-format 3D, 2D drawings, iOS) is in early development. All six formats (STEP, IGES, STL, glTF/GLB, DXF, LSM/LSMC) are integrated through the unified format routing in `mmforge-bridge`. The Metal renderer supports solid, wireframe, transparent, and x-ray modes with frustum culling, BVH picking, section fills, and async offscreen PNG export. See [docs/progress/](docs/progress/) for handoff reports.

**Key Features:**
- Multi-format parsing (STEP, IGES, glTF, STL, DXF, DWG)
- B-Rep geometry processing (based on OpenCASCADE)
- High-performance 3D rendering (Metal / Direct3D 12 / Vulkan)
- 2D drawing rendering (Core Graphics / Direct2D)
- Cross-platform native clients (macOS, iOS, Windows, Android, OpenHarmony)
- CLI tool for batch processing and automation

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Client Layer                          │
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
│                    Rust Core Library                         │
│                                                             │
│  ┌────────────┐  ┌────────────┐  ┌───────────────┐         │
│  │   Parsers  │  │    LSM     │  │  Render Data  │         │
│  │            │  │   Model    │  │               │         │
│  │ OCCT       │  │ Geometry   │  │ Tessellation  │         │
│  │ gltf-rs    │  │ Topology   │  │ VBO/IBO       │         │
│  │ LibreDWG   │  │ Materials  │  │ Spatial Index │         │
│  │ Custom     │  │ Scene Tree │  │               │         │
│  └────────────┘  └────────────┘  └───────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Component | Technology | License |
|-----------|-----------|---------|
| Core Language | Rust | MIT OR Apache 2.0 |
| Geometry Kernel | OpenCASCADE (OCCT) | LGPL 2.1 |
| STEP/IGES | OCCT built-in | - |
| glTF | gltf-rs | MIT |
| STL/DXF | Custom | - |
| DWG | Optional LibreDWG integration | GPL v3 |
| macOS/iOS UI | SwiftUI | - |
| macOS/iOS 3D | Metal | - |
| Windows UI | WinUI 3 | - |
| Windows 3D | Direct3D 12 | - |
| Android UI | Jetpack Compose | - |
| Android 3D | Vulkan / OpenGL ES | - |
| CLI | clap | MIT |

---

## Supported Formats

### 3D Formats

| Format | Priority | Parser | Status |
|--------|----------|--------|--------|
| STEP (AP203/AP214) | P0 | OCCT | Parsed with OCCT; routed by unified detection via mmforge-bridge |
| glTF 2.0 / GLB | P0 | gltf-rs | Working (macOS app via bridge; CLI via bridge crate) |
| STL (ASCII/Binary) | P0 | Custom | Working (macOS app, CLI, bridge) |
| IGES | P1 | OCCT | Parsed with OCCT; routed by unified detection via mmforge-bridge |
| DXF | P0 | Custom | Working (macOS app, CLI, bridge) |
| OBJ | P1 | Custom | Planned |
| LSM / LSMC | P1 | Custom | Working (macOS app via bridge, CLI read/write) |

### 2D Formats

| Format | Priority | Parser | Status |
|--------|----------|--------|--------|
| DXF | P0 | Custom | Working (macOS app, CLI) |
| DWG | P1 | LibreDWG | Planned |

---

## Project Structure

```
mmforge/
├── crates/                        # Rust core library
│   ├── mmforge-core/             # Core types, error model, parser traits, LSM runtime model
│   ├── mmforge-geometry/         # Geometry processing (OCCT binding, tessellation)
│   ├── mmforge-render/           # RenderPacket, camera, render data preparation
│   └── mmforge-cli/              # CLI tool
├── macos/                         # macOS client (SwiftUI + Metal)
│   └── MMForge/                  # Xcode project
│       ├── App/                  # SwiftUI App entry, AppDelegate
│       ├── Views/                # ContentView, Sidebar, Inspector, Viewport
│       ├── Document/             # FileDocument type
│       ├── Metal/                # Metal view placeholder
│       ├── RustBridge/           # Swift ↔ Rust FFI bridge
│       ├── DesignSystem/         # Color tokens, design constants
│       └── Resources/            # Info.plist
├── docs/                          # Documentation
│   ├── development-plan.md       # Full-scope phased development plan
│   ├── requirements.md           # Requirements
│   ├── architecture.md           # Architecture overview
│   ├── progress/                 # Goal completion handoff reports
│   ├── adr/                      # Architecture Decision Records
│   ├── parser/                   # Parser design docs
│   ├── geometry/                 # Geometry engine docs
│   ├── lsm/                      # LSM runtime model and future file format draft
│   ├── renderer/                 # Renderer design docs
│   ├── client/                   # Client design docs
│   └── cli/                      # CLI design docs
├── .github/                       # CI/CD workflows
├── README.md                     # This file
├── README_zh.md                  # Chinese documentation
├── Cargo.toml                    # Rust workspace root
├── LICENSE                       # License summary
├── LICENSE-APACHE                # Apache 2.0 license
├── OPEN_SOURCE.md                # Open-source compliance
└── CONTRIBUTING.md               # Contribution guidelines
```

---

## Getting Started

### Prerequisites

- **Rust** 1.85+ (stable) — install via [rustup](https://rustup.rs/)
- **Xcode** 16+ (for macOS builds) — install from the Mac App Store

### Build & Test (Rust)

```bash
# Build the workspace
cargo build --workspace

# Run all tests
cargo test --workspace

# Check formatting
cargo fmt --check

# Run linter
cargo clippy --workspace -- -D warnings

# Run the CLI
cargo run --bin mmforge -- version
```

### Build macOS App (Xcode)

Prerequisites:
- **Xcode** 26+ (with macOS 26 SDK)
- **Rust** stable toolchain in `~/.cargo/bin/`

```bash
# Open the Xcode project
open macos/MMForge.xcodeproj

# Or build from CLI (Debug, no code signing)
xcodebuild build \
  -project macos/MMForge.xcodeproj \
  -scheme MMForge \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

The built app is at `macos/build/Build/Products/Debug/MMForge.app`.

### Run macOS Tests

```bash
xcodebuild test \
  -project macos/MMForge.xcodeproj \
  -scheme MMForge \
  -derivedDataPath macos/build \
  -destination 'platform=macOS'
```

### Package macOS App (Release + DMG)

```bash
# Release .app only (unsigned)
bash macos/scripts/package.sh release

# Release .app + DMG (unsigned)
bash macos/scripts/package.sh dmg

# Debug build + symlink
bash macos/scripts/package.sh debug
```

The DMG is at `macos/build/MMForge-0.1.0-alpha.dmg`.

### macOS Document Type Support

The app registers as a viewer for these file types (Finder "Open With" +
double-click to open):

| Extension | Format | macOS UTI |
|-----------|--------|-----------|
| .step, .stp | STEP | `com.mmforge.step` |
| .igs, .iges | IGES | `com.mmforge.iges` |
| .stl | STL | `com.mmforge.stl` |
| .gltf | glTF | `com.mmforge.gltf` |
| .glb | glTF Binary | `com.mmforge.glb` |
| .dxf | DXF Drawing | `com.mmforge.dxf` |
| .lsm | LSM Model | `com.mmforge.lsm` |
| .lsmc | LSM Compressed | `com.mmforge.lsmc` |

### Known Limitations (macOS Alpha)

- **No OCCT by default**: STEP and IGES files require OpenCASCADE.
  Without OCCT the app shows build guidance.  With OCCT linked, STEP/IGES
  parse and render B-Rep models.
- **glTF requires bridge crate**: The standalone CLI (`mmforge`) supports
  STL, DXF, LSM/LSMC via its own detection.  glTF, STEP, IGES are available
  through the macOS bridge crate (`mmforge-bridge`) which provides the full
  format cascade: DXF → STL → glTF/GLB → IGES → LSM/LSMC → STEP.
- **Unsigned app**: The Debug build and Release DMG are unsigned.  macOS
  Gatekeeper will block first launch — right-click → Open to bypass.
- **No sandbox / Hardened Runtime**: Not configured for App Store or
  notarized distribution yet.
- **Metal GPU required**: Rendering needs Apple Silicon or Intel Mac with
  Metal-capable GPU.

---

## Repository

- GitHub: [hhcme/mmforge](https://github.com/hhcme/mmforge)
- Default branch: `main`
- Current focus: native macOS foundation, STEP parsing, the LSM runtime model, and Metal rendering.

---

## Development Roadmap

| Phase | Duration | Goal |
|-------|----------|------|
| Phase 1 | 3-4 months | ✅ Native macOS foundation: STEP parsing + Metal rendering — COMPLETE |
| Phase 2 | 3-4 months | Multi-format 3D + 2D drawing + polish (in progress) |
| Phase 3 | 3-4 months | iOS + complete viewer workflows |
| Phase 4 | Future | Windows, Android, OpenHarmony |

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/requirements.md](docs/requirements.md) | Requirements document |
| [docs/development-plan.md](docs/development-plan.md) | Full-scope phased development plan |
| [docs/progress/](docs/progress/) | Goal completion handoff reports |
| [docs/architecture.md](docs/architecture.md) | Architecture overview |
| [docs/parser/](docs/parser/) | Parser design (STEP, glTF, STL, DXF, DWG, algorithms) |
| [docs/geometry/](docs/geometry/) | Geometry engine (OCCT, B-Rep, curves/surfaces, spatial indexing) |
| [docs/lsm/format-spec.md](docs/lsm/format-spec.md) | LSM runtime model and future file format draft |
| [docs/renderer/](docs/renderer/) | Renderer design (3D, 2D, camera, optimization) |
| [docs/client/](docs/client/) | Client design (macOS, Rust FFI, UI, gestures) |
| [docs/cli/](docs/cli/) | CLI tool design |

---

## AI Agent Guide

> This section is for AI agents (like GitHub Copilot, Cursor, Claude, etc.) to understand the project context.

### Project Identity

- **Name:** MMForge
- **Language:** Rust (core) + Swift (macOS/iOS) + C++ (OCCT binding)
- **Purpose:** Open-source alternative to HOOPS SDK for industrial CAD visualization
- **License:** Core project is dual-licensed under MIT OR Apache-2.0. Optional DWG support based on LibreDWG is GPL-3.0-bound and must remain isolated from the permissive core.

### Key Concepts

1. **LSM (MMForge Model):** The unified runtime model. All parsers convert source files to LSM. Renderers consume LSM. A persistent `.lsm` file format will be stabilized after parsing and rendering contracts mature. See [docs/lsm/format-spec.md](docs/lsm/format-spec.md).

2. **Format Parser Trait:** All format parsers implement `FormatParser` trait defined in `mmforge-core`. See [docs/parser/architecture.md](docs/parser/architecture.md).

3. **B-Rep vs Mesh:** STEP/IGES files contain B-Rep (parametric surfaces). glTF/STL files contain triangle meshes. Tessellation converts B-Rep to meshes for rendering.

4. **OCCT (OpenCASCADE):** The geometry kernel. Used for STEP/IGES parsing and tessellation. It's a large C++ library (~2000万 lines) accessed via FFI.

### Code Organization Rules

- Core logic goes in `crates/mmforge-core` — no platform-specific code
- Each format parser is a separate crate: `crates/mmforge-format-*`
- Platform UI code goes in platform directories: `macos/`, `ios/`, `windows/`, `android/`
- All documentation goes in `docs/` with per-module subdirectories

### When Adding a New Format Parser

1. Create `crates/mmforge-format-{name}/`
2. Implement `FormatParser` trait from `mmforge-core`
3. Add format detection in `detect_format()` function
4. Add documentation in `docs/parser/{name}.md`
5. Update `docs/parser/README.md` and `docs/architecture.md`

### When Working on Rendering

- macOS/iOS: Use Metal directly
- Windows: Use Direct3D 12
- Android: Use Vulkan or OpenGL ES
- All platforms: Render data is prepared in Rust (`mmforge-render`), consumed by platform-specific renderers
- Keep the core product route on native platform rendering APIs

### Performance Considerations

- Large STEP files can be hundreds of MB with millions of entities
- Use memory mapping (mmap) for large files
- Use streaming parsing where possible
- Use parallel processing (rayon) for tessellation
- Use spatial indexing (BVH) for ray picking and frustum culling

### Key Files to Read First

1. `docs/requirements.md` — What we're building
2. `docs/architecture.md` — How it's organized
3. `docs/parser/architecture.md` — Parser interface design
4. `docs/lsm/format-spec.md` — Core data model
5. `docs/client/macos.md` — macOS client design

---

## Contributing

Contributions are welcome once the first implementation modules start landing. For now, the most useful contributions are requirement review, architecture feedback, format-specific design notes, and small documentation fixes.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for vulnerability reporting.

---

## License

Unless otherwise noted, MMForge is distributed under the terms of either the MIT License or the Apache License 2.0, at your option.

Some optional integrations may carry their own license obligations. In particular, any DWG parser implementation that links to LibreDWG is subject to GPL v3 terms and should be treated as an optional, separable component. See [OPEN_SOURCE.md](OPEN_SOURCE.md) for details.
