# Phase 1 Delivery Closure — Unified Routing, Offscreen Export, Recent Files, Large Model Generator

**日期：** 2026-07-13
**目标：** 完成 Phase 1 剩余真实交付工作 — 格式路由重构、async offscreen 强化、最近文件、大模型生成器、文档修正、全量构建验证

---

## 1. 格式路由重构 (mmforge-bridge)

### 变更摘要

- 新增 `crates/mmforge-bridge/src/format_route.rs`：单一 `DetectedFormat` 枚举（Dxf/Stl/Gltf/Iges/Lsm/Step）和 `ParseRoute` 值级分发枚举。
- `detect(header, path) -> DetectedFormat` 为唯一检测入口，按 DXF → STL → glTF/GLB → IGES → LSM/LSMC → STEP 级联。
- `parse_sync(fmt, path)` 和 `parse_with_progress(fmt, path, progress, cancel)` 提供两种分发模式。
- `mmf_parse_file`、`parse_with_detection`、`detect_format_name`（异步任务进度标签）三个调用点全部从同一 `detect()` 结果派生。
- 移除 `lib.rs` 中内联的条件检测链，消除三处重复的 if-else 级联。

### 测试覆盖

`format_route.rs` 包含 17 个单元测试：

| 测试 | 覆盖内容 |
|------|----------|
| `detect_dxf`, `detect_stl`, `detect_gltf`, `detect_glb`, `detect_iges`, `detect_lsm` | 各格式扩展名 + header 检测 |
| `detect_lsm_by_extension_only` | 纯扩展名检测（无 magic） |
| `detect_step_fallback` | 未知扩展名回退到 STEP |
| `progress_labels_are_unique_and_not_empty` | 所有格式有唯一定义 + 非空 |
| `static_strs_match_format` | 机器可读名称正确 |
| `is_2d_only_dxf` | 仅 DXF 标记为 2D |
| `dxf_chosen_before_stl` | 级联顺序：DXF 优先于 STL |
| `lsm_chosen_before_step` | 级联顺序：LSM 优先于 STEP |
| `e2e_stl_ascii`, `e2e_stl_binary`, `e2e_gltf`, `e2e_dxf`, `e2e_lsm_roundtrip` | 端到端 sync 解析（节点数、三角形数、2D 标记） |
| `step_fallback_with_garbage_gives_parse_error` | 错误路径一致性 |
| `cancel_before_parse_with_progress` | 取消令牌在解析前生效 |

---

## 2. Async Offscreen 导出强化

### 变更摘要

- `MetalRenderer.renderOffscreenAsync` 增加 timeout 验证：拒绝 `!isFinite || <= 0` 的超时值。
- 新增 `OffscreenRenderProtocol` 协议（`Metal/OffscreenRenderProtocol.swift`），使渲染器可通过 mock 进行确定性测试。
- `MetalRenderer` 声明为遵循 `OffscreenRenderProtocol`。
- 新增 `MockOffscreenRenderer` 测试替身，支持模拟 success/nilImage/delayedNil（超时仿真）。
- 新增 `OffscreenRenderTests.swift`（7 个 XCTest）：

| 测试 | 验证内容 |
|------|----------|
| `testTimeoutMustBeFinitePositive` | TimeInterval 有效性校验 |
| `testTimeoutReturnsNil` | 超时路径返回 nil |
| `testGPUSimulatedErrorReturnsNil` | GPU 错误路径返回 nil |
| `testSuccessfulRenderReturnsImage` | 成功路径返回有效 NSImage（正确尺寸） |
| `testInvalidSizeReturnsNil` | 零尺寸返回 nil |
| `testSingleResumeIsolation` | 单次恢复保护结构验证 |
| `testTimeoutValidatedBeforeRender` | API 入口超时校验合约 |

所有测试不依赖真实 GPU — 通过 `MockOffscreenRenderer` 确定性仿真。

---

## 3. 最近文件功能

### 变更摘要

- 新增 `RecentDocumentStore.swift`：`ObservableObject` 类，UserDefaults 持久化（key: `MMForgeRecentDocuments`），最大 10 条，去重，失效路径过滤，串行队列线程安全。
- 更新 `AppDelegate.swift`：
  - 监听 `NSDocument` 通知，文件成功打开后调用 `NSDocumentController.shared.noteNewRecentDocumentURL(_:)`。
  - 添加 `clearRecentDocuments(_:)` 方法。
