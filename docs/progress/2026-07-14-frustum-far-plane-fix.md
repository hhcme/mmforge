# FrustumPlanes Far-Plane Fix — 2026-07-14

**日期**: 2026-07-14
**范围**: FrustumPlanes far 平面符号修正，删除规避逻辑，新增 5 个确定性测试

---

## 根因

`FrustumPlanes` 的 far 平面公式使用 `row2 - row3`，但 Metal NDC [0,1] 中远裁面 `z=w` 的外向法线应为 `row3 - row2`（即 `w-z ≥ 0`）。

原公式 `row2 - row3` 导致法线指向错误方向，使所有 mesh 的 AABB 被判定为在远裁面之"外"而被剔除——大场景全部变黑。

## 修复

```swift
// 修复前: far = simd_float4(m[0][2] - m[0][3], ...)  // row2-row3 (错误)
// 修复后: far = simd_float4(m[0][3] - m[0][2], ...)  // row3-row2 (正确)
```

同时删除了 `if gpuMeshes.count > 4` 的规避逻辑（该 guard 是为了掩盖上述 bug）。

## 新增测试（5 个）

| 测试 | 验证 |
|------|------|
| `test_frustum_multi_mesh_not_all_culled_and_renders` | 5 mesh: culled<total, drawCalls>0, pixels>0 |
| `test_deep_assembly_frustum_and_render` | 6+ mesh: culled<total, rendering correct |
| `test_far_plane_culls_distant_mesh` | 越远裁面 mesh 必被剔除 |
| `test_all_render_modes_produce_pixels_with_frustum` | solid/wireframe/transparent 均可见 |
| `test_node_selection_visible_with_frustum_culling` | 选择在视锥剔除后可见 |

## 验证

| 命令 | 结果 |
|------|------|
| `xcodebuild test` | ✅ **268 passed, 0 failures** |
| `cargo fmt/clippy` | ✅ clean |
| `test-xcode-shell-build.sh` | ✅ 18/18 |
