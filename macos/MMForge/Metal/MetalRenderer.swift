import Metal
import MetalKit
import simd

// MARK: - Matrix helpers

extension simd_float4x4 {
    init(lookAt eye: simd_float3, target: simd_float3, up: simd_float3) {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        self.init(columns: (
            simd_float4(s.x, u.x, -f.x, 0),
            simd_float4(s.y, u.y, -f.y, 0),
            simd_float4(s.z, u.z, -f.z, 0),
            simd_float4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }

    init(perspectiveFovY fovY: Float, aspect: Float, near: Float, far: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange
        self.init(columns: (
            simd_float4(xScale, 0, 0, 0),
            simd_float4(0, yScale, 0, 0),
            simd_float4(0, 0, zScale, -1),
            simd_float4(0, 0, wzScale, 0)
        ))
    }
}

// MARK: - Uniforms / GPU types

struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var baseColor: simd_float4
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
}

// MARK: - MetalRenderer

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState

    private var gpuMeshes: [GPUMesh] = []
    private var sceneBounds: (min: simd_float3, max: simd_float3) = (.zero, .zero)
    private var camera = CameraState()
    private var needsFitToView = true

    struct CameraState {
        var target: simd_float3 = .zero
        var distance: Float = 5.0
        var yaw: Float = 0.0
        var pitch: Float = Float.pi / 9  // 20 degrees
        var fovY: Float = Float.pi / 4   // 45 degrees
        var near: Float = 0.01
        var far: Float = 1000.0

        var eye: simd_float3 {
            let sy = sin(yaw), cy = cos(yaw)
            let sp = sin(pitch), cp = cos(pitch)
            return target + simd_float3(sy * cp, sp, cy * cp) * distance
        }

        var viewMatrix: simd_float4x4 {
            simd_float4x4(lookAt: eye, target: target, up: simd_float3(0, 1, 0))
        }

        func projectionMatrix(aspect: Float) -> simd_float4x4 {
            simd_float4x4(perspectiveFovY: fovY, aspect: aspect, near: near, far: far)
        }

        mutating func fit(center: simd_float3, radius: Float) {
            target = center
            distance = max(radius / tan(fovY * 0.5) * 1.5, 0.1)
            near = max(radius * 0.001, 0.001)
            far = max(radius * 100, 100)
        }
    }

    init?(mtkView: MTKView) {
        guard let device = mtkView.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        mtkView.depthStencilPixelFormat = .depth32Float

        let library = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float

        // Vertex descriptor: position (float3) + normal (float3) = 24 bytes stride
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 24
        desc.vertexDescriptor = vd

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: desc)

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)!

        super.init()
    }

    // MARK: - Mesh upload

    func upload(positions: UnsafePointer<Float>, normals: UnsafePointer<Float>,
                vertexCount: Int, indices: UnsafePointer<UInt32>, indexCount: Int) {
        let stride = vertexCount * 3 * MemoryLayout<Float>.size
        guard let vb = device.makeBuffer(length: stride * 2, options: .storageModeShared) else { return }

        // Interleave position + normal
        let ptr = vb.contents().bindMemory(to: Float.self, capacity: vertexCount * 6)
        for i in 0..<vertexCount {
            ptr[i * 6 + 0] = positions[i * 3 + 0]
            ptr[i * 6 + 1] = positions[i * 3 + 1]
            ptr[i * 6 + 2] = positions[i * 3 + 2]
            ptr[i * 6 + 3] = normals[i * 3 + 0]
            ptr[i * 6 + 4] = normals[i * 3 + 1]
            ptr[i * 6 + 5] = normals[i * 3 + 2]
        }

        let ibSize = indexCount * MemoryLayout<UInt32>.size
        guard let ib = device.makeBuffer(bytes: indices, length: ibSize, options: .storageModeShared) else { return }

        gpuMeshes.append(GPUMesh(vertexBuffer: vb, indexBuffer: ib, indexCount: indexCount))
    }

    func setSceneBounds(min: simd_float3, max: simd_float3) {
        sceneBounds = (min, max)
        let center = (min + max) * 0.5
        let radius = length(max - min) * 0.5
        camera.fit(center: center, radius: radius)
        needsFitToView = false
    }

    func clearMeshes() {
        gpuMeshes.removeAll()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Depth buffer auto-resizes with MTKView
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let viewMat = camera.viewMatrix
        let projMat = camera.projectionMatrix(aspect: aspect)
        let mvp = projMat * viewMat

        var uniforms = Uniforms(
            mvp: mvp,
            model: matrix_identity_float4x4,
            baseColor: simd_float4(0.7, 0.7, 0.72, 1.0)
        )

        for mesh in gpuMeshes {
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: mesh.indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Camera

    func rotate(dx: Float, dy: Float) {
        camera.yaw += dx * 0.005
        camera.pitch = max(-Float.pi/2 * 0.99, min(Float.pi/2 * 0.99, camera.pitch + dy * 0.005))
    }

    func zoom(delta: Float) {
        camera.distance *= exp(-delta * 0.1)
        camera.distance = max(0.01, min(10000, camera.distance))
    }

    func pan(dx: Float, dy: Float) {
        let view = camera.viewMatrix
        let right = simd_float3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = simd_float3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        camera.target += (-dx * right + dy * up) * camera.distance * 0.001
    }

    func fitToView() {
        let center = (sceneBounds.min + sceneBounds.max) * 0.5
        let radius = length(sceneBounds.max - sceneBounds.min) * 0.5
        camera.fit(center: center, radius: radius)
    }
}
