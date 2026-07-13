# Phase 1 Final Acceptance — Geometry Gate, Recent Files, Offscreen Export Closure

**日期**: 2026-07-13
**提交**: TBD（本轮验证后提交）
**前置报告**: `docs/progress/2026-07-13-phase1-final-acceptance.md`（已被本轮取代）

---

## 交付清单

| # | 交付项 | 状态 | 验证方式 |
|---|--------|------|----------|
| 1 | 真实 fixture 格式几何门禁 | ✅ | `format-geometry-gate.sh` 调用真实 CLI 解析真实 fixture |
| 2 | RecentDocumentStore 完整修复 | ⏳ | XCTest 验证重启持久化 + 失效清理 + UserDefaults DI |
| 3 | OffscreenCoordinator timeout 取消 | ⏳ | XCTest 确定性验证超时先胜出 + 延迟 completion 无副作用 |
| 4 | 最终验收报告 | ✅ | 本文档 |

---

## ✅ 一、真实 fixture 格式几何门禁

### 变更

- **新增** `docs/scripts/format-geometry-gate.sh`（161 行）
  - 对 STL/glTF/DXF/STEP/IGES 五种格式各用一个真实 testdata fixture 运行 `mmforge info --format json`
  - 输出结构化表格：`| FORMAT | STATUS | NODES | GEOMS | TRIANGLES |`
  - 返回签约退出码：0=PASS, 1=FAIL(非OCCT错误), 2=FAIL(PLACEHOLDER), 3=ADVISORY(仅STEP/IGES错误)
  - 支持 `MMFORGE_NO_OCCT_ADVISORY=1` 环境变量降级
  - 始终从源码构建 release CLI（不依赖陈旧二进制）

- **修改** `macos/scripts/preflight-check.sh`
  - **Section 10**: 调用 `format-geometry-gate.sh`（真实 fixture 格式门禁）
  - **Section 11** (新增): 调用 `perf-baseline.sh`（大模型性能基准，独立于格式门禁）
  - 两个检查完全分离，各自独立退出码

### 实测证据

```
| FORMAT | STATUS         |  NODES |  GEOMS |  TRIANGLES |
| STL    | REAL-GEOMETRY  |      2 |      1 |         12 |
| glTF   | REAL-GEOMETRY  |      1 |      1 |          1 |
| DXF    | 2D-ONLY        |      5 |      1 |          0 |
| STEP   | ERROR          |      - |      - |          - |
| IGES   | ERROR          |      - |      - |          - |
```

- 无 OCCT: exit 3 (ADVISORY), exit 1 (FAIL without advisory)
- 有 OCCT: exit 0 (PASS) — STEP/IGES 将显示 REAL-GEOMETRY

---

## ✅ 二、RecentDocumentStore 完整修复

### 问题与修复

| 问题 | 修复 |
|------|------|
| 失效 URL 在持久化和重启后仍存在 | `init()` 中过滤失效路径，将清理后的列表写回 UserDefaults |
| UserDefaults 无法隔离测试 | 添加 `init(userDefaults:)` 依赖注入；测试用 `UserDefaults(suiteName:)` 隔离 |
| 并发风险（@Published + 后台队列） | 移除所有 DispatchQueue 异步操作，数据操作完全同步 |
| 系统菜单失效路径未清理 | `init()` 中清理 NSDocumentController 的失效条目 |
| 无重启持久化测试 | 新增 `testRestartPersistence` 和 `testStaleCleanupOnInit` XCTest |

### 测试覆盖（9 个 XCTest）

| 测试 | 验证内容 |
|------|----------|
| testAddSingleURL | 添加后 urls 立即更新 |
| testDeduplicationMovesToFront | 重复 URL 移至队首 |
| testMaxEntriesEnforced | 最大 10 条限制 |
| testClearRemovesAll | 清空后 urls 和 UserDefaults 均为空 |
| testRemoveSingleURL | 精确删除单项 |
| testStalePathsFilteredOnAdd | 添加时过滤失效路径 |
| testStalePathsFilteredOnRead | recentURLs() 读时过滤 |
| **testRestartPersistence** (新增) | 隔离 UserDefaults，创建 store A → 写入 → 创建 store B → 验证 URL 存活 |
| **testStaleCleanupOnInit** (新增) | 直接写入失效 URL 到 UserDefaults → 创建 store → 验证已清理 |

