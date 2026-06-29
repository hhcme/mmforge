# 手势交互设计

> macOS 和 iOS 的手势交互设计。
>
> 最后更新：2026-06-29

---

## macOS 手势

### 鼠标操作

| 操作 | 手势 | API 调用 |
|------|------|---------|
| 旋转 | 左键拖动 | `camera.rotate(dx, dy)` |
| 缩放 | 滚轮 | `camera.zoom(delta)` |
| 平移 | 右键拖动 / 中键拖动 | `camera.pan(dx, dy)` |
| 适配 | 双击 | `camera.fitToBounds(bounds)` |
| 选择 | 左键点击 | `bvh.rayQuery(ray)` |
| 框选 | Shift + 左键拖动 | `selectInRect(rect)` |

### 触控板手势

| 操作 | 手势 | API 调用 |
|------|------|---------|
| 旋转 | 单指拖动 | `camera.rotate(dx, dy)` |
| 缩放 | 双指捏合 | `camera.zoom(delta)` |
| 平移 | 双指拖动 | `camera.pan(dx, dy)` |
| 惯性滚动 | 快速甩动 | `camera.addVelocity(v)` |

### 实现

```swift
// 鼠标事件处理
class Viewer3DController: NSViewController {
    override func mouseDragged(with event: NSEvent) {
        if event.buttonMask == .left {
            // 左键拖动：旋转
            camera.rotate(
                deltaAzimuth: Float(event.deltaX) * 0.005,
                deltaElevation: Float(event.deltaY) * 0.005
            )
        } else if event.buttonMask == .right {
            // 右键拖动：平移
            camera.pan(
                deltaX: Float(event.deltaX) * 0.01,
                deltaY: Float(event.deltaY) * 0.01
            )
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮：缩放
        camera.zoom(delta: Float(event.scrollingDeltaY) * 0.001)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            // 双击：适配
            camera.fitToBounds(modelBounds)
        }
    }
}

// 触控板手势
class TrackpadHandler {
    var magnification: CGFloat = 0
    var translation: CGSize = .zero

    func handleMagnification(_ gesture: MagnificationGesture.Value) {
        let delta = gesture - magnification
        magnification = gesture
        camera.zoom(delta: Float(delta) * 2.0)
    }

    func handlePan(_ gesture: DragGesture.Value) {
        let dx = gesture.translation.width - translation.width
        let dy = gesture.translation.height - translation.height
        translation = gesture.translation
        camera.pan(deltaX: Float(dx) * 0.01, deltaY: Float(dy) * 0.01)
    }
}
```

---

## iOS 手势

| 操作 | 手势 | API 调用 |
|------|------|---------|
| 旋转 | 单指拖动 | `camera.rotate(dx, dy)` |
| 缩放 | 双指捏合 | `camera.zoom(delta)` |
| 平移 | 双指拖动 | `camera.pan(dx, dy)` |
| 适配 | 双击 | `camera.fitToBounds(bounds)` |
| 选择 | 单指点击 | `bvh.rayQuery(ray)` |

```swift
struct Viewer3DView: View {
    @State private var camera = OrbitCamera()

    var body: some View {
        MetalView(renderer: renderer)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        camera.rotate(
                            deltaAzimuth: Float(value.translation.width) * 0.005,
                            deltaElevation: Float(value.translation.height) * 0.005
                        )
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        camera.zoom(delta: Float(scale - 1.0))
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    camera.fitToBounds(modelBounds)
                }
            }
    }
}
```

---

## 键盘快捷键 (macOS)

| 快捷键 | 操作 |
|--------|------|
| Cmd+O | 打开文件 |
| Cmd+S | 保存 |
| Cmd+Z | 撤销 |
| Cmd+Shift+Z | 重做 |
| Cmd+0 | 适配模型 |
| Cmd+1 | 实体渲染 |
| Cmd+2 | 线框渲染 |
| Cmd+3 | 实体+线框 |
| Cmd+M | 测量模式 |
| Cmd+D | 标注模式 |
| Space | 切换剖切面 |
| Delete | 删除选中 |
| Cmd+A | 全选 |
| Cmd+Shift+I | 显示信息 |
