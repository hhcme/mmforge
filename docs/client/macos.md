# macOS 客户端设计

> MMForge macOS 客户端的技术设计（SwiftUI + Metal）。
>
> 最后更新：2026-06-29

---

## 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| UI 框架 | SwiftUI | 苹果最新官方推荐 |
| 3D 渲染 | Metal | 苹果自家 GPU API，优先使用当前稳定 SDK 能力 |
| 2D 渲染 | Core Graphics / Metal | 系统原生 |
| Rust 桥接 | Swift-Rust FFI | 通过 C ABI 桥接 |
| 构建工具 | Xcode + SPM | 官方工具链 |
| 最低版本 | 发布前按功能矩阵确定 | 开发主线优先跟进当前稳定 macOS / Xcode / SwiftUI |

---

## Apple 设计规范

macOS 客户端必须按 Apple Human Interface Guidelines 设计和验收：

- 窗口：采用文档型应用结构，支持文件打开、最近文件、拖放和多窗口策略。
- 菜单栏：常用命令进入系统菜单，保留标准快捷键，例如 `Cmd+O`、`Cmd+S`、`Cmd+,`。
- Toolbar：放置高频查看工具，例如打开、适配视图、渲染模式、测量、剖切；按钮需要图标、label 和 tooltip。
- Sidebar：用于文件列表、产品结构树、图层树等导航信息。
- Inspector：用于当前选择对象属性、材质、测量结果、剖切参数和标注参数。
- Status bar：显示坐标、单位、选择数量、三角形数、fps、解析进度等状态。
- Accessibility：所有主要控件提供可读 label，支持键盘导航和 VoiceOver 基础使用。
- Appearance：支持系统 Dark Mode，颜色不硬编码到单一主题。
- Long-running tasks：解析、tessellation、导出等长任务必须显示进度并支持取消。

参考：

- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines/
- macOS app design: https://developer.apple.com/design/human-interface-guidelines/macos
- SwiftUI: https://developer.apple.com/xcode/swiftui/
- Metal: https://developer.apple.com/metal/

---

## 项目结构

```
macos/
├── MMForge.xcodeproj
├── MMForge/
│   ├── App/
│   │   ├── MMForgeApp.swift         # App 入口
│   │   └── AppState.swift           # 全局状态
│   │
│   ├── Views/
│   │   ├── ContentView.swift        # 主视图
│   │   ├── Sidebar/
│   │   │   ├── FileListView.swift   # 文件列表
│   │   │   └── StructureTreeView.swift # 结构树
│   │   ├── Viewer/
│   │   │   ├── Viewer3DView.swift   # 3D 查看器
│   │   │   ├── Viewer2DView.swift   # 2D 查看器
│   │   │   └── MetalView.swift      # Metal 渲染视图
│   │   ├── Toolbar/
│   │   │   ├── MainToolbar.swift    # 主工具栏
│   │   │   └── RenderModePicker.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   │
│   ├── Metal/
│   │   ├── Shaders/
│   │   │   ├── Shaders.metal        # Metal 着色器
│   │   │   ├── PBR.metal            # PBR 光照
│   │   │   └── Wireframe.metal      # 线框渲染
│   │   ├── Renderer.swift           # Metal 渲染器
│   │   ├── Scene.swift              # 场景管理
│   │   ├── Camera.swift             # 相机控制
│   │   └── Material.swift           # 材质系统
│   │
│   ├── Models/
│   │   ├── Document.swift           # 文档模型
│   │   └── RenderSettings.swift     # 渲染设置
│   │
│   ├── RustBridge/
│   │   ├── include/
│   │   │   └── mmforge_bridge.h     # C 头文件（bindgen 生成）
│   │   ├── mmforge_bridge.swift     # Swift 桥接层
│   │   └── RustFFI.swift            # 高层封装
│   │
│   └── Resources/
│       ├── Assets.xcassets
│       └── Shaders.metallib
│
├── Shared/                          # macOS/iOS 共享代码
│   ├── Views/
│   ├── Models/
│   └── RustBridge/
│
└── Package.swift                    # SPM 依赖
```

---

## SwiftUI 应用架构

### App 入口

```swift
@main
struct MMForgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    appState.showOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
```

### 主视图

