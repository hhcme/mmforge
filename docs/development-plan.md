# MMForge 全功能开发计划

> 面向目标模式执行的完整产品开发计划。项目先完成 macOS 原生版本，再将稳定的 Rust 核心、LSM 运行时模型、渲染数据层和交互模型扩展到 iOS、Windows、Android、OpenHarmony。
>
> 最后更新：2026-07-13 — Phase 1 closure complete; unified format routing landed

---

## 1. 开发原则

### 1.1 产品目标

MMForge 要做完整的工业 2D/3D 模型解析与原生渲染产品。开发顺序采用“先主链路、后全能力”的方式，但每个阶段都服务最终全功能版本。

### 1.2 平台顺序

| 顺序 | 平台 | 技术路线 | 目标 |
|------|------|----------|------|
| 1 | macOS | SwiftUI + AppKit interop + Metal + Core Graphics | 首个完整桌面版本 |
| 2 | iOS / iPadOS | SwiftUI + UIKit interop + Metal | 复用 Apple 平台核心能力 |
| 3 | Windows | WinUI 3 + Direct3D 12 + Direct2D | 第二个桌面平台 |
| 4 | Android | Jetpack Compose + Vulkan / GLES fallback | 移动端扩展 |
| 5 | OpenHarmony | ArkUI + OpenGL ES / 平台图形 API | 后续国产生态扩展 |

### 1.3 技术策略

- 原生优先：UI、窗口、菜单、输入、渲染都使用平台原生能力。
- 最新稳定工具链优先：主线跟进当前稳定 SDK；具体最低系统版本在发布分支按功能矩阵确定。
- Rust 核心共享：解析、LSM 运行时模型、几何、渲染数据准备、空间索引、CLI 共享。
- 平台适配变薄：平台层负责窗口、输入、GPU 资源、系统集成，不重复实现解析逻辑。
- LSM 运行时优先：先稳定内存模型与查询接口，`.lsm` 文件格式后置。
- 开源合规优先：MIT OR Apache-2.0 核心与 GPL-bound 可选模块保持清晰隔离。

### 1.4 Apple 设计规范要求

macOS 版本必须遵守 Apple Human Interface Guidelines：

- 使用符合 macOS 习惯的 window、toolbar、sidebar、split view、inspector、menu bar、keyboard shortcuts。
- 保持原生控件行为，不用自绘替代标准控件，除非渲染视图必须自绘。
- 支持系统外观、Dark Mode、动态文本相关能力、键盘导航和辅助功能。
- 工具栏使用图标+简短标签，复杂工具放入 inspector 或 popover。
- 文档型工作流要符合 macOS 文件打开、最近文件、多窗口、拖放、保存/导出习惯。

参考：

- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines/
- macOS app design: https://developer.apple.com/design/human-interface-guidelines/macos
- SwiftUI: https://developer.apple.com/xcode/swiftui/
- Metal: https://developer.apple.com/metal/

---

## 2. 目标模式执行格式

给执行模型的一句话提示：

```text
请阅读 `/Volumes/hhcStorage/hhc_project/mmforge/docs/development-plan.md` 和 `docs/progress/` 中已有报告，按计划继续或执行我指定的当前目标，严格遵守架构契约、算法细则、验收标准和交接报告规则，完成后把报告写入 `docs/progress/YYYY-MM-DD-target-name.md`。
```

每个目标都按以下格式执行：

```text
目标：一句话说明本目标要完成什么
范围：本目标包含/不包含什么
交付物：代码、文档、测试、示例文件、验收报告
验收标准：可运行、可测试、可截图/录屏验证的标准
依赖：前置模块或外部工具
风险：主要不确定性和降级策略
```

完成一个目标后，根据计划和已有报告继续下一个目标；如果用户指定了目标，则以用户指定目标为准。跨阶段返工需要记录到需求或 ADR 文档。

---

## 3. 总体架构契约

目标模式执行时，任何阶段都不能绕过这些架构契约。

### 3.1 模块边界

| 模块 | 职责 | 不允许做的事 |
|------|------|--------------|
| `mmforge-core` | LSM 运行时模型、错误类型、parser trait、基础数学类型、文档无关核心 API | 依赖 OCCT、Metal、Swift、平台 UI |
| `mmforge-geometry` | OCCT FFI、安全 wrapper、B-Rep 访问、tessellation adapter | 直接读取 UI 状态或平台文件面板 |
| `mmforge-format-*` | 单一格式解析和转换到 LSM runtime model | 调用平台渲染 API |
| `mmforge-render` | LSM -> RenderPacket、batching、material mapping、BVH、LOD 输入数据 | 直接创建 `MTLBuffer` / D3D / Vulkan resource |
| `mmforge-cli` | 命令行编排、info/validate/convert/benchmark | 复制 parser 或 renderer 业务逻辑 |
| `macos/MMForge` | SwiftUI/AppKit shell、Metal adapter、文件工作流、HIG UI | 重新实现 STEP/DXF/glTF 解析 |

