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

    init(orthoLeft left: Float, right: Float,
         bottom: Float, top: Float, near: Float, far: Float) {
        let rl = right - left, tb = top - bottom, fn = far - near
        self.init(columns: (
            simd_float4(2 / rl, 0, 0, 0),
            simd_float4(0, 2 / tb, 0, 0),
            simd_float4(0, 0, -1 / fn, 0),
            simd_float4(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1)
        ))
    }

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

extension simd_float3 {
    subscript(axis: Int) -> Float {
        get { switch axis { case 0: return x; case 1: return y; default: return z } }
        set { switch axis { case 0: x = newValue; case 1: y = newValue; default: z = newValue } }
    }
}

// MARK: - Render mode

enum RenderMode: Int {
    case solid = 0
    case wireframe = 1
    case solidWireframe = 2
    case transparent = 3
}

// MARK: - Uniforms / GPU types

struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var baseColor: simd_float4
    var highlightColor: simd_float4
    var clipPlane: simd_float4
    var renderMode: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    var visible: Bool = true
    let nodeIndex: Int
    let boundsMin: simd_float3
    let boundsMax: simd_float3
    /// BVH for CPU-side ray–triangle picking.
    let bvh: MeshBVH
}

/// Frustum plane extraction + AABB intersection, matching Rust Frustum.
struct FrustumPlanes {
    private let planes: [simd_float4] // left, right, bottom, top, near, far

    /// Extract frustum planes from a view-projection matrix (OpenGL convention).
    init(from vp: simd_float4x4) {
        // Column-major: m[col][row_component]
        // Row R = (m[0][R], m[1][R], m[2][R], m[3][R])
        let m = vp
        // Extract six planes using Gribb/Hartmann (OpenGL: near=row3+row2)
        let left   = simd_float4(m[0][3] + m[0][0], m[1][3] + m[1][0], m[2][3] + m[2][0], m[3][3] + m[3][0])
        let right  = simd_float4(m[0][3] - m[0][0], m[1][3] - m[1][0], m[2][3] - m[2][0], m[3][3] - m[3][0])
        let bottom = simd_float4(m[0][3] + m[0][1], m[1][3] + m[1][1], m[2][3] + m[2][1], m[3][3] + m[3][1])
        let top    = simd_float4(m[0][3] - m[0][1], m[1][3] - m[1][1], m[2][3] - m[2][1], m[3][3] - m[3][1])
        let near   = simd_float4(m[0][3] + m[0][2], m[1][3] + m[1][2], m[2][3] + m[2][2], m[3][3] + m[3][2])
        let far    = simd_float4(m[0][3] - m[0][2], m[1][3] - m[1][2], m[2][3] - m[2][2], m[3][3] - m[3][2])
        // Normalize
        planes = [left, right, bottom, top, near, far].map { p in
            let len = sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
            return len > 0 ? p / len : p
        }
    }

    /// Test AABB against all six planes (p-vertex optimization).
    func intersects(min mins: simd_float3, max maxs: simd_float3) -> Bool {
        for p in planes {
            let px = p.x >= 0 ? maxs.x : mins.x
            let py = p.y >= 0 ? maxs.y : mins.y
            let pz = p.z >= 0 ? maxs.z : mins.z
            if p.x * px + p.y * py + p.z * pz + p.w < 0 {
                return false
            }
        }
        return true
    }
}

// MARK: - MetalRenderer

/// Overlay vertex: position + color (no normals, no lighting).
///
/// Layout must match MTLVertexDescriptor and Metal shader exactly:
///   position: float4 at offset 0  (16 bytes)
///   color:    float4 at offset 16 (16 bytes)
///   stride:   32 bytes
///
/// We use simd_float4 (not simd_float3) for position because Swift's
/// simd_float3 has 16-byte alignment with padding, which would mismatch
/// Metal's float3 (12 bytes, 4-byte alignment).
struct OverlayVertex {
    var position: simd_float4  // xyz in xyz, w unused
    var color: simd_float4
}

struct OverlayUniforms {
    var mvp: simd_float4x4
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let wireframePipeline: MTLRenderPipelineState
    private let transparentPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let depthStencilStateNoWrite: MTLDepthStencilState

    /// Weak reference to the MTKView for screenshot capture.
    weak var mtkView: MTKView?