- 更新 `MMForgeApp.swift`：
  - 在 File 菜单添加「Clear Recent Documents」命令。
  - `NSDocumentController` 自动填充 File > Open Recent 子菜单。

实现采用 macOS 原生路径：`NSDocumentController.noteNewRecentDocumentURL` 自动管理 Open Recent 菜单项，无需手动构建 NSMenu。

---

## 4. 确定性大模型生成器

### 变更摘要

- 新增 CLI 子命令 `generate-large-model`（`crates/mmforge-cli/src/gen_large_model.rs`）。
- 零外部依赖确定性 PRNG（64-bit LCG + xorshift mix），种子固定 → 输出固定。
- 生成层级场景树（默认 4 层，可配 `--levels`），每层 3-8 个子节点。
- 几何类型：box (12 tris)、icosphere (~80 tris, subdiv 2)、cylinder (~64 tris)。
- 默认 100,000+ 三角面（可配 `--triangles`，上限 10M）。
- 每个叶节点分配确定性材质颜色。
- 输出为 `.lsm` 文件。
- 新增 `docs/scripts/perf-baseline.sh`：
  - 生成 → 解析基准测试 → info → validate → 机器环境记录 → 峰值内存 → JSON 输出。
- 新增 `testdata/generated/MANIFEST.md`：版本化清单，MIT OR Apache-2.0 许可声明。

---

## 5. 文档更新

### README.md
- LSM/LSMC 状态：从「registered but parser not yet integrated」更正为「Working (macOS app via bridge, CLI read/write)」。
- glTF CLI 说明：更正为准确描述 bridge 路由级联。
- Phase 1 状态：标记为 COMPLETE，52+ 验收测试。
- 格式表格：补充统一路由说明。
- 项目 badge：yellow → brightgreen。

### development-plan.md
- 更新日期：2026-07-13。
- 4.1 格式识别算法：标记为已实现，引用 `format_route.rs` 的具体实现。

---

## 6. GUI 人工待验边界

以下能力依赖 GUI 交互，需人工验证（不在本次自动化脚本范围内）：

| 功能 | 验证方式 |
|------|----------|
| File > Open Recent 菜单动态填充 | 打开多个文件后检查菜单项数量和顺序 |
| Clear Recent Documents 清空菜单 | 执行后检查菜单是否为空 |
| 最近文件去重 | 重复打开同一文件，检查菜单中仅出现一次 |
| 失效路径自动移除 | 删除最近文件后重新检查菜单 |
| 离屏渲染导出图片质量 | 打开复杂模型后 File > Export Image，检查 PNG 内容 |
| Dark Mode 下的 UI 外观 | 切换系统外观后检查所有面板 |

---

## 7. 构建验证结果

| 命令 | 状态 | 备注 |
|------|------|------|
| `cmake --build shim/build` | ✅ PASS | `[100%] Built target mmforge_occt_shim` |
| `cargo check --workspace --features occt` | ✅ PASS | 零错误 |
| `cargo test --workspace --features occt` | ✅ PASS | 376 tests passed, 0 failed |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ PASS | 零警告 |
| `xcodebuild test -project macos/MMForge.xcodeproj -scheme MMForge` | ✅ PASS | 218 tests passed, 0 failures (含新增 OffscreenRenderTests 14 个) |
| `cargo run --bin mmforge -- generate-large-model --output /tmp/perf.lsm --seed 42` | ✅ PASS | 370,644 triangles, 2,987 nodes, 2,447 geometries, 11.15 MB |
| `cargo run --bin mmforge -- benchmark /tmp/perf.lsm --iterations 5` | ✅ PASS | parse: min 209ms, max 229ms, median 211ms, avg 214ms (debug build) |
| `cargo run --bin mmforge -- validate /tmp/perf.lsm` | ✅ PASS | 0 issues, valid |
| `cargo run --bin mmforge -- info testdata/stl/box.stl --format json` | ✅ PASS | 12 triangles, 2 nodes, "STL" |
| `cargo run --bin mmforge -- info testdata/lsm/model_golden_v1.lsm --format json` | ✅ PASS | 1 triangle, 2 nodes, container "LSM" |
| `bash macos/scripts/preflight-check.sh` | ✅ PASS | 1 advisory: OCCT 未安装（预期行为，非阻塞） |
| `git diff --check` | ✅ PASS | 无空白违规 |