### 3.2 数据流

```text
Source File
  -> Format Detection
  -> FormatParser
  -> LSM Runtime Model
  -> RenderPacket / DrawingDrawList
  -> Platform Renderer Adapter
  -> Native View
```

所有平台都必须消费相同的 LSM runtime model 和 RenderPacket/DrawingDrawList。平台层只能做资源上传、窗口输入、系统集成和绘制命令提交。

### 3.3 错误与 warning 模型

解析器不能只返回 `Result<LsmModel>`；需要同时保留 warning：

```rust
pub struct ParseOutput {
    pub model: LsmModel,
    pub warnings: Vec<ParseWarning>,
    pub stats: ParseStats,
}

pub enum ParseWarning {
    UnsupportedEntity { entity_type: String, count: usize },
    MissingMaterial { node_id: NodeId },
    PrecisionLoss { message: String },
    RecoveredFromInvalidTopology { message: String },
}
```

规则：

- 致命错误返回 `Err`.
- 可恢复问题进入 `warnings`.
- UI 必须能显示 warning 摘要。
- CLI `validate` 必须能把 warning 输出为 JSON。

### 3.4 ID 与引用规则

- `NodeId`、`GeometryId`、`MaterialId`、`TextureId` 使用 typed id，不直接裸用 `u32`。
- LSM 内部引用必须可验证：任何 id 引用都能检测 dangling reference。
- scene tree 是用户交互主入口，不能只保存 mesh list。
- 装配结构、图层、颜色 override 都应挂在 scene node 或 metadata 上。

### 3.5 坐标与单位规则

- LSM 内部长度单位默认保存源单位，同时记录 `Units`。
- 渲染数据可以转换为 float，但测量和元数据保留 double precision。
- 坐标轴约定必须写入 `docs/architecture.md` 或 ADR：默认右手系，Z-up；导入格式如有差异必须在 parser adapter 转换或记录 transform。

---

## 4. 核心算法执行细则

### 4.1 格式识别算法

状态：✅ 已实现统一格式路由（`crates/mmforge-bridge/src/format_route.rs`），单一 `DetectedFormat` 枚举和 `detect()` 函数被 `mmf_parse_file`、`parse_with_detection`、异步任务进度标签三个调用点共享。

算法：

```text
1. 读取文件前 84 字节（支持 binary STL 80-byte header + u32 count）。
2. 按优先级顺序检测：DXF → STL → glTF/GLB → IGES → LSM/LSMC → STEP（兜底）。
3. 各检测器使用扩展名 + header 特征联合判断。
4. 检测结果作为单一 DetectedFormat 枚举值返回，所有调用点派生自此结果。
5. 解析器启动后再次验证格式，不信任检测阶段。
```

验收：

- 空文件、随机二进制、扩展名错误文件都有测试。
- ASCII STL 与 binary STL header 为 `solid` 的冲突有测试。
- 所有六种格式的 sync/async 类型、节点数、2D 标记和错误路径一致性均有测试覆盖。

### 4.2 STEP / OCCT 解析算法

目标：

- 第一阶段使用 OCCT 读取 STEP，避免自研 EXPRESS parser。
- 通过 safe wrapper 隔离 C++ 生命周期和 unsafe。

流程：

```text
1. StepParser 接收 path 或 reader。
2. OCCT adapter 创建 STEPControl_Reader。
3. 读取文件，收集 transfer status。
4. transfer roots。
5. 获取 TopoDS_Shape。
6. 如果启用 XDE，读取 assembly/product/color/layer；否则至少提取 shape tree。
7. 遍历 TopoDS_Shape：
   - TopAbs_SOLID -> Solid node
   - TopAbs_SHELL -> Shell metadata
   - TopAbs_FACE -> Face/BRep info
8. 计算 bounding box。
9. 输出 LSM runtime model + warnings + stats。
```

安全要求：

- OCCT 原始指针不能泄漏到 `mmforge-core`。
- `unsafe` 只允许出现在 `mmforge-geometry/src/occt/sys` 或 `adapter`。
- 所有 OCCT handle wrapper 必须实现明确 Drop 策略。
- 解析失败不得 panic。

AP242/XDE 决策：

- 初期文档允许 AP203/AP214 基础查看。
- 产品结构、颜色、图层如果基础 reader 不够，需要评估 OCCT XDE。
- 评估结果必须写 ADR，再决定是否引入 TKXDE。

### 4.3 Tessellation 算法

目标：