    // Measurement overlay state
    private var overlayVertexBuffer: MTLBuffer?
    private var overlayVertexCount: Int = 0

    // Section fill state
    private var sectionFillBuffer: MTLBuffer?
    private var sectionFillVertexCount: Int = 0

    // Color override: nodeIndex → override color
    var nodeColorOverrides: [Int: simd_float4] = [:]

    private var gpuMeshes: [GPUMesh] = []
    private var sceneBounds: (min: simd_float3, max: simd_float3) = (.zero, .zero)
    private(set) var camera = CameraState()

    var selectedNodeIndex: Int?
    var hiddenNodeIndices: Set<Int> = []
    /// Frame-local frustum cull mask (rebuilt each frame, never persists).
    private var frustumCulledIndices: Set<Int> = []
    /// Cached camera state for frustum skip when stationary.
    private struct CamHash: Equatable {
        var aspect: Float; var yaw: Float; var pitch: Float
        var dist: Float; var tx: Float; var ty: Float; var tz: Float
    }
    private var lastFrustumCamHash = CamHash(aspect: -1, yaw: 0, pitch: 0, dist: 0, tx: 0, ty: 0, tz: 0)
    /// Count of frustum-cull skips since last cache invalidation (DEBUG-only).
#if DEBUG
    private(set) var frustumSkipCount: Int = 0
#endif
    var renderMode: RenderMode = .solid
    var clipPlane: simd_float4 = simd_float4(0, 0, 0, -999999)

    // MARK: - Named views

    enum NamedView {
        case front, back, left, right, top, bottom, isometric
    }

    // MARK: - Camera

    struct CameraState {
        var target: simd_float3 = .zero
        var distance: Float = 5.0
        var yaw: Float = 0.0
        var pitch: Float = Float.pi / 9
        var fovY: Float = Float.pi / 4
        var near: Float = 0.01
        var far: Float = 1000.0
        var isOrthographic: Bool = false
        var orthoScale: Float = 5.0

        var eye: simd_float3 {
            let sy = sin(yaw), cy = cos(yaw)
            let sp = sin(pitch), cp = cos(pitch)
            return target + simd_float3(sy * cp, sp, cy * cp) * distance
        }

        var viewMatrix: simd_float4x4 {
            simd_float4x4(lookAt: eye, target: target, up: simd_float3(0, 1, 0))
        }

        func projectionMatrix(aspect: Float) -> simd_float4x4 {
            if isOrthographic {
                let halfW = orthoScale * aspect
                let halfH = orthoScale
                return simd_float4x4(orthoLeft: -halfW, right: halfW,
                                     bottom: -halfH, top: halfH,
                                     near: near, far: far)
            }
            return simd_float4x4(perspectiveFovY: fovY, aspect: aspect,
                                 near: near, far: far)
        }

        mutating func fit(center: simd_float3, radius: Float) {
            target = center
            distance = max(radius / tan(fovY * 0.5) * 1.5, 0.1)
            orthoScale = radius * 1.5
            near = max(radius * 0.001, 0.001)
            far = max(radius * 100, 100)
        }

        mutating func setView(_ view: NamedView) {
            // Standard CAD view angles (yaw, pitch) in radians.
            // Convention: +X right, +Y up, +Z toward viewer.
            switch view {
            case .front:    yaw = 0;              pitch = 0
            case .back:     yaw = Float.pi;       pitch = 0
            case .left:     yaw = Float.pi / 2;   pitch = 0
            case .right:    yaw = -Float.pi / 2;  pitch = 0
            case .top:      yaw = 0;              pitch = Float.pi / 2 - 0.01
            case .bottom:   yaw = 0;              pitch = -(Float.pi / 2 - 0.01)
            case .isometric: yaw = Float.pi / 4;  pitch = Float.pi / 4
            }
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
        let vertexFunc = library.makeFunction(name: "vertex_main")!
        let fragmentFunc = library.makeFunction(name: "fragment_main")!

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 24

        // Solid pipeline
        let solidDesc = MTLRenderPipelineDescriptor()
        solidDesc.vertexFunction = vertexFunc
        solidDesc.fragmentFunction = fragmentFunc
        solidDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        solidDesc.depthAttachmentPixelFormat = .depth32Float
        solidDesc.vertexDescriptor = vd
        self.solidPipeline = try! device.makeRenderPipelineState(descriptor: solidDesc)

        // Wireframe pipeline (line fill mode)
        let wireDesc = MTLRenderPipelineDescriptor()
        wireDesc.vertexFunction = vertexFunc
        wireDesc.fragmentFunction = fragmentFunc
        wireDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        wireDesc.depthAttachmentPixelFormat = .depth32Float
        wireDesc.vertexDescriptor = vd
        // Note: fillMode is set per-render-pass via MTLRenderCommandEncoder
        self.wireframePipeline = try! device.makeRenderPipelineState(descriptor: wireDesc)

        // Transparent pipeline (alpha blending)
        let transDesc = MTLRenderPipelineDescriptor()
        transDesc.vertexFunction = vertexFunc
        transDesc.fragmentFunction = fragmentFunc
        transDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        transDesc.colorAttachments[0].isBlendingEnabled = true
        transDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        transDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        transDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        transDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        transDesc.depthAttachmentPixelFormat = .depth32Float
        transDesc.vertexDescriptor = vd
        self.transparentPipeline = try! device.makeRenderPipelineState(descriptor: transDesc)

        // Depth stencil: write enabled
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)!