```swift
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            // 侧边栏
            SidebarView()
        } detail: {
            // 主视图
            if let document = appState.currentDocument {
                if document.is3D {
                    Viewer3DView(document: document)
                } else {
                    Viewer2DView(document: document)
                }
            } else {
                WelcomeView()
            }
        }
        .toolbar {
            MainToolbar()
        }
    }
}
```

### 状态管理

```swift
@MainActor
class AppState: ObservableObject {
    @Published var currentDocument: Document?
    @Published var recentFiles: [URL] = []
    @Published var renderSettings = RenderSettings()

    private let rustBridge = RustBridge()

    func openFile(url: URL) {
        Task {
            let handle = try await rustBridge.openFile(path: url.path)
            let info = try await rustBridge.getModelInfo(handle: handle)
            let tree = try await rustBridge.getSceneTree(handle: handle)

            currentDocument = Document(
                url: url,
                handle: handle,
                info: info,
                sceneTree: tree
            )
        }
    }
}
```

---

## Metal 3D 渲染器

### MTKView 集成

```swift
struct MetalView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer.device
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // 更新渲染参数
    }
}
```

### Metal 渲染器核心

```swift
class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState!
    var depthStencilState: MTLDepthStencilState!

    // 场景数据
    var vertexBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    var uniformBuffer: MTLBuffer?

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        setupPipeline()
    }

    func setupPipeline() {
        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_pbr")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float

        pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 更新投影矩阵
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)

        // 设置顶点/索引缓冲区
        if let vb = vertexBuffer {
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
        }
        if let ib = indexBuffer {
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indexCount,
                indexType: .uint32,
                indexBuffer: ib,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

---

## Rust FFI 桥接

### C 头文件（bindgen 生成）

```c
// mmforge_bridge.h
typedef struct ModelHandle ModelHandle;

ModelHandle* mmforge_open_file(const char* path);
void mmforge_close_file(ModelHandle* handle);
ModelInfo mmforge_get_model_info(ModelHandle* handle);
SceneTree mmforge_get_scene_tree(ModelHandle* handle);
RenderData mmforge_get_render_data(ModelHandle* handle, TessellationOptions options);
```

### Swift 桥接层

```swift
class RustBridge {
    func openFile(path: String) throws -> ModelHandle {
        let cPath = path.cString(using: .utf8)!
        guard let handle = mmforge_open_file(cPath) else {
            throw RustError.openFailed
        }
        return ModelHandle(ptr: handle)
    }

    func getModelInfo(handle: ModelHandle) throws -> ModelInfo {
        let cInfo = mmforge_get_model_info(handle.ptr)
        return ModelInfo(from: cInfo)
    }

    func getRenderData(handle: ModelHandle, options: TessellationOptions) throws -> RenderData {
        let cData = mmforge_get_render_data(handle.ptr, options.toC())
        return RenderData(from: cData)
    }
}
```

---

## 构建配置

### Xcode 项目设置

```
Build Settings:
  - Minimum Deployment: release-defined
  - Swift Language Version: Swift 6+ when supported by the stable toolchain
  - Metal Language Version: latest stable, with feature availability checks
  - Architecture: arm64 (Apple Silicon), x86_64 (Intel)
```

### Rust 编译

```bash
# 编译 Rust 静态库
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# 合并为 universal binary
lipo -create \
  target/aarch64-apple-darwin/release/libmmforge_core.a \
  target/x86_64-apple-darwin/release/libmmforge_core.a \
  -output macos/MMForge/libmmforge_core.a

# 生成 C 头文件
cbindgen --crate mmforge-core -o macos/MMForge/RustBridge/include/mmforge_bridge.h
```

---

## macOS/iOS 代码共享

```
Shared/
├── Views/              # SwiftUI 视图（90% 共享）
│   ├── Viewer3DView.swift
│   ├── Viewer2DView.swift
│   └── StructureTreeView.swift
├── Models/             # 数据模型（100% 共享）
│   ├── Document.swift
│   └── RenderSettings.swift
├── Metal/              # Metal 渲染器（100% 共享）
│   ├── Renderer.swift
│   ├── Shaders.metal
│   └── Camera.swift
└── RustBridge/         # Rust 桥接（100% 共享）
    ├── mmforge_bridge.h
    └── RustFFI.swift
```

平台差异（不共享的部分）：
- macOS: NSViewRepresentable、菜单栏、文件拖放
- iOS: UIViewRepresentable、触控手势、分享功能