- 使用 OCCT `BRepMesh_IncrementalMesh` 作为第一实现。
- 输出平台无关 mesh。

流程：

```text
1. 输入 TopoDS_Shape 或 BRep handle。
2. 根据模型 bounding box 和质量等级计算 deflection。
3. 调用 OCCT incremental mesh。
4. 遍历 face triangulation。
5. 修正 face orientation。
6. 合并全局 vertex/index buffer。
7. 为每个 face/submesh 保存 material_id/node_id。
8. 计算 normals、bounds、triangle count。
9. 输出 RenderMesh。
```

质量等级：

| 等级 | 用途 | linear deflection |
|------|------|-------------------|
| preview | 大模型快速显示 | bbox diagonal * 0.002 |
| standard | 默认查看 | bbox diagonal * 0.0005 |
| high | 截图/检查 | bbox diagonal * 0.0001 |

验收：

- 简单 box 三角形数稳定。
- cylinder/curved surface 法线正确。
- reversed face 不出现背面剔除错误。
- tessellation stats 可输出到 CLI。

### 4.4 RenderPacket 架构

目标：

- Metal/D3D12/Vulkan 都能消费同一份 packet。

结构：

```rust
pub struct RenderPacket {
    pub meshes: Vec<RenderMesh>,
    pub materials: Vec<RenderMaterial>,
    pub instances: Vec<RenderInstance>,
    pub batches: Vec<RenderBatch>,
    pub scene_bounds: BoundingBox,
    pub stats: RenderStats,
}
```

生成算法：

```text
1. 遍历 scene tree。
2. 收集 visible renderable nodes。
3. 将 LSM geometry 映射为 RenderMesh。
4. 将 material 映射为 renderer-neutral material。
5. 相同 geometry + material 的节点生成 instances。
6. 按 material、透明度、渲染模式生成 batches。
7. 构建 BVH 输入数据。
```

验收：

- RenderPacket 不包含 Metal 类型。
- 同一个 LSM 可被 CLI 打印 stats。
- 可序列化为 debug JSON 供检查。

### 4.5 Metal 渲染算法

目标：

- macOS 第一版 Metal adapter 只消费 RenderPacket。

流程：

```text
1. MTKView 创建 device、commandQueue、depth texture。
2. RenderPacket 上传：
   - positions/normals/uvs -> vertex buffers
   - indices -> index buffers
   - instances -> instance buffer
   - materials -> uniform/argument buffer
3. 每帧更新 camera uniform。
4. 按 RenderBatch 提交 drawIndexedPrimitives。
5. solid pass -> optional wire overlay -> selection highlight -> UI overlay。
6. 输出 render stats。
```

shader 要求：

- `vertex_main` 支持 model/view/projection。
- `fragment_solid` 支持 base color、normal lighting。
- wireframe 第一阶段可用 edge overlay 或 barycentric 后续实现。
- 剖切面后续通过 uniform plane discard。

验收：

- resize 正常重建 depth texture。
- 没有 drawable 时安全跳过。
- GPU resource 生命周期清晰，不在每帧重复全量创建 buffer。

### 4.6 Orbit Camera 算法

状态：

```rust
pub struct OrbitCamera {
    pub target: Vec3,
    pub distance: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub fov_y: f32,
    pub near: f32,
    pub far: f32,
}
```

算法：

```text
rotate:
  yaw += dx * sensitivity
  pitch = clamp(pitch + dy * sensitivity, -89deg, 89deg)

zoom:
  distance *= exp(-wheel_delta * zoom_speed)
  distance = clamp(distance, min_distance, max_distance)

pan:
  right/up from view matrix
  world_delta = (-dx * right + dy * up) * distance * pan_scale
  target += world_delta

fit:
  target = bounds.center
  distance = bounds.radius / tan(fov_y / 2) * margin
  near/far = derived from radius, with sensible minimum
```

验收：

- fit 后模型完整可见。
- pan 速度随 distance 缩放。
- pitch 不翻转。
- 鼠标、触控板、快捷键都调用同一 camera core。

### 4.7 BVH 与选择算法

构建：

```text
1. 为每个 triangle 计算 AABB 和 centroid。
2. 递归选择最长轴。
3. 按 centroid median split。
4. 叶子阈值 4-16 triangles。
5. 保存 node bounds、child indices、triangle range。
```

射线：

```text
1. screen point -> NDC。
2. NDC -> inverse projection -> view ray。
3. inverse view -> world ray。
4. BVH traversal，先近后远。
5. triangle intersection 用 Moller-Trumbore。
6. 返回 node_id、geometry_id、triangle_id、hit position、distance。
```

验收：

- 点击简单 box 能选中正确 node。
- 空白区域返回 none。
- BVH 查询结果与 brute force 查询一致。

### 4.8 DXF 2D 算法

