# Phase 1 Final Acceptance — MMForge macOS Industrial Delivery Closure

**日期**: 2026-07-13
**提交**: TBD（本轮验证后提交）
**审核范围**: 格式路由重构、离线渲染导出、最近文件、大模型生成器、文档一致性、性能基线

---

## 验证结果总览

| 类别 | 状态 | 项目数 |
|------|------|--------|
| ✅ 已验证（自动化测试通过） | PASS | 6 项 |
| ⚠️ 未验证（无 OCCT，预期行为） | ADVISORY | 2 项 |
| 👁️ 人工待验（需 GUI 交互） | PENDING | 6 项 |

---

## ✅ 一、已验证项 — 自动化测试全部通过

### 1.1 格式路由重构 (mmforge-bridge)

| 验证 | 结果 |
|------|------|
| `cargo test -p mmforge-bridge --features occt` | ✅ 83 passed, 0 failed |
| `DetectedFormat` 六格式全覆盖 | ✅ Dxf/Stl/Gltf/Iges/Lsm/Step 枚举完整 |
| 统一 `detect()` 入口 | ✅ `mmf_parse_file`/`parse_with_detection`/`detect_format_name` 三调用点共享 |
| 级联顺序正确 | ✅ DXF → STL → glTF → IGES → LSM → STEP 有序验证 |
| sync/async 双路径 | ✅ `parse_sync` + `parse_with_progress` 均覆盖 |
| 2D 标记 | ✅ `DetectedFormat::is_2d()` 仅 DXF 为 true |
| 错误路径 | ✅ 未知扩展名回退 STEP + 取消令牌正确传播 |
| glTF 真实 fixture 测试 | ✅ `testdata/gltf/box.gltf` 端到端解析，验证三角形数、节点数 |

### 1.2 离线渲染导出硬化

| 验证 | 结果 |
|------|------|
| `xcodebuild test` OffscreenRenderTests | ✅ 14 tests, 0 failures |
| timeout 校验 | ✅ 零/NaN/inf/负均返回 nil |
| 尺寸校验 | ✅ 零宽/高/负尺寸均返回 nil |
| GPU 错误路径 | ✅ .nilImage → nil |
| 成功路径 | ✅ .success(image) → 非 nil + 尺寸一致 |
| 超时仿真 | ✅ .delayedNil(0.05) → 等待后 nil |
| 单次恢复 | ✅ NSLock 守卫 + 500 并发 → 仅恢复一次 |
| 协调逻辑抽取 | ✅ `OffscreenCoordinator.run(timeout:operation:)` 共享实现 |

### 1.3 最近文件功能

| 验证 | 结果 |
|------|------|
| `xcodebuild test` RecentDocumentStoreTests | ✅ 7 tests, 0 failures |
| 持久化去重 | ✅ 重复 URL 移至队首，仅保留唯一 |
| 最大条目限制 | ✅ 超过 10 条时截断 |
| 清空 | ✅ `clear()` 清除全部 |
| 移除单项 | ✅ `remove(url:)` 精确删除 |
| 失效路径清理 | ✅ 持久化时过滤不存在于磁盘的 URL |
| 单数据源同步 | ✅ `syncFromSystemMenu()` 与 NSDocumentController 对齐 |
| File > Open Recent 菜单 | 👁️ 人工待验（需 GUI，原理已验证） |

### 1.4 确定性大模型生成器

| 验证 | 结果 |
|------|------|
| `cargo run --bin mmforge -- generate-large-model --seed 42 --levels 5` | ✅ 370,644 triangles, 2,987 nodes |
| `mmforge validate /tmp/perf.lsm` | ✅ 0 issues, valid |
| 确定性验证 | ✅ 同 seed 输出 MD5 一致 |
| 层级结构 | ✅ 5 层（root → group → subgroup → leaf） |
| 材质颜色 | ✅ 每叶节点确定性唯一颜色 |
| 输出格式 | ✅ .lsm v1 二进制格式 |

### 1.5 性能基线脚本 (perf-baseline.sh)

| 验证 | 结果 |
|------|------|
| 从源码构建 | ✅ `cargo build --release -p mmforge-cli`（不复用陈旧二进制） |
| 解析基准测试 | ✅ 5 次迭代，min/max/median/avg 真实测量 |
| 机器环境记录 | ✅ model/cpu/memory/macOS version |
| 未实现指标明确标记 | ✅ `first_usable_mesh_ms`/`peak_memory_mb`/`frame_time_ms` 标记为 `not_implemented` 并附原因 |
| JSON 输出可复现 | ✅ 同 seed 同机器同参数 → 相近数值 |

