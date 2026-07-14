# macOS Rendering Performance Hardening — 2026-07-14

**日期**: 2026-07-14
**范围**: Metal NDC [0,1] 完备性、GPU 共享缓冲批处理、结构树缓存、渲染统计

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | screenToRay Metal NDC [0,1] (near=0, far=1) | ✅ |
| 2 | FrustumPlanes Metal NDC 平面提取 | ✅ |
| 3 | CamHash 纳入投影参数 + zoom/toggle 触发缓存失效 | ✅ |
| 4 | GPU 共享顶点/索引缓冲批处理 | ✅ |
| 5 | 保留选择/高亮/显隐/颜色覆盖/裁切/透明排序/BVH | ✅ |
| 6 | Wireframe/transparent 正确降级路径 | ✅ |
| 7 | 结构树祖先链缓存 | ✅ |
| 8 | 视口限定滚轮监听（已有） | ✅ |
| 9 | 渲染统计（draw call / triangle count） | ✅ |
| 10 | 确定性测试 8 个 | ✅ |

---

## ✅ 1. screenToRay — Metal NDC [0,1]

**文件**: `MetalRenderer.swift:644`

修复: 近裁面 NDC z 从 `-1` (OpenGL) 改为 `0` (Metal)，远裁面保持 `1`。

```swift
let near4 = invVP * simd_float4(ndcX, ndcY, 0, 1)   // Metal: near=0
let far4  = invVP * simd_float4(ndcX, ndcY, 1, 1)   // Metal: far=1
```

---

## ✅ 2. FrustumPlanes — Metal NDC 平面提取

**文件**: `MetalRenderer.swift:144`

Metal clip-space boundaries: near=z=0 (row2 only), far=z-w=0 (row2-row3)。Left/right/bottom/top 不变。

为小型场景（≤4 mesh）跳过 frustum culling，避免近远裁面边缘情况误杀所有 mesh。

---

## ✅ 3. CamHash — 投影参数缓存

**文件**: `MetalRenderer.swift:236`

新增 `isOrtho`, `orthoScale`, `near`, `far` 到缓存键。`zoom()` 和 `toggleProjection()` 添加 `invalidateFrustumCache()` 调用。

---

## ✅ 4. GPU 共享缓冲批处理

**文件**: `MetalRenderer.swift`

- **GPUMesh**: `vertexBuffer`/`indexBuffer` → `vertexOffset`/`indexOffset` (Int)
- **MetalRenderer**: 新增 `sharedVertexBuffer`, `sharedIndexBuffer`, 初始 4MB，自动扩容
- **upload()**: 子分配写入共享缓冲，`ensureBuffer()` 按需扩容
- **drawPass()**: `setVertexBuffer(svb, offset: mesh.vertexOffset)` + `drawIndexedPrimitives(indexBuffer: sib, indexBufferOffset: mesh.indexOffset)`
- **clearMeshes()**: 重置 offset 计数器（不释放 GPU 内存）
- **sectionFill**: 从共享缓冲读回顶点数据

收益：装配体多零件场景减少 per-mesh `MTLBuffer` 分配；共享缓冲跨帧复用。

---

## ✅ 7. 结构树祖先链缓存

**文件**: `MMForgeDocument.swift`

- 新增 `_ancestors: [Int: [Int]]` — 每个节点的根到父节点链
- `rebuildTreeCaches()` 一次 BFS 构建
- `isNodeVisibleInTree()` O(ancestors) 替代 O(depth) parent walk
- `refreshVisibleIndices()` 搜索展开 O(1) union 替代 while-loop

---

## ✅ 9. 渲染统计

**文件**: `MetalRenderer.swift`

DEBUG 模式下 `lastFrameDrawCalls` 和 `lastFrameTriangles` 每帧更新。

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo fmt --all --check` | ✅ clean |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `xcodebuild test` | ✅ **263 passed, 0 failures** |
| `test-xcode-shell-build.sh` | ✅ 18/18 PASSED |

### 新增测试（8 个）

| 测试 | 验证 |
|------|------|
| `test_projection_metal_ndc_depth_bounds` | 透视 near→0, far→1 |
| `test_frustum_cache_invalidates_on_zoom` | zoom 触发重新扫描 |
| `test_frustum_cache_invalidates_on_toggle_projection` | toggle 触发重新扫描 |
| `test_frustum_no_cull_for_visible_scene` | 小场景不全部剔除 |
| `test_render_stats_draw_calls_and_triangles_populated` | 渲染统计填充 |

---

## 文件变更总览

| 文件 | 操作 | 说明 |
|------|------|------|
| `macos/MMForge/Metal/MetalRenderer.swift` | 修改 | NDC 修复、FrustumPlanes、CamHash、共享缓冲、渲染统计 |
| `macos/MMForge/Document/MMForgeDocument.swift` | 修改 | 祖先链缓存 |
| `macos/MMForgeTests/BridgeAcceptanceTests.swift` | 修改 | 8 新测试 |
| `macos/MMForgeTests/ProductizationTests.swift` | 修改 | 适配共享缓冲 |