Tokenizer：

```text
1. DXF 是 group code + value 两行一组。
2. tokenizer 输出 DxfPair { code, raw_value, line }。
3. section parser 根据 0/SECTION, 2/<name>, 0/ENDSEC 切段。
```

Entity parser：

```text
1. 收集一个 entity 的所有 group pairs。
2. 根据 type dispatch。
3. LINE/CIRCLE/ARC/LWPOLYLINE/TEXT 为首批。
4. TABLES 解析 layer、line type、style。
5. BLOCKS 保存 block definition。
6. INSERT 阶段引用 block，并保留 transform，不急于全量展开。
```

LWPOLYLINE bulge：

```text
theta = 4 * atan(bulge)
radius = chord / (2 * sin(theta / 2))
center = chord_mid + normal * center_offset
```

验收：

- LINE/ARC/CIRCLE/LWPOLYLINE 显示正确。
- 图层颜色和显隐生效。
- INSERT 的 transform 可验证。

### 4.9 2D DrawList 与 Core Graphics

流程：

```text
1. Drawing2DGeometry -> DrawingDrawList。
2. PathBuilder 将 line/arc/polyline/spline 转为 platform-neutral Path2D。
3. LayerDrawList 按 layer 分组。
4. SpatialIndex 支持 viewport query。
5. macOS adapter 将 Path2D 转为 CGPath。
6. 按 layer/style 绘制。
```

验收：

- zoom/pan 不改变线型语义。
- 大图纸只绘制 viewport 相关实体。
- 文字高度按图纸单位转换为屏幕显示。

### 4.10 测量与标注算法

3D 测量：

```text
1. 通过 BVH picking 获取点/边/面命中。
2. 点点距离：world distance。
3. 点面距离：project onto plane。
4. 角度：两个 edge direction 或两个 face normal。
5. 显示时使用 LSM units。
```

2D 测量：

```text
1. screen point -> world point。
2. snap 到最近 entity endpoint/midpoint/center/intersection。
3. distance/angle/area 使用 drawing units。
```

标注：

- annotation 保存在独立模型，不修改源 geometry。
- annotation 绑定 `NodeId`、`EntityId` 或 world/drawing coordinate。
- 导出时 annotation 作为 overlay 渲染。

---

## 5. 目标交回检查协议

给 MiMo 执行目标时，必须要求它在完成后把报告写入仓库内的固定目录，方便 Codex 后续检查。

报告目录：

```text
docs/progress/
```

报告命名：

```text
docs/progress/YYYY-MM-DD-target-name.md
```

示例：

```text
docs/progress/2026-06-29-repository-foundation.md
docs/progress/2026-06-29-lsm-runtime-model.md
```

规则：

- 每个目标完成后必须新增一份报告。
- 不覆盖旧报告。
- 报告必须写真实命令输出摘要，不写“已通过”但不说明命令。
- 如果没有运行某项检查，必须说明原因。
- 如果修改了计划外文件，必须在报告中单独列出。
- 如果触碰 `testfile/` 或引入样例文件，必须说明来源、用途和许可证状态。

报告必须包含以下内容：

```text
1. 完成摘要
2. 修改文件清单
3. 架构决策
4. 关键算法说明
5. 已运行命令和结果
6. 未运行检查及原因
7. 已知问题
8. 下一目标建议
9. 需要 Codex 重点 review 的文件/函数
```

检查标准：

- 是否遵守模块边界。
- 是否有不必要的平台耦合。
- 是否有 unsafe 扩散。
- 是否有 panic/unwrap 进入解析不可信文件路径。
- 是否有测试覆盖核心算法。
- 是否符合 macOS HIG。
- 是否留下可运行、可验证的状态。

---

## 6. Phase 0：仓库与工程基础

**目标：建立可持续开发的仓库、规范、工程骨架。**

### 架构说明

Phase 0 不实现业务算法，只建立让后续目标可持续落地的工程骨架。Rust workspace 是核心，macOS 工程是第一个平台壳。所有 crate 先给出最小可编译 public API，避免后续目标直接把代码塞进单一 crate。

推荐目录：

```text
crates/
  mmforge-core/
  mmforge-geometry/
  mmforge-render/
  mmforge-cli/
macos/
  MMForge/
docs/
  adr/
examples/
tests/
  fixtures/
```

### 执行算法

```text
1. 创建 Cargo workspace。
2. 每个 crate 创建最小 lib.rs 和 README。
3. mmforge-core 定义 Version、Result、Error 占位。
4. mmforge-cli 接入 clap，只实现 --version。
5. macOS 创建空 SwiftUI document-style shell。
6. CI 运行 cargo fmt/test/clippy。
7. 加 docs/adr/README.md，后续重大决策写 ADR。
```