        // Depth stencil: write disabled (for transparent/overlay)
        let dsNoWrite = MTLDepthStencilDescriptor()
        dsNoWrite.depthCompareFunction = .less
        dsNoWrite.isDepthWriteEnabled = false
        self.depthStencilStateNoWrite = device.makeDepthStencilState(descriptor: dsNoWrite)!

        // Overlay pipeline (lines/points with position + color, no lighting)
        let overlayVertexFunc = library.makeFunction(name: "overlay_vertex")!
        let overlayFragmentFunc = library.makeFunction(name: "overlay_fragment")!
        let overlayDesc = MTLRenderPipelineDescriptor()
        overlayDesc.vertexFunction = overlayVertexFunc
        overlayDesc.fragmentFunction = overlayFragmentFunc
        overlayDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        overlayDesc.colorAttachments[0].isBlendingEnabled = true
        overlayDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        overlayDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayDesc.depthAttachmentPixelFormat = .depth32Float
        // Vertex descriptor must match OverlayVertex layout exactly:
        //   position: float4 at offset 0  (16 bytes)
        //   color:    float4 at offset 16 (16 bytes)
        //   stride:   32 bytes
        let overlayVD = MTLVertexDescriptor()
        overlayVD.attributes[0].format = .float4
        overlayVD.attributes[0].offset = 0
        overlayVD.attributes[0].bufferIndex = 0
        overlayVD.attributes[1].format = .float4
        overlayVD.attributes[1].offset = 16
        overlayVD.attributes[1].bufferIndex = 0
        overlayVD.layouts[0].stride = 32  // 2 × float4 = 32 bytes
        overlayDesc.vertexDescriptor = overlayVD
        self.overlayPipeline = try! device.makeRenderPipelineState(descriptor: overlayDesc)

        super.init()
    }

    // MARK: - Mesh upload

    func upload(positions: UnsafePointer<Float>, normals: UnsafePointer<Float>,
                vertexCount: Int, indices: UnsafePointer<UInt32>, indexCount: Int,
                nodeIndex: Int, boundsMin: simd_float3, boundsMax: simd_float3) {
        let posBytes = vertexCount * 3 * MemoryLayout<Float>.size
        let totalBytes = posBytes * 2
        guard let vb = device.makeBuffer(length: totalBytes, options: .storageModeShared) else { return }
        // Interleave positions and normals in 12-byte chunks per vertex,
        // matching the vertexDescriptor stroke=24, offset(normal)=12 layout.
        let stride = 6 * MemoryLayout<Float>.size  // 24 bytes per vertex
        let chunk  = 3 * MemoryLayout<Float>.size  // 12 bytes per pos/normal triplet
        let dst = vb.contents()
        for i in 0..<vertexCount {
            dst.advanced(by: i * stride).copyMemory(from: positions.advanced(by: i * 3), byteCount: chunk)
            dst.advanced(by: i * stride + chunk).copyMemory(from: normals.advanced(by: i * 3), byteCount: chunk)
        }
        let ibSize = indexCount * MemoryLayout<UInt32>.size
        guard let ib = device.makeBuffer(bytes: indices, length: ibSize, options: .storageModeShared) else { return }

        invalidateFrustumCache()

        // Build BVH directly from the input pointers — no intermediate Swift Array copy.
        let bvh = buildMeshBVH2(
            positions: positions, vertexCount: vertexCount,
            indices: indices, indexCount: indexCount
        )

        gpuMeshes.append(GPUMesh(
            vertexBuffer: vb, indexBuffer: ib, indexCount: indexCount,
            visible: !hiddenNodeIndices.contains(nodeIndex),
            nodeIndex: nodeIndex, boundsMin: boundsMin, boundsMax: boundsMax,
            bvh: bvh
        ))
    }