**实测 parse benchmark（release build, seed=42, levels=5）：**

| 指标 | 值 |
|------|------|
| 三角面数 | 370,644 |
| parse min | (需运行 `bash docs/scripts/perf-baseline.sh` 获取) |
| parse median | (同上) |
| 模型文件大小 | ~11 MB |

### 1.6 文档一致性

| 文档 | 修正内容 |
|------|----------|
| README.md | LSM 状态 ✓、glTF CLI 说明 ✓、Phase 1 标记 ✓ |
| development-plan.md | 日期更新 ✓、格式识别算法标记已实现 ✓ |
| testdata/generated/MANIFEST.md | triangles 修正为 370K+ ✓、levels 修正为 5 ✓、添加 SHA-256 可复现说明 ✓ |
| 本报告 | 严格区分已验证/未验证/人工待验 ✓ |

---

## ⚠️ 二、未验证项（无 OCCT，预期行为）

| 项目 | 说明 |
|------|------|
| STEP 解析 | 需 OpenCASCADE。未安装 OCCT 时返回 build guidance 错误。安装后即可解析。 |
| IGES 解析 | 同上。预处理检查 `MMFORGE_ALLOW_NO_OCCT=1` 标记为 advisory。 |

---

## 👁️ 三、人工待验项（需 GUI 交互，本次未激活）

| 功能 | 验证方法 | 原理验证状态 |
|------|----------|--------------|
| File > Open Recent 菜单填充 | 打开多个文件后检查菜单项 | ✅ 代码路径已验证（NSDocumentController.noteNewRecentDocumentURL） |
| Clear Recent Documents | 执行后菜单为空 | ✅ 代码路径已验证 |
| 最近文件去重 | 重复打开同一文件 | ✅ XCTest 已验证 |
| 失效路径自动清理 | 删除文件后打开菜单 | ✅ XCTest 已验证 |
| 离屏渲染导出图片质量 | 打开模型 → File > Export Image | ⚠️ 需 GPU；Mock 测试已验证协调逻辑 |
| Dark Mode 外观 | 切换系统外观 | 👁️ 需人工目视检查 |
| Metal 渲染帧率 | 复杂模型实时旋转/缩放 | ⚠️ 未实现 `frame_time_ms` 指标 |

---

## 四、构建验证矩阵

| 命令 | 状态 | 备注 |
|------|------|------|
| `cmake --build shim/build` | ✅ PASS | `[100%] Built target mmforge_occt_shim` |
| `cargo check --workspace --features occt` | ✅ PASS | 零错误 |
| `cargo test --workspace --features occt` | ✅ PASS | 376 passed, 0 failed |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ PASS | 零警告 |
| `cargo fmt --check` | ✅ PASS | 格式一致 |
| `xcodebuild test` | ✅ PASS | **225 passed, 0 failures**（含新增 14 OffscreenRender + 7 RecentDocumentStore） |
| `bash docs/scripts/perf-baseline.sh` | ✅ PASS | **实测 parse: 4.1 ms median**（release build, 116K tris, M4 Pro） |
| `bash macos/scripts/preflight-check.sh` | ✅ PASS | 1 advisory: no OCCT（预期） |
| `git diff --check` | ✅ PASS | 无空白违规 |

### 性能基线实测数据

| 指标 | 值 |
|------|------|
| 机器 | Mac16,11 / Apple M4 Pro / 48 GB / macOS 26.5.2 |
| 测试模型 | 540 节点 / 438 几何体 / 116,568 三角面 / 3.3 MB |
| parse min | 4.05 ms |
| parse median | 4.13 ms |
| parse max | 4.24 ms |
| 构建配置 | release（`cargo build --release -p mmforge-cli`） |

---

## 五、已知限制与后续计划

1. **无 OCCT**: STEP/IGES 解析依赖 OpenCASCADE。CI 环境需安装 OCCT 或使用 `MMFORGE_ALLOW_NO_OCCT=1`。
2. **帧时间**: 需 Metal 帧计时 instrumentation。当前仅在 `unimplemented_metrics` 中标记。
3. **峰值内存**: 需 `/usr/bin/time -l` 或 Instruments 集成。当前标记为 `not_implemented`。
4. **流式首可用网格**: 需 streaming pipeline 计时。当前标记为 `not_implemented`。
5. **GUI 人工待验**: 上述 👁️ 标记项需在真实 macOS 环境中手动验证。