### 交回检查重点

- workspace 是否能独立编译。
- crate 命名和依赖方向是否正确。
- macOS 工程是否没有把 Rust 构建写死到个人路径。
- `testfile/` 这类本地样例是否没有误提交，除非明确作为 fixture 并说明许可证。

### 范围

- Rust workspace
- macOS Xcode/SPM 工程骨架
- GitHub Actions 基础 CI
- 文档、许可证、贡献指南、安全策略
- 代码格式化、静态检查、测试入口

### 交付物

- `Cargo.toml` workspace
- `crates/mmforge-core`
- `crates/mmforge-geometry`
- `crates/mmforge-render`
- `crates/mmforge-cli`
- `macos/` 原生工程骨架
- `.github/workflows/ci.yml`
- `CONTRIBUTING.md`、`SECURITY.md`、`OPEN_SOURCE.md`

### 验收标准

- `cargo test --workspace` 可运行。
- `cargo fmt --check` 和 `cargo clippy --workspace` 可运行。
- macOS 空应用可在 Xcode 打开并启动。
- README 能指导新贡献者理解项目结构和开发入口。

---

## 7. Phase 1：macOS 3D 主链路

**目标：macOS 原生应用能打开 STEP 文件，解析为 LSM 运行时模型，生成渲染数据，并用 Metal 显示可交互 3D 模型。**

### 1. Rust 核心与 LSM 运行时模型

架构说明：

- `mmforge-core` 是最底层 crate。
- LSM runtime model 先服务内存工作流，不做稳定文件格式。
- 所有 parser 输出 `ParseOutput`。
- 所有 geometry/render module 只能依赖 core，不能反向依赖平台。

核心数据结构：

```rust
pub struct LsmModel {
    pub header: ModelHeader,
    pub scene: SceneTree,
    pub geometries: Vec<Geometry>,
    pub materials: Vec<Material>,
    pub metadata: Metadata,
}
```

算法：

```text
1. 定义 typed ids。
2. 定义 scene tree flat storage。
3. 定义 Geometry enum：BRepHandleRef / Mesh / Drawing2D。
4. 定义 stats traversal。
5. 定义 validate_references。
6. 为 model builder 写单元测试。
```

范围：

- `LsmModel`
- scene tree
- geometry id / node id
- materials
- metadata
- bounding boxes
- error model

交付物：

- `mmforge-core`
- `FormatParser` trait
- LSM runtime model docs
- 单元测试

验收标准：

- 能构造包含 scene tree、mesh、material、metadata 的模型。
- 能进行基础统计：节点数、mesh 数、三角形数、包围盒。
- 不承诺稳定 `.lsm` 文件格式。

### 2. OCCT 集成与 STEP 解析

架构说明：

- `mmforge-format-step` 只依赖 `mmforge-core` 和 `mmforge-geometry`。
- OCCT 细节隐藏在 `mmforge-geometry::occt`。
- STEP parser 不直接 tessellate；tessellation 在 render/geometry 目标里做。

算法见本文 4.2。

范围：

- OCCT 构建/链接
- STEPControl_Reader 包装
- TopoDS_Shape 安全句柄
- STEP AP203/AP214 基础支持
- 后续评估 AP242 与 XDE

交付物：

- `mmforge-geometry`
- `mmforge-format-step`
- STEP fixture：box、cylinder、assembly、curved surface
- 错误和 warning 收集

验收标准：

- 能读取基础 STEP 文件。
- 能输出结构树、包围盒、基础几何统计。
- 解析失败不会 panic，返回明确错误。
- OCCT unsafe 代码集中在 FFI adapter 内部。

### 3. Tessellation 与 RenderPacket

架构说明：

- tessellation adapter 可以在 `mmforge-geometry`，RenderPacket builder 在 `mmforge-render`。
- macOS Metal adapter 不参与 RenderPacket 生成。

算法见本文 4.3 和 4.4。

范围：

- B-Rep tessellation
- mesh packing
- normals
- materials
- bounds
- RenderPacket

交付物：

- `mmforge-render`
- tessellation options
- render stats
- golden fixture 输出

验收标准：

- STEP B-Rep 能转换为三角网格。
- RenderPacket 与平台无关。
- 同一 fixture 的三角形数和包围盒可回归测试。

### 4. macOS SwiftUI 壳与 Apple HIG 基础

架构说明：

- SwiftUI 管整体结构，必要时用 AppKit bridge 补菜单、文件面板、MTKView。
- 渲染视图是一个 isolated view，不把业务状态散落在 SwiftUI view 中。
- `AppState` 只做 UI 状态编排，模型生命周期交给 `DocumentModel` / `RustBridge`。

推荐结构：