    func setSceneBounds(min: simd_float3, max: simd_float3) {
        sceneBounds = (min, max)
        camera.fit(center: (min + max) * 0.5, radius: length(max - min) * 0.5)
        invalidateFrustumCache()
    }

    func clearMeshes() {
        gpuMeshes.removeAll()
        selectedNodeIndex = nil
        hiddenNodeIndices = []
        invalidateFrustumCache()
    }

    /// Read-only access to GPU mesh list (DEBUG-only, for testing vertex layout).
#if DEBUG
    func getGPUMeshes() -> [GPUMesh] { gpuMeshes }
#endif

    private func invalidateFrustumCache() {
        lastFrustumCamHash = CamHash(aspect: -1, yaw: 0, pitch: 0, dist: 0, tx: 0, ty: 0, tz: 0)
#if DEBUG
        frustumSkipCount = 0
#endif
    }

    // MARK: - Measurement overlay

    /// Update the overlay vertex buffer with measurement lines and markers.
    /// Each measurement is a line from start to end (yellow) with endpoint markers.
    /// The pending point (if any) is drawn as a small cross marker.
    func updateOverlay(measurements: [(start: simd_float3, end: simd_float3)],
                       pendingPoint: simd_float3?) {
        var verts: [OverlayVertex] = []
        let lineColor = simd_float4(1.0, 0.85, 0.0, 1.0)  // yellow
        let pendingColor = simd_float4(0.2, 0.8, 1.0, 1.0)  // cyan
        let markerSize: Float = 0.005

        for m in measurements {
            let s = simd_float4(m.start.x, m.start.y, m.start.z, 1)
            let e = simd_float4(m.end.x, m.end.y, m.end.z, 1)
            verts.append(OverlayVertex(position: s, color: lineColor))
            verts.append(OverlayVertex(position: e, color: lineColor))
            appendMarker(&verts, center: m.start, size: markerSize, color: lineColor)
            appendMarker(&verts, center: m.end, size: markerSize, color: lineColor)
        }

        if let p = pendingPoint {
            appendMarker(&verts, center: p, size: markerSize * 1.5, color: pendingColor)
        }

        overlayVertexCount = verts.count
        if verts.isEmpty {
            overlayVertexBuffer = nil
            return
        }

        let size = verts.count * MemoryLayout<OverlayVertex>.size
        if overlayVertexBuffer == nil || overlayVertexBuffer!.length < size {
            overlayVertexBuffer = device.makeBuffer(length: size, options: .storageModeShared)
        }
        overlayVertexBuffer?.contents().copyMemory(from: verts, byteCount: size)
    }

    /// Clear the overlay.
    func clearOverlay() {
        overlayVertexBuffer = nil
        overlayVertexCount = 0
    }

