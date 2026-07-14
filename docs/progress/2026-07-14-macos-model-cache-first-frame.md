# macOS Model Cache & First-Frame Delivery — 2026-07-14

**日期**: 2026-07-14
**范围**: 文件 URL 完整传递、缓存实际加载、LSM 序列化移出 MainActor、缓存命中跳过 OCCT、损坏回退

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | fileURL 从 DocumentGroup → MMForgeDocument → ContentView → parseSourceURL | ✅ |
| 2 | parseSourceURL 不再为空，缓存键始终计算 | ✅ |
| 3 | ModelCache.load 在解析前实际调用 | ✅ |
| 4 | 缓存命中：直接加载 LSM，跳过 OCCT 解析和 tessellation | ✅ |
| 5 | 缓存损坏/来源变更/版本变化 → 安全回退到完整解析 | ✅ |
| 6 | LSM 序列化和缓存存储移出 MainActor (Task.detached) | ✅ |
| 7 | 代际取消保护 (parseGeneration token) | ✅ |

---

## ✅ 1. fileURL 完整传递链路

**根因**: `parseSourceURL` 声明但从未赋值，缓存键永远为 nil。

### 修复链路

```
DocumentGroup { file in... }          ← file.fileURL 可用
    ↓ ContentView(fileURL: file.fileURL)
    ↓ viewModel.parseSourceURL = fileURL
    ↓ parseFile → currentCacheKey = ModelCache.cacheKey(for: url)
```

**修改文件**:
- `MMForgeApp.swift`: DocumentGroup 传递 `file.fileURL` → ContentView
- `ContentView.swift`: 新增 `let fileURL: URL?` 参数，在 onAppear/onChange/handleDrop 中设置
- `MMForgeDocument.swift`: 新增 `var fileURL: URL?`（可选，拖拽时设置）

---

## ✅ 2-4. 缓存实际加载——跳过 OCCT

**文件**: `MMForgeDocument.swift:parseFile()`

### 新流程

```
parseFile(data, ext)
  ├─ currentCacheKey = ModelCache.cacheKey(for: parseSourceURL)
  ├─ IF cache hit:
  │   ├─ parseStage = "loading from cache"
  │   ├─ Task.detached (background):
  │   │   └─ 写 LSM → tmpFile → mmf_parse_file(tmpFile)  ← LSM 解析，无 OCCT
  │   └─ MainActor:
  │       ├─ OK → finishParse(fromCache: true)
  │       └─ 损坏 → ModelCache.evict() → startAsyncParse() 回退
  └─ IF cache miss:
      └─ startAsyncParse() → 完整 OCCT 解析 → finishParse(fromCache: false)
```

### finishParse（两路径统一）
1. 释放旧 doc，存储新 doc
2. **后台**: `Task.detached(.background)` 中序列化 LSM → 存入缓存
3. 构建 DTO → 上传渲染
4. 设置 `.loaded` 状态

---

## ✅ 5. 损坏/取消/版本回退

| 场景 | 行为 |
|------|------|
| 缓存文件损坏（加载失败） | `ModelCache.evict(key)` → `startAsyncParse()` 回退 |
| 源文件内容变化 | 缓存键变化 → 自动视为 miss |
| 解析器/OCCT 版本变化 | 缓存键计算纳入版本 → 旧缓存不匹配 |
| 用户取消（打开新文件） | `parseGeneration` 递增 → 旧回调和任务被丢弃 |

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo fmt --all --check` | ✅ clean |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `xcodebuild test` | ✅ **263 passed, 0 failures** |
| `test-xcode-shell-build.sh` | ✅ 18/18 |

---

## 文件变更总览

| 文件 | 操作 | 说明 |
|------|------|------|
| `macos/MMForge/App/MMForgeApp.swift` | 修改 | DocumentGroup 传递 fileURL |
| `macos/MMForge/Views/ContentView.swift` | 修改 | fileURL 参数 → parseSourceURL |
| `macos/MMForge/Document/MMForgeDocument.swift` | 修改 | 缓存加载、finishParse、后台存储、fileURL |
| `macos/MMForge/RustBridge/RustBridge.swift` | 修改 | ModelCache.evict() 公开方法 |