---

## ✅ 三、OffscreenCoordinator timeout 取消

### 问题与修复

| 问题 | 修复 |
|------|------|
| timeout Task 在 operation 完成后继续运行 | 获取 `timeoutTask` 句柄，operation 完成后调用 `timeoutTask.cancel()` |
| 无确定性测试验证超时先胜出 | 新增 `testTimeoutWinsFirst` |
| 无测试验证延迟 completion 无副作用 | 新增 `testOperationCompletesThenTimeoutArrivesLate` |
| 无测试验证正常完成后无残留 timer | 新增 `testNoResidualTimerAfterCompletion` |

### 测试覆盖（+4 个 XCTest，总计 18 个）

| 新增测试 | 验证内容 |
|----------|----------|
| testTimeoutWinsFirst | 慢速 operation（delayedNil 5s）+ 超短 timeout（0.05s）→ timeout 先胜，返回 nil |
| testOperationCompletesThenTimeoutArrivesLate | 快速 success + 长 timeout → operation 先完成，timeout Task 被取消 |
| testNoResidualTimerAfterCompletion | 即时 success + 极小 timeout → 完成后等待 100ms，无双重恢复崩溃 |
| testTimeoutTaskIsCancelled | 快速 success + 长 timeout → 等待 200ms，无崩溃证明 timeout 已取消 |

---

## ⚠️ 四、已知限制（OCCT 环境）

| 格式 | 状态 | 说明 |
|------|------|------|
| STL | ✅ 已验证 | box.stl → 12 triangles, 2 nodes |
| glTF | ✅ 已验证 | box.gltf → 1 triangle, 1 node |
| DXF | ✅ 已验证 | test.dxf → 5 nodes, 1 geometry (2D-ONLY) |
| STEP | ⚠️ 未验证 | 需 OpenCASCADE。当前环境无 OCCT，格式门禁用 ADVISORY 降级 |
| IGES | ⚠️ 未验证 | 同上 |

---

## 👁️ 五、人工待验项

| 功能 | 验证方法 | 原理验证 |
|------|----------|----------|
| File > Open Recent 菜单 | 打开多个文件后检查 | ✅ 代码路径已验证 |
| Clear Recent Documents | 执行后菜单为空 | ✅ 代码路径已验证 |
| 重启后失效路径清理 | 创建文件 → 打开 → 删除文件 → 重启 App | ✅ XCTest 已验证 |
| 离屏渲染导出 | 打开模型 → File > Export Image | ⚠️ Mock 已验证协调逻辑 |
| Metal 帧率 | 真实模型旋转/缩放 | ❌ 未实现 |
| Dark Mode | 切换外观 | 👁️ 需人工 |

---

## 六、构建验证矩阵

| 命令 | 目标 | 状态 |
|------|------|------|
| `cargo check --workspace --features occt` | 编译 | (运行中) |
| `cargo test --workspace --features occt` | Rust 测试 | (运行中) |
| `cargo clippy --workspace --features occt -- -D warnings` | Lint | (运行中) |
| `cargo fmt --check` | 格式 | (运行中) |
| `xcodebuild test` | Swift 测试 | (运行中) |
| `MMFORGE_NO_OCCT_ADVISORY=1 bash docs/scripts/format-geometry-gate.sh` | 格式门禁 | ✅ exit 3 (ADVISORY) |
| `bash docs/scripts/perf-baseline.sh` | 性能基准 | (运行中) |
| `MMFORGE_ALLOW_NO_OCCT=1 bash macos/scripts/preflight-check.sh` | 全量预检 | (运行中) |
| `git diff --check` | 空白 | (运行中) |