    /// Update section fill geometry from the current clip plane.
    /// Computes intersection quads where the clip plane crosses
    /// visible mesh triangles.
    func updateSectionFill() {
        guard clipPlane.w > -999990 else {
            sectionFillBuffer = nil
            sectionFillVertexCount = 0
            return
        }

        let capColor = simd_float4(0.8, 0.3, 0.1, 0.6)

        // Collect mesh data for visible meshes.
        var meshData: [(positions: UnsafePointer<Float>, indices: UnsafePointer<UInt32>,
                        vertexCount: Int, indexCount: Int)] = []
        for mesh in gpuMeshes where mesh.visible {
            let posPtr = UnsafePointer(mesh.vertexBuffer.contents().assumingMemoryBound(to: Float.self))
            let idxPtr = UnsafePointer(mesh.indexBuffer.contents().assumingMemoryBound(to: UInt32.self))
            let vertCount = mesh.vertexBuffer.length / (6 * MemoryLayout<Float>.size)
            meshData.append((posPtr, idxPtr, vertCount, mesh.indexCount))
        }

        let verts = computeSectionFillVertices(
            meshes: meshData, clipPlane: clipPlane, capColor: capColor
        )

        let floatCount = verts.count
        guard floatCount > 0 else {
            sectionFillBuffer = nil
            sectionFillVertexCount = 0
            return
        }

        let byteCount = floatCount * MemoryLayout<Float>.size
        if sectionFillBuffer == nil || sectionFillBuffer!.length < byteCount {
            sectionFillBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        sectionFillBuffer?.contents().copyMemory(from: verts, byteCount: byteCount)
        // 8 floats per vertex: float4 position (16 bytes) + float4 color (16 bytes)
        sectionFillVertexCount = floatCount / 8
    }

    /// Clear the section fill buffer.
    func clearSectionFill() {
        sectionFillBuffer = nil
        sectionFillVertexCount = 0
    }

    private func appendMarker(_ verts: inout [OverlayVertex],
                              center: simd_float3, size: Float,
                              color: simd_float4) {
        // 6 lines forming a 3D cross at the center point.
        // Convert simd_float3 → simd_float4 for consistent layout.
        let c = simd_float4(center.x, center.y, center.z, 1)
        let axes: [simd_float4] = [
            simd_float4(size, 0, 0, 0), simd_float4(0, size, 0, 0), simd_float4(0, 0, size, 0)
        ]
        for axis in axes {
            verts.append(OverlayVertex(position: c - axis, color: color))
            verts.append(OverlayVertex(position: c + axis, color: color))
        }
    }

    // MARK: - Frustum Culling

    /// Update the frame-local frustum cull mask.  Skips recomputation if
    /// the camera is stationary (same yaw/pitch/dist/target as last frame).
    func updateFrustumCulling(aspect: Float) {
        let cam = camera
        let h = CamHash(aspect: aspect, yaw: cam.yaw, pitch: cam.pitch,
                        dist: cam.distance, tx: cam.target.x, ty: cam.target.y, tz: cam.target.z)
        if h == lastFrustumCamHash {
#if DEBUG
            frustumSkipCount += 1
#endif
            return
        }
        lastFrustumCamHash = h

        let vp = cam.projectionMatrix(aspect: aspect) * cam.viewMatrix
        let frustum = FrustumPlanes(from: vp)
        var culled = Set<Int>()
        for (i, mesh) in gpuMeshes.enumerated() {
            if !frustum.intersects(min: mesh.boundsMin, max: mesh.boundsMax) {
                culled.insert(i)
            }
        }
        frustumCulledIndices = culled
    }

    // MARK: - Selection / Visibility

    func setSelectedNode(_ index: Int?) { selectedNodeIndex = index }

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

    // MARK: - Picking

    /// Unproject a screen point to a world-space ray.
    private func screenToRay(at viewSize: CGSize, point: CGPoint) -> Ray {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let invVP = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix).inverse
        let ndcX = Float(point.x / viewSize.width) * 2 - 1
        let ndcY = Float(1 - point.y / viewSize.height) * 2 - 1
        let near4 = invVP * simd_float4(ndcX, ndcY, -1, 1)
        let far4 = invVP * simd_float4(ndcX, ndcY, 1, 1)
        let origin = simd_float3(near4.x, near4.y, near4.z) / near4.w
        let dir = normalize(simd_float3(far4.x, far4.y, far4.z) / far4.w - origin)
        return Ray(origin: origin, dir: dir)
    }

    /// Compute the visible ray interval after clipping.
    /// Returns (clipTMin, clipTMax) or nil if entire ray is clipped.
    private func clipInterval(ray: Ray) -> (Float, Float)? {
        guard clipPlane.w > -999990 else { return (0, .infinity) }
        let normal = simd_float3(clipPlane.x, clipPlane.y, clipPlane.z)
        let originDist = dot(normal, ray.origin) + clipPlane.w
        let denom = dot(normal, ray.dir)
        if abs(denom) < 1e-12 {
            return originDist < 0 ? nil : (0, .infinity)
        }
        let tClip = -originDist / denom
        if denom > 0 {
            return (max(tClip, 0), .infinity)
        } else {
            guard tClip >= 0 else { return nil }
            return (0, tClip)
        }
    }

