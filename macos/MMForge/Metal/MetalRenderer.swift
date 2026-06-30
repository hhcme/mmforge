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

    /// Inverse of a 4x4 matrix using cofactor expansion.
    var inverse: simd_float4x4 {
        let m = self
        var inv = simd_float4x4()

        inv[0][0] =  m[1][1]*m[2][2]*m[3][3] - m[1][1]*m[2][3]*m[3][2] - m[2][1]*m[1][2]*m[3][3]
                   + m[2][1]*m[1][3]*m[3][2] + m[3][1]*m[1][2]*m[2][3] - m[3][1]*m[1][3]*m[2][2]
        inv[1][0] = -m[1][0]*m[2][2]*m[3][3] + m[1][0]*m[2][3]*m[3][2] + m[2][0]*m[1][2]*m[3][3]
                   - m[2][0]*m[1][3]*m[3][2] - m[3][0]*m[1][2]*m[2][3] + m[3][0]*m[1][3]*m[2][2]
        inv[2][0] =  m[1][0]*m[2][1]*m[3][3] - m[1][0]*m[2][3]*m[3][1] - m[2][0]*m[1][1]*m[3][3]
                   + m[2][0]*m[1][3]*m[3][1] + m[3][0]*m[1][1]*m[2][3] - m[3][0]*m[1][3]*m[2][1]
        inv[3][0] = -m[1][0]*m[2][1]*m[3][2] + m[1][0]*m[2][2]*m[3][1] + m[2][0]*m[1][1]*m[3][2]
                   - m[2][0]*m[1][2]*m[3][1] - m[3][0]*m[1][1]*m[2][2] + m[3][0]*m[1][2]*m[2][1]

        let det = m[0][0]*inv[0][0] + m[0][1]*inv[1][0] + m[0][2]*inv[2][0] + m[0][3]*inv[3][0]
        guard abs(det) > 1e-12 else { return matrix_identity_float4x4 }
        let invDet = 1.0 / det

        inv[0][1] = (-m[0][1]*m[2][2]*m[3][3] + m[0][1]*m[2][3]*m[3][2] + m[2][1]*m[0][2]*m[3][3]
                    - m[2][1]*m[0][3]*m[3][2] - m[3][1]*m[0][2]*m[2][3] + m[3][1]*m[0][3]*m[2][2]) * invDet
        inv[0][2] = ( m[0][1]*m[1][2]*m[3][3] - m[0][1]*m[1][3]*m[3][2] - m[1][1]*m[0][2]*m[3][3]
                    + m[1][1]*m[0][3]*m[3][2] + m[3][1]*m[0][2]*m[1][3] - m[3][1]*m[0][3]*m[1][2]) * invDet
        inv[0][3] = (-m[0][1]*m[1][2]*m[2][3] + m[0][1]*m[1][3]*m[2][2] + m[1][1]*m[0][2]*m[2][3]
                    - m[1][1]*m[0][3]*m[2][2] - m[2][1]*m[0][2]*m[1][3] + m[2][1]*m[0][3]*m[1][2]) * invDet

        inv[1][1] = ( m[0][0]*m[2][2]*m[3][3] - m[0][0]*m[2][3]*m[3][2] - m[2][0]*m[0][2]*m[3][3]
                    + m[2][0]*m[0][3]*m[3][2] + m[3][0]*m[0][2]*m[2][3] - m[3][0]*m[0][3]*m[2][2]) * invDet
        inv[1][2] = (-m[0][0]*m[1][2]*m[3][3] + m[0][0]*m[1][3]*m[3][2] + m[1][0]*m[0][2]*m[3][3]
                    - m[1][0]*m[0][3]*m[3][2] - m[3][0]*m[0][2]*m[1][3] + m[3][0]*m[0][3]*m[1][2]) * invDet
        inv[1][3] = ( m[0][0]*m[1][2]*m[2][3] - m[0][0]*m[1][3]*m[2][2] - m[1][0]*m[0][2]*m[2][3]
                    + m[1][0]*m[0][3]*m[2][2] + m[2][0]*m[0][2]*m[1][3] - m[2][0]*m[0][3]*m[1][2]) * invDet

        inv[2][0] = inv[2][0] * invDet
        inv[2][1] = ( m[0][0]*m[2][1]*m[3][3] - m[0][0]*m[2][3]*m[3][1] - m[2][0]*m[0][1]*m[3][3]
                    + m[2][0]*m[0][3]*m[3][1] + m[3][0]*m[0][1]*m[2][3] - m[3][0]*m[0][3]*m[2][1]) * invDet
        inv[2][2] = (-m[0][0]*m[1][1]*m[3][3] + m[0][0]*m[1][3]*m[3][1] + m[1][0]*m[0][1]*m[3][3]
                    - m[1][0]*m[0][3]*m[3][1] - m[3][0]*m[0][1]*m[1][3] + m[3][0]*m[0][3]*m[1][1]) * invDet
        inv[2][3] = ( m[0][0]*m[1][1]*m[2][3] - m[0][0]*m[1][3]*m[2][1] - m[1][0]*m[0][1]*m[2][3]
                    + m[1][0]*m[0][3]*m[2][1] + m[2][0]*m[0][1]*m[1][3] - m[2][0]*m[0][3]*m[1][1]) * invDet

        inv[3][0] = inv[3][0] * invDet
        inv[3][1] = (-m[0][0]*m[2][1]*m[3][2] + m[0][0]*m[2][2]*m[3][1] + m[2][0]*m[0][1]*m[3][2]
                    - m[2][0]*m[0][2]*m[3][1] - m[3][0]*m[0][1]*m[2][2] + m[3][0]*m[0][2]*m[2][1]) * invDet
        inv[3][2] = ( m[0][0]*m[1][1]*m[3][2] - m[0][0]*m[1][2]*m[3][1] - m[1][0]*m[0][1]*m[3][2]
                    + m[1][0]*m[0][2]*m[3][1] + m[3][0]*m[0][1]*m[1][2] - m[3][0]*m[0][2]*m[1][1]) * invDet
        inv[3][3] = (-m[0][0]*m[1][1]*m[2][2] + m[0][0]*m[1][2]*m[2][1] + m[1][0]*m[0][1]*m[2][2]
                    - m[1][0]*m[0][2]*m[2][1] - m[2][0]*m[0][1]*m[1][2] + m[2][0]*m[0][2]*m[1][1]) * invDet

        inv[0][0] = inv[0][0] * invDet
        inv[1][0] = inv[1][0] * invDet
        return inv
    }
}

