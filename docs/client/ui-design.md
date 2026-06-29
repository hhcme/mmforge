# UI 设计规范

> MMForge 原生客户端的 UI 设计规范。
>
> 最后更新：2026-06-29

---

## 设计原则

- 原生体验：遵循各平台设计规范（macOS HIG、iOS HIG）
- 性能优先：UI 渲染不影响 3D 渲染性能
- 信息密度：CAD 用户需要看到更多信息
- 可定制：支持面板显隐、布局调整

---

## macOS 界面布局

```
┌──────────────────────────────────────────────────────────┐
│  ┌─ Title Bar ─────────────────────────────────────────┐ │
│  │  [●●●]  MMForge          [用户] [设置]              │ │
│  └─────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────┤
│  ┌─ Toolbar ───────────────────────────────────────────┐ │
│  │  [打开] [保存] │ [实体] [线框] [透明] │ [测量] [标注] │ │
│  └─────────────────────────────────────────────────────┘ │
├────────────┬─────────────────────────────────────────────┤
│            │                                             │
│  Sidebar   │           Main Content                      │
│            │                                             │
│  文件      │     ┌─ 3D/2D View ──────────────────────┐  │
│  ├─ model1 │     │                                   │  │
│  ├─ model2 │     │                                   │  │
│  └─ model3 │     │         渲染区域                   │  │
│            │     │                                   │  │
│  结构树    │     │                                   │  │
│  ├─ 零件1  │     │                                   │  │
│  │  ├─ 面1 │     │                                   │  │
│  │  └─ 面2 │     └───────────────────────────────────┘  │
│  └─ 零件2  │                                             │
│            │     ┌─ Properties ─────────────────────┐   │
│  图层      │     │  选中: 零件1                      │   │
│  ☑ 图层1   │     │  面数: 127                        │   │
│  ☑ 图层2   │     │  大小: 100×50×30 mm              │   │
│            │     └──────────────────────────────────┘   │
├────────────┴─────────────────────────────────────────────┤
│  ┌─ Status Bar ────────────────────────────────────────┐ │
│  │  坐标: (12.5, 34.2, 0.0)  │  比例: 1:1  │  60 fps  │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

---

## SwiftUI 组件

### 侧边栏

```swift
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section("Files") {
                ForEach(appState.recentFiles, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "doc")
                        .onTapGesture {
                            appState.openFile(url: url)
                        }
                }
            }

            if let doc = appState.currentDocument {
                Section("Structure") {
                    OutlineGroup(doc.sceneTree.children, id: \.id) { node in
                        Label(node.name, systemImage: node.isGroup ? "folder" : "cube")
                    }
                }

                Section("Layers") {
                    ForEach(doc.layers) { layer in
                        Toggle(layer.name, isOn: $layer.isVisible)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
```

### 3D 视图

```swift
struct Viewer3DView: View {
    let document: Document
    @State private var camera = OrbitCamera()
    @State private var renderMode: RenderMode = .solid

    var body: some View {
        MetalView(renderer: document.renderer)
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
            .toolbar {
                RenderModePicker(mode: $renderMode)
            }
    }
}
```

---

## 主题

```swift
struct MMForgeTheme {
    // 颜色
    static let accent = Color.blue
    static let background = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)

    // 字体
    static let titleFont = Font.system(.title2, design: .rounded)
    static let bodyFont = Font.system(.body)
    static let monoFont = Font.system(.caption, design: .monospaced)

    // 间距
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 16
}
```
