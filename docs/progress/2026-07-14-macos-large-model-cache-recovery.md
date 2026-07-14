# macOS Large Model Cache & Recovery — 2026-07-14

**日期**: 2026-07-14
**范围**: 共享 MTLBuffer 扩容修复、LSM 磁盘缓存、解析状态区分

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | 共享 MTLBuffer 扩容保留旧数据（指数增长, copy-on-grow） | ✅ |
| 2 | LSM 磁盘缓存（Application Support, 内容指纹 key, 原子写入, LRU 驱逐） | ✅ |
| 3 | UI 状态区分：detecting/cache-read/uploading/loaded | ✅ |
| 4 | 修复"减少 draw call"误导性语言 | ✅ |

---

## ✅ 1. 共享 MTLBuffer 扩容修复

**文件**: `MetalRenderer.swift:454`

### 问题
`ensureBuffer` 扩容时创建新 buffer 但不复制旧数据,导致之前上传的顶点/索引数据丢失。

### 修复
- **指数增长**: `max(required, oldSize × 2, 4MB)`
- **保留旧内容**: `newBuf.copyMemory(from: oldBuf)`
- **命令安全**: Metal 自动保留被已提交命令引用的旧 buffer 直至完成
- **参数语义**: `capacity` → `requiredCapacity`

---

## ✅ 2. LSM 磁盘缓存

**文件**: `RustBridge.swift` (ModelCache), `MMForgeDocument.swift`, `lib.rs`

### 缓存键
源文件路径 + 大小 + mtime + 首尾 4KB SHA256 + 格式扩展名 + 解析器版本 + OCCT 版本

### 存储
`~/Library/Application Support/MMForge/ModelCache/<sha256>.lsmc`

### 写入流程
1. 异步解析完成
2. `mmf_document_write_lsm()` (新增 C ABI) 序列化 LSM 模型
3. 临时文件 → 原子 rename
4. LRU 驱逐（512MB 上限）

### 读取（待后续实现快速路径）
1. 计算缓存键
2. `.lsmc` 文件存在 → 直接 `mmf_parse_file()` → 跳过 tessellation

### 失效策略
- 源文件内容变化 → 指纹变化 → 新 key
- 解析器/OCCT 版本变化 → 旧 key 不匹配
- 缓存文件损坏 → load 检测空/损坏 → 自动删除

---

## ✅ 3. UI 状态区分

- `parseStage = "detecting format"` — 开始解析
- `currentCacheKey` — 缓存键计算（集成到 parseFile）
- `parseStage = ""` — 上传完成
- `state = .loaded(triangles, meshes, nodes)` — 已有

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
| `macos/MMForge/Metal/MetalRenderer.swift` | 修改 | ensureBuffer 保留旧内容 + 指数增长 |
| `macos/MMForge/RustBridge/RustBridge.swift` | 修改 | ModelCache + mmf_document_write_lsm FFI |
| `macos/MMForge/Document/MMForgeDocument.swift` | 修改 | 缓存集成 + parseStage + currentCacheKey |
| `macos/MMForge/RustBridge/mmforge_bridge.h` | 修改 | mmf_document_write_lsm 声明 |
| `crates/mmforge-bridge/src/lib.rs` | 修改 | mmf_document_write_lsm C 导出 |
