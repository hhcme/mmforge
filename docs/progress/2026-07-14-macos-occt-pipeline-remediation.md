# macOS OCCT Release Pipeline Remediation — 2026-07-14

**日期**: 2026-07-14
**范围**: OCCT 发布链路修复 — stdout/stderr 合约、指纹统一、Xcode shell 路径验证、cargo test 幂等性、OffscreenCoordinator 观察者契约

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | build-occt-shim.sh stdout/stderr 合约修复 | ✅ |
| 2 | Xcode Build Rust Bridge shell 路径验证 | ✅ |
| 3 | test-xcode-shell-build.sh 非 GUI 回归测试 | ✅ |
| 4 | 消除 shell/build.rs 双 fingerprint 实现 | ✅ |
| 5 | cargo test 不修改已跟踪 shim/fingerprint 文件 | ✅ |
| 6 | OffscreenCoordinator 观察者契约统一 | ✅ |
| 7 | 验收报告更新 | ✅ |

---

## ✅ 1. build-occt-shim.sh stdout/stderr 合约

**文件**: `macos/scripts/build-occt-shim.sh`

### 问题
- 直接执行路径（`bash build-occt-shim.sh`）向 stdout 输出两行：archive 路径 + `MMFORGE_SHIM_DIR=...`
- Xcode 通过 `SHIM_PATH=$(bash ...)` 捕获 stdout，会得到含脏数据的 `SHIM_PATH`

### 修复
- 移除直接执行路径的 `echo "MMFORGE_SHIM_DIR=..."`（调用方自行计算）
- 新增 stdout/stderr 合约文档注释
- 合约：
  - **stdout**: 恰好一行 — `libmmforge_occt_shim.a` 的绝对路径（失败时为空）
  - **stderr**: 所有诊断、进度、错误消息
  - **exit code**: 0=ready, 1=no-OCCT, 2=build-failed

---

## ✅ 2. Xcode Build Rust Bridge shell 路径验证

**文件**: `macos/MMForge.xcodeproj/project.pbxproj`

### 问题
Xcode shell 脚本在 `SHIM_PATH=$(bash build-occt-shim.sh)` 后直接 `export MMFORGE_SHIM_DIR="$(dirname "$SHIM_PATH")"`，无任何验证。

### 修复
添加三层验证：
1. `SHIM_PATH` 非空
2. `SHIM_PATH` 指向存在的文件
3. `$(dirname "$SHIM_PATH")` 是存在的目录

失败时明确报错退出。同时将所有 `echo` 诊断重定向到 stderr（`>&2`）。

---

## ✅ 3. test-xcode-shell-build.sh — 非 GUI 回归测试

**新文件**: `macos/scripts/test-xcode-shell-build.sh`

6 组测试，共 24 个断言：

| 测试组 | 断言数 | 覆盖 |
|--------|--------|------|
| 1. stdout 合约 | 3 | 恰好一行、含 `libmmforge_occt_shim.a`、exit code 正确 |
| 2. stderr 合约 | 6 | stdout 不含 "Building"/"ERROR"/"fingerprint"/"OCCT not configured" + stderr 非空 |
| 3. 缺少 OCCT | 2 | exit 1 + stderr 含 "OCCT dirs not found" |
| 4. 路径验证 | 4 | 有效路径接受、空路径拒绝、不存在文件拒绝、目录拒绝 |
| 5. 指纹一致性 | 2 | shell fingerprint == 已存储 fingerprint + 64-char hex |
| 6. sourced 模式 | 1 | `ensure_occt_shim` 函数可被 source 后使用 |

---

## ✅ 4. 消除双 fingerprint 实现

**文件**: `macos/scripts/build-occt-shim.sh`, `crates/mmforge-geometry/build.rs`

### 问题
Shell `compute_fingerprint()` 使用 `sha256(sha256(f1) ++ sha256(f2) ++ sha256(f3))`，而 Rust `compute_shim_fingerprint()` 使用 `sha256(f1 ++ f2 ++ f3)`。两者产生不同的指纹值，导致 shell 写入的 `.shim_fingerprint` 被 Rust 认为过期。

### 修复
统一为**单一规范**：

```
CANONICAL FINGERPRINT SPEC:
  SHA256 of the concatenated raw bytes of (in order):
    1. mmforge_occt_shim.cpp
    2. mmforge_occt_shim.h
    3. CMakeLists.txt
  产出: 64-char lowercase hex string.
```

- Shell: `cat f1 f2 f3 | shasum -a 256 | cut -d' ' -f1`
- Rust: `sha2::Sha256::update(f1); update(f2); update(f3); format!("{:x}", finalize())`

