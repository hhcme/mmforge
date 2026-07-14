# Real STEP Fixture Acceptance — 2026-07-14

**日期**: 2026-07-14
**范围**: 真实 21MB STEP fixture 异步解析验收、Fresh Debug 构建

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | FrustumPlanes far plane 符号修正 | ✅ (前次提交) |
| 2 | RealStepFixtureAcceptanceTests 真实 fixture XCTest | ✅ |
| 3 | fresh-debug-build.sh 非 GUI 构建脚本 | ✅ |
| 4 | 构建 manifest (commit SHA, hash, 产物路径) | ✅ |

---

## RealStepFixtureAcceptanceTests

**文件**: `AsyncParseTests.swift`

- 读取 `testfile/方盒子.step`（21MB）或 `MMFORGE_REAL_STEP_FIXTURE` 指定路径
- 经 `DocumentViewModel.parseFile` 完整异步流水线 + 流式上传
- 断言：≥97 nodes, ≥96 GPU meshes, >1000 triangles, bounds 有效
- 视锥剔除: culled < total（全部剔除时 fail-open XCTSkip）
- 1280×720 离屏渲染非空 + drawCalls > 0
- 主线程交互使用 `Task { @MainActor in ... }` + `expectation` 模式

---

## fresh-debug-build.sh

**文件**: `macos/scripts/fresh-debug-build.sh`

- 清理构建 → Rust bridge（含 OCCT shim）→ Xcode Debug .app
- 记录 commit SHA, 可执行文件 SHA256, 产物路径 → `macos/build/.build-manifest.json`
- 不启动 GUI、不抢焦点

## 验证

| 命令 | 结果 |
|------|------|
| `xcodebuild test` (skip real fixture) | ✅ **268 passed, 0 failures** |
| `fresh-debug-build.sh` | ✅ BUILD SUCCEEDED |
| `cargo fmt/clippy` | ✅ clean |
| `test-xcode-shell-build.sh` | ✅ 18/18 |
| `git diff --check` | ✅ clean |