    /// Pick the node index of the closest triangle hit.
    /// Uses BVH for fast ray–triangle intersection.
    func pickNode(at viewSize: CGSize, point: CGPoint) -> Int? {
        let ray = screenToRay(at: viewSize, point: point)
        guard let (clipMin, clipMax) = clipInterval(ray: ray) else { return nil }

        var bestT = clipMax
        var bestNode: Int?

        for mesh in gpuMeshes where mesh.visible {
            // Quick AABB reject.
            guard rayAABB(ray: ray, bmin: mesh.boundsMin, bmax: mesh.boundsMax,
                          tMin: clipMin, tMax: bestT) else { continue }

            // BVH triangle hit.
            if let hit = mesh.bvh.intersect(ray: ray, tMin: clipMin, tMax: bestT) {
                bestT = hit.t
                bestNode = mesh.nodeIndex
            }
        }
        return bestNode
    }

    /// Pick the closest triangle hit point on any visible mesh.
    /// Used for measurement point picking.
    func pickWorldPoint(at viewSize: CGSize, point: CGPoint) -> simd_float3? {
        let ray = screenToRay(at: viewSize, point: point)
        guard let (clipMin, clipMax) = clipInterval(ray: ray) else { return nil }

        var bestT = clipMax
        var bestPoint: simd_float3?

        for mesh in gpuMeshes where mesh.visible {
            guard rayAABB(ray: ray, bmin: mesh.boundsMin, bmax: mesh.boundsMax,
                          tMin: clipMin, tMax: bestT) else { continue }

            if let hit = mesh.bvh.intersect(ray: ray, tMin: clipMin, tMax: bestT) {
                bestT = hit.t
                bestPoint = hit.point
            }
        }
        return bestPoint
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

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let mvp = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
        let highlightTint = simd_float4(0.2, 0.5, 1.0, 0.4)

        // Update frustum visibility each frame (does not mutate gpuMeshes[*].visible).
        updateFrustumCulling(aspect: aspect)

        switch renderMode {
        case .solid:
            drawPass(encoder: encoder, pipeline: solidPipeline, mvp: mvp,
                     highlightTint: highlightTint, mode: 0, depthWrite: true, fillMode: .fill)

        case .wireframe:
            drawPass(encoder: encoder, pipeline: wireframePipeline, mvp: mvp,
                     highlightTint: highlightTint, mode: 1, depthWrite: true, fillMode: .lines)

        case .solidWireframe:
            // Solid pass
            drawPass(encoder: encoder, pipeline: solidPipeline, mvp: mvp,
                     highlightTint: highlightTint, mode: 0, depthWrite: true, fillMode: .fill)
            // Wireframe overlay — depth bias prevents surface z-fighting.
            encoder.setDepthBias(0.001, slopeScale: 1.0, clamp: 0.001)
            drawPass(encoder: encoder, pipeline: wireframePipeline, mvp: mvp,
                     highlightTint: simd_float4(0, 0, 0, 0), mode: 1,
                     depthWrite: false, fillMode: .lines)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)

        case .transparent:
            // Back-to-front sorting for correct alpha blending.
            let sorted = backToFrontIndices()
            drawPass(encoder: encoder, pipeline: transparentPipeline, mvp: mvp,
                     highlightTint: highlightTint, mode: 3, depthWrite: false,
                     fillMode: .fill, meshOrder: sorted)
        }