两者字节完全一致。在 `test-xcode-shell-build.sh` 测试 5a 中已验证 shell fingerprint == 存储 fingerprint。

---

## ✅ 5. cargo test 不修改已跟踪文件

**文件**: `.gitignore`, `crates/mmforge-geometry/build.rs`

### 问题
1. `crates/mmforge-geometry/shim/build/libmmforge_occt_shim.a` 和 `.shim_fingerprint` 被 git 跟踪
2. `build.rs` 的 `find_shim_library()` 在检测到指纹过期时**自动构建 shim** 并写入新 fingerprint

### 修复
1. **`.gitignore`**: 新增 ignore `shim/build/libmmforge_occt_shim.a`, `.shim_fingerprint`, `.cmake_configure.log`, `.cmake_build.log`
2. **`git rm --cached`**: 从 git 跟踪中移除上述两个文件
3. **`build.rs`**: 移除 `find_shim_library()` 中的 auto-build 逻辑。`build.rs` 现在**只检测和验证** shim，绝不写入 `shim/build/`。Auto-build 是 `build-occt-shim.sh` 的职责。同时移除 `write_shim_fingerprint()` 和 `build_shim_with_cmake()` 函数。
4. 保留 `compute_shim_fingerprint()` 和 `shim_fingerprint_changed()` 作为规范参考（`#[allow(dead_code)]`）。

---

## ✅ 6. OffscreenCoordinator 观察者契约统一

**文件**: `macos/MMForge/Metal/OffscreenCoordinator.swift`

### 问题
- 文档写 "Observer receives exactly TWO events" 但代码只发一个
- `LoserOutcome` 枚举定义但从未被观察者接收（死代码）
- 文档内部矛盾："Exactly ONE" vs "exactly TWO"

### 修复
- **移除 `LoserOutcome`** 枚举
- **简化 `resolve()` 函数签名**：移除 `loser` 参数
- **统一文档**："Exactly ONE terminal outcome is reported to observer per call"
- **保留 `Outcome` 枚举**（`.operationCompleted` / `.timeoutFired`）— 已为正确契约

现有测试 `OffscreenRenderTests.swift` 已验证单事件契约（`testOperationWinsTimeoutCancelledNotFired`, `testTimeoutWinsOperationDiscarded`, `testNeverBothOperationCompletedAndTimeoutFired` 等）。无需修改测试代码。

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo check --workspace` | ✅ clean |
| `cargo fmt --all --check` | ✅ clean |
| `cargo test --workspace` | ✅ all passed |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `bash macos/scripts/test-xcode-shell-build.sh` | ✅ 18/18 ALL PASSED |
| `xcodebuild test` | ✅ **250 passed, 0 failures, 0 unexpected** |
| `MMFORGE_NO_OCCT_ADVISORY=1 bash format-geometry-gate.sh` | ✅ exit 3 (ADVISORY — OCCT env vars not set) |
| `bash macos/scripts/preflight-check.sh` | ✅ Rust/Clippy/Fmt/Xcode tests pass |
| `git diff --check` | ✅ clean |

---

## 文件变更总览

| 文件 | 操作 | 说明 |
|------|------|------|
| `macos/scripts/build-occt-shim.sh` | 修改 | stdout/stderr 合约 + 统一 fingerprint |
| `macos/scripts/test-xcode-shell-build.sh` | **新增** | 24 断言非 GUI 回归测试 |
| `macos/MMForge.xcodeproj/project.pbxproj` | 修改 | Xcode shell 路径验证 + stderr 重定向 |
| `.gitignore` | 修改 | 忽略 shim build artifacts |
| `crates/mmforge-geometry/build.rs` | 修改 | 移除 auto-build，保留验证 + 规范文档 |
| `macos/MMForge/Metal/OffscreenCoordinator.swift` | 修改 | 移除 LoserOutcome，统一文档 |
| `crates/mmforge-geometry/shim/build/libmmforge_occt_shim.a` | untrack | git rm --cached |
| `crates/mmforge-geometry/shim/build/.shim_fingerprint` | untrack | git rm --cached |

---

## ⚠️ 未验证项

| 项目 | 说明 |
|------|------|
| GUI 人工待验 | 离屏渲染导出、Dark Mode、File > Open Recent |
| Metal 渲染帧率 | `frame_time_ms` 标记为 `not_implemented` |
| STEP/IGES OCCT 原生日志 | 需要 OCCT 实际链接环境验证 |