/// Subscript access to simd_float3 by axis index.
extension simd_float3 {
    subscript(axis: Int) -> Float {
        get {
            switch axis {
            case 0: return x
            case 1: return y
            default: return z
            }
        }
        set {
            switch axis {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }
}

// MARK: - Uniforms / GPU types

struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var baseColor: simd_float4
    var highlightColor: simd_float4  // rgb = tint, a = blend factor
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    var visible: Bool = true
    let nodeIndex: Int
    let boundsMin: simd_float3
    let boundsMax: simd_float3
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

    /// Currently selected node index (highlighted in viewport).
    var selectedNodeIndex: Int?
    /// Set of hidden node indices.
    var hiddenNodeIndices: Set<Int> = []

    // MARK: - Camera

    struct CameraState {
        var target: simd_float3 = .zero
        var distance: Float = 5.0
        var yaw: Float = 0.0
        var pitch: Float = Float.pi / 9
        var fovY: Float = Float.pi / 4
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

    // MARK: - Init

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
                vertexCount: Int, indices: UnsafePointer<UInt32>, indexCount: Int,
                nodeIndex: Int, boundsMin: simd_float3, boundsMax: simd_float3) {
        let stride = vertexCount * 3 * MemoryLayout<Float>.size
        guard let vb = device.makeBuffer(length: stride * 2, options: .storageModeShared) else { return }

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

        gpuMeshes.append(GPUMesh(
            vertexBuffer: vb, indexBuffer: ib, indexCount: indexCount,
            visible: !hiddenNodeIndices.contains(nodeIndex),
            nodeIndex: nodeIndex,
            boundsMin: boundsMin, boundsMax: boundsMax
        ))
    }

    func setSceneBounds(min: simd_float3, max: simd_float3) {
        sceneBounds = (min, max)
        let center = (min + max) * 0.5
        let radius = length(max - min) * 0.5
        camera.fit(center: center, radius: radius)
    }

    func clearMeshes() {
        gpuMeshes.removeAll()
        selectedNodeIndex = nil
        hiddenNodeIndices = []
    }

    // MARK: - Selection / Visibility

    func setSelectedNode(_ index: Int?) {
        selectedNodeIndex = index
    }

    func setNodeVisible(_ index: Int, visible: Bool) {
        for i in gpuMeshes.indices where gpuMeshes[i].nodeIndex == index {
            gpuMeshes[i].visible = visible
        }
    }

    func setHiddenNodes(_ indices: Set<Int>) {
        hiddenNodeIndices = indices
        for i in gpuMeshes.indices {
            gpuMeshes[i].visible = !indices.contains(gpuMeshes[i].nodeIndex)
        }
    }

    // MARK: - Picking (CPU AABB ray test)

    /// Test a screen-space click against all visible meshes.
    /// Returns the node index of the closest hit, or nil.
    func pickNode(at viewSize: CGSize, point: CGPoint) -> Int? {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let invVP = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix).inverse

        let ndcX = Float(point.x / viewSize.width) * 2 - 1
        let ndcY = Float(1 - point.y / viewSize.height) * 2 - 1

        let near4 = invVP * simd_float4(ndcX, ndcY, -1, 1)
        let far4 = invVP * simd_float4(ndcX, ndcY, 1, 1)
        let rayOrigin = simd_float3(near4.x, near4.y, near4.z) / near4.w
        let rayDir = normalize(simd_float3(far4.x, far4.y, far4.z) / far4.w - rayOrigin)

        var closestDist: Float = .infinity
        var closestNode: Int?

        for mesh in gpuMeshes where mesh.visible {
            if let t = rayAABBIntersect(origin: rayOrigin, dir: rayDir,
                                        bmin: mesh.boundsMin, bmax: mesh.boundsMax),
               t < closestDist {
                closestDist = t
                closestNode = mesh.nodeIndex
            }
        }

        return closestNode
    }

    /// Slab-method ray-AABB intersection.
    private func rayAABBIntersect(origin: simd_float3, dir: simd_float3,
                                   bmin: simd_float3, bmax: simd_float3) -> Float? {
        var tmin: Float = -.infinity
        var tmax: Float = .infinity

        for axis in 0..<3 {
            let o = origin[axis], d = dir[axis]
            let lo = bmin[axis], hi = bmax[axis]
            if abs(d) < 1e-12 {
                if o < lo || o > hi { return nil }
            } else {
                var t1 = (lo - o) / d
                var t2 = (hi - o) / d
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1)
                tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        return tmax >= 0 ? max(tmin, 0) : nil
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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
        let mvp = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
        let highlightTint = simd_float4(0.2, 0.5, 1.0, 0.4)

        for mesh in gpuMeshes {
            guard mesh.visible else { continue }

            let isHighlighted = (mesh.nodeIndex == selectedNodeIndex)
            var uniforms = Uniforms(
                mvp: mvp,
                model: matrix_identity_float4x4,
                baseColor: simd_float4(0.7, 0.7, 0.72, 1.0),
                highlightColor: isHighlighted ? highlightTint : simd_float4(0, 0, 0, 0)
            )

            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: mesh.indexCount,
                indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Camera controls

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