```text
macos/MMForge/App
macos/MMForge/Views
macos/MMForge/Document
macos/MMForge/Metal
macos/MMForge/RustBridge
macos/MMForge/DesignSystem
```

Apple HIG 算法化检查：

```text
1. 每个 toolbar item 必须有 label、system image、help。
2. 每个 destructive command 必须有 confirm 或 undo。
3. 每个 long task 必须有 progress + cancel。
4. 每个 sidebar/inspector section 必须有明确标题。
5. 每个 command 至少从 menu 或 toolbar 一处可达。
```

范围：

- document window
- menu bar
- toolbar
- sidebar
- inspector
- status bar
- recent files
- drag and drop open

交付物：

- `macos/MMForge`
- SwiftUI app shell
- AppKit bridge where needed
- empty-state view
- HIG checklist

验收标准：

- 窗口、菜单、工具栏符合 macOS 文档型应用习惯。
- 支持 `Cmd+O` 打开文件。
- 支持最近文件。
- 支持 Dark Mode。
- VoiceOver 能读出主要控件名称。

### 5. Metal 3D Viewer

架构说明：

- Swift 层 `MetalRenderer` 只消费 `RenderPacketDTO`。
- Rust FFI 先允许复制数据到 Swift/Metal buffer，后续再优化 zero-copy。
- 每帧只更新 camera/material uniforms，避免重建 mesh buffer。

算法见本文 4.5 和 4.6。

范围：

- `MTKView`
- Metal pipeline
- depth buffer
- camera uniforms
- mesh upload
- solid render mode
- basic lighting

交付物：

- Metal renderer
- shader library
- camera model
- screenshot fixtures

验收标准：

- 可以渲染来自 STEP 的三角网格。
- 支持 orbit、pan、zoom、fit to view。
- 简单模型稳定 60 fps。
- 渲染视图 resize 不崩溃、不拉伸。

---

## 8. Phase 2：macOS 3D 完整查看能力

**目标：把 macOS 3D 查看器从“能显示”推进到“可用的工业查看器”。**

### 功能范围

- 产品结构树浏览
- 节点/零件选择
- 部件显隐
- 图层/颜色 override
- render modes：solid、wireframe、solid+wireframe、transparent
- 剖切面
- 截面填充
- 模型信息面板
- 选择高亮
- screenshot / image export
- preferences

### 架构与算法

选择与高亮：

```text
1. mouseDown 获取 screen point。
2. camera screen_to_ray。
3. BVH ray query。
4. hit -> SelectionState。
5. SelectionState 同步 sidebar 和 inspector。
6. Metal selection pass 或 material override 绘制高亮。
```

部件显隐：

```text
1. SceneNode.visible 作为源状态。
2. RenderPacketBuilder 读取 visible。
3. 隐藏节点只更新 instance visibility 或 batch，不重新 parse。
```

剖切面：

```text
1. UI 保存 ClipPlane { normal, distance, enabled }。
2. 渲染 pass 将 clip plane 写入 fragment uniform。
3. shader discard clipped fragments。
4. 截面填充后续通过 mesh-plane intersection 生成 cap geometry。
```

线框：

- 第一阶段可以生成 edge list overlay。
- 后续可用 barycentric wireframe 或后处理边缘检测。
- CAD 默认需要 `solid+edge` 工程风格，不只 PBR。

### 交付物

- structure sidebar
- inspector
- render mode toolbar
- clipping tool
- selection manager
- BVH picking
- export image command

### 验收标准

- 选择树节点能高亮对应模型部分。
- 隐藏/显示部件不重建整个模型。
- 剖切面可拖动、可开关。
- 线框和透明模式视觉稳定。
- 所有工具栏按钮有 tooltip、菜单项和快捷键。
- 符合 Apple toolbar、sidebar、inspector 交互习惯。

---

## 9. Phase 3：macOS 多格式 3D

**目标：扩展 3D 格式覆盖，让同一套 LSM/RenderPacket 支持 B-Rep 与 mesh 源格式。**

### 格式范围

| 格式 | 解析路线 | 目标能力 |
|------|----------|----------|
| glTF / GLB | gltf-rs | mesh、scene tree、PBR material、texture |
| STL | custom | binary/ascii mesh |
| IGES | OCCT | B-Rep 基础查看 |
| OBJ | custom 或第三方库评估 | mesh、material 基础支持 |
| STEP AP242 | OCCT/XDE 评估 | 产品结构、颜色、PMI 后续能力 |

### 架构与算法

glTF：

```text
1. gltf-rs 解析 JSON/glB。
2. buffer/accessor -> MeshGeometry。
3. node tree -> SceneTree。
4. material pbrMetallicRoughness -> Material。
5. texture 先记录 metadata，Metal texture upload 后续目标实现。
```

STL：

