# macOS Acceptance Remediation — Phase 1 Closure

**提交**: `e095888` → ... → `5674379`（最终）
**日期**: 2026-07-13
**范围**: OffscreenCoordinator 可观测化、RecentDocumentStore 依赖注入、CLI JSON 污染修复、真实门禁测试

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | OffscreenCoordinator 可观测超时/取消机制 | ✅ |
| 2 | RecentDocumentStore 移除 XCTest 探测，DI 注入 | ✅ |
| 3 | CLI `--format json` stdout 始终可解析 JSON | ✅ |
| 4 | STEP/IGES fixture CLI JSON 集成测试 | ✅ |
| 5 | test-preflight-geometry-gating.sh 真实门禁覆盖 | ✅ |

---

## ✅ 1. OffscreenCoordinator — 可观测超时调度

**文件**: `macos/MMForge/Metal/OffscreenCoordinator.swift`

重构为可观测的三态事件模型：

```swift
enum Outcome: Equatable {
    case operationCompleted    // operation 完成
    case timeoutFired          // 超时触发
    case timeoutCancelled      // 超时被取消（operation 先完成）
}
```

- `run(timeout:observer:operation:)` — observer 接收所有事件
- timeout Task 在 `Task.isCancelled` 时返回 `.timeoutCancelled`，**不调用 resume**
- operation Task 完成后取消 timeout Task，发送 `.operationCompleted`

### 测试证据（不再用"没崩溃"作证据）

| 测试 | 断言 |
|------|------|
| `testOperationWinsTimeoutCancelledNotFired` | observer 收到 `.operationCompleted` + `.timeoutCancelled`；**断言 `.timeoutFired` 不存在** |
| `testTimeoutWinsOperationDiscarded` | observer 收到 `.timeoutFired`，返回 nil；**断言 `.operationCompleted` 不存在** |
| `testRapidTimeoutRace` | 10ms timeout 对 500ms operation：observer 收到 `.timeoutFired`，elapsed < 1s |

---

## ✅ 2. RecentDocumentStore — 依赖注入

**文件**: `macos/MMForge/App/RecentDocumentStore.swift`

移除全部 `NSClassFromString("XCTestCase")` 探测。改为三参数依赖注入：

| 参数 | 生产 | 测试 |
|------|------|------|
| `userDefaults` | `.standard` | `UserDefaults(suiteName:)` 隔离 |
| `reachability` | `checkResourceIsReachable` | 可控的 `Set<URL>` |
| `systemMenu` | `NSDocumentControllerMenu()` | `NoOpSystemMenu()` |

- `add()` 拒绝不可达 URL（通过注入的 reachability 判断）
- `init()` 启动时清理失效 URL（持久化 + 系统菜单）
- `add()` 运行时清理失效条目
- `cleanSystemMenuIfNeeded()` 推迟到 `AppDelegate.applicationDidFinishLaunching` 调用（避免 SEGV）

### 新增协议

```swift
protocol SystemRecentMenu {
    func recentDocumentURLs() -> [URL]
    func clearRecentDocuments(_ sender: Any?)
    func noteNewRecentDocumentURL(_ url: URL)
}
```

### 测试：10 个 XCTest 全部通过

---

## ✅ 3. CLI JSON stdout 不污染

**文件**: `crates/mmforge-cli/src/main.rs`

- `--format json` 错误输出为有效 JSON（含 `"error"` 字段）
- `"occt_available": bool` 在所有 JSON 响应中存在
- 失败时 `node_count`/`triangle_count` 设为 0
- 诊断文本仅通过 stderr（非 JSON 路径时）

### 集成测试（3 个新增）

| 测试 | 验证 |
|------|------|
| `step_fixture_json_error_is_valid_json_on_stdout` | assembly.stp 输出为可解析 JSON |
| `iges_fixture_json_error_is_valid_json_on_stdout` | box.igs 输出为可解析 JSON |
| `nonexistent_file_json_error_valid_json_on_stdout` | 不存在文件输出为可解析 JSON |

---

## ✅ 4. test-preflight-geometry-gating.sh 重写

**文件**: `macos/scripts/test-preflight-geometry-gating.sh`

- 调用真实 `format-geometry-gate.sh`（不再模拟）
- 测试 advisory 模式（exit 3）+ 非 advisory 模式（exit 1）
- 验证表格式（FORMAT 头、五种格式都存在）
- 验证 STL/glTF 状态为 REAL-GEOMETRY、DXF 为 2D-ONLY
- 保留 `MMFORGE_CLI` / `CARGO_TARGET_DIR` 注入但不削弱真实门禁

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ clean |
| `cargo test --workspace --features occt` | ✅ 全部通过（含 3 新 JSON 测试） |
| `cargo fmt --check` | ✅ clean |
| `xcodebuild test` | ✅ **247 passed, 0 failures** |
| `MMFORGE_NO_OCCT_ADVISORY=1 bash format-geometry-gate.sh` | ✅ exit 3 (ADVISORY) |
| `bash format-geometry-gate.sh` (no advisory) | ✅ exit 1 (FAIL) |
| `bash test-preflight-geometry-gating.sh` | ✅ ALL TESTS PASSED |
| `git diff --check` | ✅ clean |

---

## ⚠️ 未验证项

| 项目 | 说明 |
|------|------|
| STEP/IGES OCCT 原生日志污染 | 当前环境无 OCCT 链接，无法复现 OCCT C++ Messenger 输出。修复策略已在 OCCT shim 中预留：`Message_DefaultMessenger` 可重定向到 stderr。有 OCCT 环境时需再验证。 |
| Metal 渲染帧率 | 未实现，`frame_time_ms` 标记为 `not_implemented` |
| GUI 人工待验 | File > Open Recent、离屏渲染导出、Dark Mode |

---

## 👁️ GUI 人工待验边界（无 GUI 运行，未激活）

- File > Open Recent 菜单动态填充
- Clear Recent Documents 功能
- 离屏渲染导出图片质量（Mock 测试已验证协调逻辑）
- Dark Mode 外观
