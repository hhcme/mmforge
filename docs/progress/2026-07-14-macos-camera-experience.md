# macOS Industrial CAD Camera Experience — 2026-07-14

**日期**: 2026-07-14
**范围**: 工业 CAD 相机体验修复 — 抓取模型拖拽语义、Metal NDC [0,1] 深度矩阵、正交投影默认

---

## 交付清单

| # | 交付项 | 状态 |
|---|--------|------|
| 1 | rotate(dx:dy:) 反转符号 — 抓取模型语义 | ✅ |
| 2 | perspectiveFovY 矩阵修正为 Metal NDC [0,1] | ✅ |
| 3 | 默认/重置设为正交投影（消除工业透视感） | ✅ |
| 4 | 确定性方向测试 + 投影矩阵测试 | ✅ |
| 5 | 现有测试适配（resetCamera / zoom） | ✅ |

---

## ✅ 1. rotate(dx:dy:) — 抓取模型语义

**文件**: `macos/MMForge/Metal/MetalRenderer.swift` line 851

### 问题
原来的 `yaw += dx * 0.005` 是"围绕模型旋转"语义：向右拖 → 相机右转 → 模型左移。工业 CAD 用户预期的是"抓取模型直接移动"：向右拖 → 模型右移。

### 修复
```swift
camera.yaw -= dx * 0.005   // 右拖 → yaw 减小 → 模型右移
camera.pitch -= dy * 0.005  // 上拖 → pitch 减小 → 模型上移
```

### 测试
- `test_rotate_drag_right_yaw_decreases` — 右拖 → yaw 减小
- `test_rotate_drag_up_pitch_decreases` — 上拖 → pitch 减小
- `test_rotate_drag_left_yaw_increases` — 左拖 → yaw 增大（对称验证）

---

## ✅ 2. perspectiveFovY — Metal NDC [0,1]

**文件**: `macos/MMForge/Metal/MetalRenderer.swift` line 20

### 问题
原矩阵使用 OpenGL 规范（近裁面 → -1，远裁面 → 1），但 Metal 的 NDC 深度为 [0,1]（近→0，远→1）。这浪费了一半深度精度且可能造成不正确的裁剪。

### 修复
```swift
// OpenGL:  zScale = -(far + near) / zRange, wzScale = -2*far*near / zRange
// Metal:   zScale = -far / zRange,         wzScale = -(far * near) / zRange
```

### 测试
- `test_perspective_near_maps_to_zero` — 近裁面 → NDC 0
- `test_perspective_far_maps_to_one` — 远裁面 → NDC 1
- `test_orthographic_depth_is_metal_ndc` — 正交投影同样满足 Metal [0,1]

---

## ✅ 3. 正交投影默认

**文件**: `macos/MMForge/Metal/MetalRenderer.swift`

### 变更
- `CameraState.isOrthographic`: `false` → **`true`**
- `resetCamera()`: 设置 `isOrthographic = true`（原为 `false`）
- `toggleProjection()`: 保持不变，可随时切换到透视

### 理由
工业 CAD 模型（装配体、零件）应默认正交投影以消除透视畸变和广角感。透视模式保留为可选（用于检查/演示）。

### 测试
- `test_default_projection_is_orthographic` — resetCamera 后为 ortho
- `test_toggle_from_ortho_goes_to_perspective` — 一次切换→透视，再次→正交
- 适配 `test_camera_zoom_in_decreases_distance` / `test_headless_renderer_camera_zoom_changes_distance` — 先切到透视再测 distance zoom

---

## 构建验证矩阵

| 命令 | 结果 |
|------|------|
| `cargo fmt --all --check` | ✅ clean |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `xcodebuild test` | ✅ **258 passed, 0 failures** (含 8 新测试) |
| `test-xcode-shell-build.sh` | ✅ 18/18 PASSED |

### 新增测试（8 个）

| 测试 | 验证 |
|------|------|
| `test_rotate_drag_right_yaw_decreases` | 右拖 → yaw ↓ |
| `test_rotate_drag_up_pitch_decreases` | 上拖 → pitch ↓ |
| `test_rotate_drag_left_yaw_increases` | 左拖 → yaw ↑（对称） |
| `test_perspective_near_maps_to_zero` | Metal NDC 近=0 |
| `test_perspective_far_maps_to_one` | Metal NDC 远=1 |
| `test_orthographic_depth_is_metal_ndc` | 正交矩阵也满足 [0,1] |
| `test_default_projection_is_orthographic` | 默认正交 |
| `test_toggle_from_ortho_goes_to_perspective` | 切换仍可用 |

---

## 文件变更总览

| 文件 | 操作 | 说明 |
|------|------|------|
| `macos/MMForge/Metal/MetalRenderer.swift` | 修改 | rotate 符号反转、perspectiveFovY Metal NDC、默认/重置正交 |
| `macos/MMForgeTests/BridgeAcceptanceTests.swift` | 修改 | 8 个新测试 + 3 个适配 |
