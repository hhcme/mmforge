# macOS Safe Cache & First-Frame — 2026-07-14

**日期**: 2026-07-14
**范围**: 消除 use-after-free 不安全模式、所有权安全、缓存流水线

---

## 不安全模式修复

| 模式 | 位置 | 问题 | 修复 |
|------|------|------|------|
| **B** (严重) | `finishParse` → `Task.detached` 捕获 `doc` 裸指针 | 后台任务持有已释放 MmfDocument 指针 → use-after-free | 在 detached 前同步序列化 LSM 为 Data，任务只传递 Data |
| **A** (中等) | cache-hit 路径: `docPtr` 在 bg 线程创建后进入 `MainActor.run` | 创建和使用之间的所有权间隙 | `mmf_parse_file` 移入 `MainActor.run` 内部，docPtr 仅在 MainActor 块内访问 |
| **C** (严重) | streaming loop: `currentDoc` 快照跨 `Task.yield()` 使用 | 挂起点间文档可能被替换，快照指向已释放内存 | 每次迭代从 `self.rustDoc` 重新读取，不在外部捕获 |

### Pattern B 详述

```
修复前: finishParse(doc) → Task.detached { writeLSM(doc: doc) }  ← doc 可能已被释放
修复后: finishParse(doc) → writeLSM(doc) → Data → Task.detached { store(data) }  ← 只有 safe Data
```

### Pattern C 详述

```
修复前: let currentDoc = self.rustDoc  ← 捕获一次
        for chunk in chunks {
            uploadChunk(from: currentDoc, ...)  ← 快照可能已失效
            await Task.yield()  ← 释放点
        }
修复后: for chunk in chunks {
            guard let currentDoc = self.rustDoc else { return }  ← 每次重新读取
            uploadChunk(from: currentDoc, ...)
            await Task.yield()
        }
```

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo fmt --all --check` | ✅ clean |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `xcodebuild test` | ✅ **263 passed, 0 failures** |
| `test-xcode-shell-build.sh` | ✅ 18/18 |

---

## 文件变更

| 文件 | 变更 |
|------|------|
| `MMForgeDocument.swift` | finishParse(Pattern B), cache-hit path(Pattern A), streaming(Pattern C) |
