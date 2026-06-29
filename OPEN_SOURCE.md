# Open Source Statement

MMForge is an open-source project for industrial CAD/model parsing and native rendering.

## License Policy

Unless otherwise noted, MMForge source code and documentation are licensed under either:

- MIT License
- Apache License, Version 2.0

You may choose either license, at your option. This dual-license model is intended to keep the project friendly to both open-source and commercial use.

## Optional GPL Components

Some file formats require dependencies with stronger license obligations. The main example is DWG support:

- LibreDWG is licensed under GPL v3.
- Any MMForge module that links to LibreDWG must be treated as GPL-bound.
- GPL-bound modules should remain optional and separable from the permissively licensed core.
- Commercial users should review their own obligations before enabling or distributing GPL-bound DWG functionality.

The recommended architecture is:

- Keep `mmforge-core`, `mmforge-geometry`, `mmforge-render`, and permissive format parsers under MIT OR Apache-2.0.
- Keep any LibreDWG-based parser in a clearly named optional crate or feature.
- Avoid making the permissive core depend on GPL-bound code.

## Third-Party Notices

Dependencies keep their original licenses. When adding a dependency, document:

- Package name and upstream URL
- License
- Whether it is required or optional
- Whether it is used at build time, runtime, or only for development

## Trademarks And Compatibility

MMForge is not affiliated with Tech Soft 3D, HOOPS Exchange, HOOPS Visualize, Autodesk, OpenCASCADE SAS, Khronos Group, Apple, Microsoft, Google, or any other third-party vendor mentioned in the documentation.

Third-party product names are used only to describe compatibility goals, file formats, APIs, or ecosystem context.

## 中文说明

MMForge 是一个面向工业 CAD/模型解析与原生渲染的开源项目。

除非另有说明，项目源码与文档采用 MIT License 或 Apache License 2.0 双许可证发布，使用者可任选其一。这个许可策略的目标是同时支持开源使用和商业使用。

需要特别注意的是，部分格式支持可能引入更强约束的第三方依赖。例如：

- LibreDWG 采用 GPL v3 许可证。
- 任何链接 LibreDWG 的 MMForge 模块都应视为受 GPL 约束。
- 这类模块应保持可选、可分离，不能成为宽松许可证核心库的强依赖。
- 商业使用者在启用或分发 GPL 约束功能前，应自行评估合规义务。

建议将 `mmforge-core`、`mmforge-geometry`、`mmforge-render` 以及宽松许可证格式解析器保持在 MIT OR Apache-2.0 下；将基于 LibreDWG 的 DWG 解析实现放在明确命名的可选 crate 或 feature 中。