```text
1. 判断 binary/ascii。
2. binary 用 length 校验：84 + triangle_count * 50 == file_size。
3. 读取 triangle normal 和 vertices。
4. 可选顶点去重，必须保留 flat normal 模式。
```

IGES：

- 复用 OCCT adapter。
- 输出 B-Rep 后走同一 tessellation/RenderPacket。

OBJ：

- 先支持 v/vn/vt/f 和 mtllib 基础。
- triangulate polygon faces。
- material 不完整时 warning。

### 验收标准

- 每个格式至少有 3 个合法 fixture 和 3 个错误 fixture。
- 所有格式统一进入 LSM runtime model。
- glTF 材质能映射到 Metal renderer。
- STL 大文件不会阻塞 UI，显示进度。
- 文件不支持或部分支持时给出清晰 warning。

---

## 10. Phase 4：macOS 原生 2D 图纸

**目标：支持 DXF/DWG/SVG/PDF 等 2D 图纸查看，优先 DXF。**

### 功能范围

- DXF tokenizer / section parser / entity parser
- LINE / ARC / CIRCLE / LWPOLYLINE / TEXT
- BLOCK / INSERT
- layer table
- line types
- Core Graphics 2D renderer
- zoom / pan / fit
- layer panel

### 架构与算法

DXF 算法见本文 4.8。

DrawList 算法见本文 4.9。

macOS 2D adapter：

```text
1. DrawingView 接收 DrawingDrawList。
2. ViewportState 保存 pan/zoom。
3. 每次 redraw 计算 visible world rect。
4. SpatialIndex query visible commands。
5. Core Graphics 绘制 visible commands。
6. overlay pass 绘制 selection/measurement/annotation。
```

### 后续扩展

- MTEXT
- DIMENSION
- HATCH
- SPLINE
- PDF export
- DWG optional LibreDWG module
- SVG import/export
- PDF 2D import evaluation

### 验收标准

- DXF 基础图纸可正确显示。
- 图层开关即时生效。
- 图纸坐标、单位、包围盒正确。
- 大图纸使用空间索引裁剪绘制。
- LibreDWG 相关模块保持可选隔离，不进入默认核心依赖。

---

## 11. Phase 5：测量、标注、导出

**目标：补齐工业查看器的日常使用工作流。**

### 功能范围

- 3D 距离测量
- 2D 距离、角度、面积测量
- point / edge / face picking
- annotation model
- text / arrow / dimension annotation
- screenshot export
- image export
- PDF export
- annotation persistence design

### 架构与算法

测量算法见本文 4.10。

导出：

```text
image export:
  render current viewport into offscreen texture or bitmap
  composite annotation overlay
  write png/jpeg

PDF export:
  2D drawing 使用 Core Graphics PDF context
  3D current view 作为 raster snapshot
  annotation overlay 保持矢量优先
```

### 验收标准

- 测量结果使用源文件单位，并显示精度。
- 标注绑定模型节点或图纸坐标。
- 导出图像与当前视图一致。
- PDF 导出保留页面尺寸和基础图层语义。

---

## 12. Phase 6：性能、大模型与稳定性

**目标：让大型工业模型可用、可诊断、可回归。**

### 功能范围

- background parsing
- progress and cancellation
- memory budget
- RenderPacket streaming
- LOD
- instancing
- frustum culling
- occlusion strategy
- crash-safe parser boundaries
- fuzzing
- benchmark corpus

### 架构与算法

后台任务：

```text
1. UI 发起 OpenDocumentJob。
2. job 在线程池执行 detect/parse/tessellate/build packet。
3. progress callback 上报 stage/current/total。
4. cancellation token 在 parser/tessellation 循环检查。
5. 完成后主线程 publish DocumentModel。
```

大模型策略：

- 首屏 preview quality tessellation。
- 后台补 standard/high quality。
- RenderPacket 分 chunk，按 scene node 或 spatial cluster。
- GPU buffer 复用，避免重复上传未变化 mesh。

稳定性：

- parser fixture tests。
- fuzz targets：STEP header/entity parser、DXF tokenizer、STL binary reader。
- unsafe audit doc。

### 验收标准

- UI 不被解析任务阻塞。
- 解析和 tessellation 可取消。
- 大模型有进度、内存、三角形数统计。
- parser fuzzing 可在 CI 或 nightly workflow 中运行。
- 所有 unsafe FFI 都有集中审计点。

---

## 13. Phase 7：LSM 持久化与 CLI 完整化

**目标：在运行时模型稳定后冻结 `.lsm` 文件格式，并完善批处理能力。**

### 功能范围

- `.lsm` binary format v1
- `.lsmc` compressed format
- forward-compatible sections
- CLI info / validate / convert / benchmark
- batch conversion
- schema versioning
- compatibility tests

### 架构与算法