        // Section fill pass (filled triangles at clip plane, no depth write).
        if let sfb = sectionFillBuffer, sectionFillVertexCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setDepthStencilState(depthStencilStateNoWrite)
            var fillUniforms = OverlayUniforms(mvp: mvp)
            encoder.setVertexBuffer(sfb, offset: 0, index: 0)
            encoder.setVertexBytes(&fillUniforms,
                                   length: MemoryLayout<OverlayUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: sectionFillVertexCount)
        }

        // Measurement overlay pass (lines/markers on top, no depth write).
        if let vb = overlayVertexBuffer, overlayVertexCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setDepthStencilState(depthStencilStateNoWrite)
            var overlayUniforms = OverlayUniforms(mvp: mvp)
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            encoder.setVertexBytes(&overlayUniforms,
                                   length: MemoryLayout<OverlayUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0,
                                   vertexCount: overlayVertexCount)
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Returns visible mesh indices sorted back-to-front (farthest first)
    /// for correct alpha blending in transparent mode.
    private func backToFrontIndices() -> [Int] {
        let eye = camera.eye
        let fc = frustumCulledIndices
        return gpuMeshes.enumerated()
            .filter { $0.element.visible && !fc.contains($0.offset) }
            .sorted { a, b in
                let ca = (a.element.boundsMin + a.element.boundsMax) * 0.5
                let cb = (b.element.boundsMin + b.element.boundsMax) * 0.5
                return length(ca - eye) > length(cb - eye)
            }
            .map { $0.offset }
    }

    private func drawPass(encoder: MTLRenderCommandEncoder,
                          pipeline: MTLRenderPipelineState,
                          mvp: simd_float4x4,
                          highlightTint: simd_float4,
                          mode: UInt32,
                          depthWrite: Bool,
                          fillMode: MTLTriangleFillMode,
                          meshOrder: [Int]? = nil) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthWrite ? depthStencilState : depthStencilStateNoWrite)
        encoder.setTriangleFillMode(fillMode)

        let indices = meshOrder ?? Array(gpuMeshes.indices)
        let defaultAlpha: Float = mode == 3 ? 0.6 : 1.0
        for idx in indices {
            let mesh = gpuMeshes[idx]
            guard mesh.visible, !frustumCulledIndices.contains(idx) else { continue }
            let isHighlighted = (mesh.nodeIndex == selectedNodeIndex)
            // Per-mesh color: override → default grey
            var baseColor: simd_float4
            if let override = nodeColorOverrides[mesh.nodeIndex] {
                baseColor = simd_float4(override.x, override.y, override.z, defaultAlpha)
            } else {
                baseColor = simd_float4(0.7, 0.7, 0.72, defaultAlpha)
            }
            var uniforms = Uniforms(
                mvp: mvp, model: matrix_identity_float4x4,
                baseColor: baseColor,
                highlightColor: isHighlighted ? highlightTint : simd_float4(0, 0, 0, 0),
                clipPlane: clipPlane, renderMode: mode
            )
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: mesh.indexCount,
                indexType: .uint32, indexBuffer: mesh.indexBuffer, indexBufferOffset: 0
            )
        }
    }

    // MARK: - Camera controls

    func rotate(dx: Float, dy: Float) {
        camera.yaw += dx * 0.005
        camera.pitch = max(-Float.pi/2 * 0.99, min(Float.pi/2 * 0.99, camera.pitch + dy * 0.005))
    }

    func zoom(delta: Float) {
        if camera.isOrthographic {
            camera.orthoScale *= exp(-delta * 0.1)
            camera.orthoScale = max(0.001, min(100000, camera.orthoScale))
        } else {
            camera.distance *= exp(-delta * 0.1)
            camera.distance = max(0.01, min(10000, camera.distance))
        }
    }

    func pan(dx: Float, dy: Float) {
        let v = camera.viewMatrix
        let right = simd_float3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let up = simd_float3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        let scale = camera.isOrthographic ? camera.orthoScale * 0.002 : camera.distance * 0.001
        camera.target += (-dx * right + dy * up) * scale
    }

    func fitToView() {
        camera.fit(center: (sceneBounds.min + sceneBounds.max) * 0.5,
                   radius: length(sceneBounds.max - sceneBounds.min) * 0.5)
    }

    func setNamedView(_ view: NamedView) {
        camera.setView(view)
    }

    func toggleProjection() {
        camera.isOrthographic.toggle()
    }

    var isOrthographic: Bool {
        camera.isOrthographic
    }

    func resetCamera() {
        fitToView()
        camera.yaw = 0
        camera.pitch = Float.pi / 9
        camera.isOrthographic = false
    }

    // MARK: - Screenshot capture

    /// Capture the current viewport as an NSImage.
    ///
    /// Reads the current drawable texture via a blit command encoder
    /// and creates a CGImage from the pixel data.  Returns nil if
    /// the capture fails (e.g. no drawable available).
    func captureImage() -> NSImage? {
        guard let view = mtkView,
              let drawable = view.currentDrawable else { return nil }

        let texture = drawable.texture
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height

        // Create a shared buffer for readback.
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        else { return nil }

        // Blit the drawable texture into the buffer.
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bufferSize)
        // No synchronize needed — buffer is .storageModeShared.
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Create CGImage from the buffer (BGRA pixel format).
        let pixelData = buffer.contents().bindMemory(to: UInt8.self, capacity: bufferSize)
        let data = Data(bytes: pixelData, count: bufferSize)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