LSM 文件冻结流程：

```text
1. 列出 runtime model 已稳定字段。
2. 为每个 section 定义 binary layout。
3. 写 versioned reader/writer。
4. reader 必须跳过未知 section。
5. writer 必须写 schema version 和 feature flags。
6. 建立 golden files。
7. 任何 breaking change 需要 migration 或 major version。
```

CLI：

```text
info:
  detect -> parse metadata/structure -> print stats

validate:
  parse -> validate references/topology warnings -> exit code

convert:
  source -> LSM runtime -> target writer

benchmark:
  measure parse/tessellate/render-packet timings
```

### 验收标准

- `.lsm` 文件可跨版本读取。
- 未知 section 可跳过。
- CLI 输出支持 text 和 JSON。
- CLI 适合 CI 批处理。
- 文件格式冻结前所有 breaking change 记录到 changelog。

---

## 14. Phase 8：iOS / iPadOS

**目标：复用 macOS 的 Apple 平台能力，交付移动端和 iPad 查看体验。**

### 功能范围

- SwiftUI shared views
- UIKit interop for Metal view where needed
- touch gestures
- share sheet
- Files app integration
- memory constrained render mode
- optional server-side conversion strategy

### 验收标准

- iPad 支持大屏 split view 和 pointer。
- iOS 支持打开本地文件和分享导入。
- Metal renderer 复用核心 shader/RenderPacket。
- 内存过高时有降级策略。

---

## 15. Phase 9：Windows

**目标：将完整查看能力移植到 Windows 桌面。**

### 功能范围

- WinUI 3 app shell
- Direct3D 12 renderer
- Direct2D 2D renderer
- Rust C ABI bridge
- Windows file associations
- DPI scaling

### 验收标准

- 同一 fixture 与 macOS 渲染结果保持可接受一致性。
- 支持鼠标、键盘、触控板基础交互。
- 高 DPI 下 UI 和图纸线宽正确。

---

## 16. Phase 10：Android

**目标：交付 Android 原生查看器。**

### 功能范围

- Jetpack Compose UI
- Vulkan renderer
- OpenGL ES fallback
- JNI / C ABI bridge
- Android file picker
- mobile performance profile

### 验收标准

- 中等模型可流畅查看。
- 低端设备 fallback 可用。
- 解析任务不阻塞主线程。

---

## 17. Phase 11：OpenHarmony 与 Web 评估

**目标：扩展平台生态，但不影响核心架构。**

### OpenHarmony

- ArkUI shell
- OpenGL ES or platform graphics API
- NAPI bridge
- file picker and share integration

### Web 评估

- WASM build feasibility
- OCCT wasm size and performance
- WebGPU renderer feasibility
- server-side conversion option

---

## 18. 横向工作流

这些工作不属于单一阶段，需要持续推进：

- 测试语料库：合法、损坏、超大、边界文件。
- 性能基准：解析时间、tessellation 时间、GPU 时间、内存峰值。
- 安全：fuzzing、FFI 审计、崩溃样本回归。
- 合规：第三方依赖许可证、示例文件授权、GPL 可选隔离。
- 文档：每个 crate 和平台模块有 README、设计说明和验收记录。
- 发布：版本号、changelog、release artifacts、签名、公证。

---

## 19. macOS HIG 验收清单

每个 macOS 目标完成前，必须检查：

- [ ] 菜单栏命令完整，常用命令有快捷键。
- [ ] Toolbar 使用系统风格图标、label、tooltip。
- [ ] Sidebar 用于文件、结构树、图层等导航信息。
- [ ] Inspector 用于当前选择对象属性和工具参数。
- [ ] 支持多窗口或明确记录不支持原因。
- [ ] 支持系统 Dark Mode。
- [ ] 支持键盘导航和 VoiceOver 基础标签。
- [ ] 文件打开、拖放、最近文件符合 macOS 习惯。
- [ ] 破坏性操作有确认或撤销路径。
- [ ] 长任务显示进度并支持取消。

---

## 20. 推荐目标模式启动顺序

1. 创建 Rust workspace 与 macOS 空应用。
2. 实现 LSM runtime model 最小核心。
3. 集成 OCCT 并读取 `simple_box.step`。
4. 生成 tessellated mesh 和 RenderPacket。
5. 在 macOS Metal 视图显示模型。
6. 加 orbit / pan / zoom / fit。
7. 加 structure sidebar 和 inspector。
8. 加 selection / highlight / visibility。
9. 加 render modes 和 clipping。
10. 扩 glTF / STL / IGES。
11. 做 DXF 和原生 2D 图纸。
12. 做测量、标注、导出。

这 12 个目标全部完成后，macOS 版本就具备完整产品主干，再进入 iOS 和其它平台迁移。
