import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - Supported file types

extension UTType {
    static let step = UTType("com.mmforge.step")!
    static let stl  = UTType("com.mmforge.stl")!
    static let gltf = UTType("com.mmforge.gltf")!
    static let glb  = UTType("com.mmforge.glb")!
    static let iges = UTType("com.mmforge.iges")!
    static let dxf  = UTType("com.mmforge.dxf")!
}

// MARK: - App preferences (persisted via UserDefaults)

/// Global viewer preferences, persisted across sessions.
struct AppPreferences {
    @AppStorage("exportFormat") static var exportFormat: String = "png"
    @AppStorage("exportScale") static var exportScale: Double = 1.0
    /// Persist the last render mode across document opens.
    @AppStorage("renderMode") static var renderMode: Int = RenderMode.solid.rawValue
}

// MARK: - Measurement

/// A point-to-point measurement in world coordinates.
struct Measurement: Identifiable {
    let id = UUID()
    let start: simd_float3
    let end: simd_float3

    /// Euclidean distance between start and end.
    var distance: Float {
        let d = end - start
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    }

    /// Per-axis deltas.
    var deltaX: Float { end.x - start.x }
    var deltaY: Float { end.y - start.y }
    var deltaZ: Float { end.z - start.z }
}

/// The document type for MMForge model files.
struct MMForgeDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.step, .stl, .gltf, .glb, .iges, .dxf]
    }

    /// Raw file data (passed to Rust bridge for parsing).
    var fileData: Data

    /// Original file extension (e.g. "step", "stl", "glb").
    /// Used to create temp files with the correct extension so Rust
    /// format detection works properly.
    var fileExtension: String

    init(fileData: Data = Data(), fileExtension: String = "step") {
        self.fileData = fileData
        self.fileExtension = fileExtension
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.fileData = data
        // Extract extension from the original filename.
        let filename = configuration.file.filename ?? "model.step"
        self.fileExtension = (filename as NSString).pathExtension.lowercased()
        if self.fileExtension.isEmpty {
            self.fileExtension = "step"
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: fileData)
    }
}

// MARK: - Document state

enum DocumentState: Equatable {
    case empty
    case loading
    case loaded(triangleCount: Int, meshCount: Int, nodeCount: Int)
    case error(String)
}

// MARK: - Document view model

/// Manages async parsing and Metal state for a document.
@MainActor
final class DocumentViewModel: ObservableObject {
    @Published var state: DocumentState = .empty
    @Published var nodeNames: [String] = []
    @Published var nodes: [RenderPacketDTO.NodeInfo] = []
    @Published var stats: RenderPacketDTO.ModelStats?
    @Published var selectedIndex: Int?
    @Published var hiddenNodeIndices: Set<Int> = []
    @Published var renderMode: RenderMode = .init(rawValue: AppPreferences.renderMode) ?? .solid
    @Published var clipEnabled: Bool = false
    @Published var clipAxis: Int = 2  // 0=X, 1=Y, 2=Z
    @Published var clipDistance: Float = 0.0

    // Sidebar tree state
    @Published var expandedIndices: Set<Int> = []
    @Published var searchText: String = ""

    // Measurement state (3D)
    @Published var measurementMode: Bool = false
    @Published var measurements: [Measurement] = []
    @Published var pendingPoint: simd_float3?

    // Annotation state (2D + 3D unified)
    @Published var annotations: [Annotation] = []
    @Published var pendingAnnotationPoint: CGPoint?  // 2D first-click
    @Published var pendingPolygonPoints: [CGPoint] = []  // 2D area polygon
    @Published var measurementType: MeasurementType = .distance
    @Published var snapEnabled: Bool = true
    /// Active independent annotation tool (text/arrow/dimension). Nil = no tool active.
    @Published var activeAnnotationTool: AnnotationTool?
    /// Text content for text annotation tool.
    @Published var annotationToolText: String = ""

    /// Error message for failed export (shown as alert in UI).
    @Published var exportError: String?

    // Parse progress (stage + fraction)
    @Published var parseStage: String = ""
    @Published var parseProgress: Double = 0  // 0..1
    /// File extension being loaded (for format-aware UI during loading).
    @Published var loadingFileExtension: String = ""

    // Color override state
    @Published var nodeColorOverrides: [Int: simd_float4] = [:]

    // Layer visibility state (for 2D drawings)
    @Published var layerVisibility: [String: Bool] = [:]
    @Published var layerColors: [String: Int] = [:]

    fileprivate(set) var rustDoc: OpaquePointer?
    fileprivate var renderer: MetalRenderer?
    /// Active background parse job (for cancellation).
    fileprivate var currentJob: OpaquePointer?
    /// Active cancellation token.
    fileprivate var currentCancelToken: UnsafeMutableRawPointer?
    /// Stores DTO from async parse when renderer isn't ready yet (full-upload path).
    fileprivate var pendingDTO: RenderPacketDTO?
    /// Stores DTO for deferred streaming upload (late renderer binding).
    fileprivate var pendingStreamingDTO: RenderPacketDTO?
    /// Active streaming Task handle — cancelled on new parse, freeCurrentDocument, deinit.
    fileprivate var streamingTask: Task<Void, Never>?
    /// Increments on each parseFile call; stale async results are discarded.
    /// Also serves as the generation token for DocumentSpatialLease validation.
    internal var parseGeneration: UInt64 = 0
    /// Temp file URL from current/last parse — cleaned up in cancelParse/deinit.
    fileprivate var _parseTmpURL: URL?
    /// If true, forces streaming mode even for small models (testing only).
    var _testForceStreaming = false

    // MARK: - Structure tree acceleration

    /// Pre-built children lookup: parentNodeIndex -> [childIndices].  Built once
    /// after nodes are populated; O(1) lookup replaces O(n) scans in
    /// hasChildren/childrenOf/collectDescendants.
    fileprivate var _childrenMap: [Int: [Int]] = [:]
    /// Pre-built node depth cache: nodeIndex -> tree depth.  Built once
    /// after nodes are populated.
    fileprivate var _nodeDepth: [Int: Int] = [:]
    /// Published snapshot of visible indices.  Rebuilt only when nodes,
    /// expandedIndices, or searchText change.
    @Published var _cachedVisibleIndices: [Int] = []
    /// Lazy-rebuild sentinel: triggers cache recomputation when node count changes.
    private var _lastNodeCount: Int = -1

    /// Whether the current document is a 2D drawing (DXF).
    var is2DDrawing: Bool {
        guard let doc = rustDoc else { return false }
        return RustBridge.shared.is2DDrawing(doc)
    }

    /// 2D drawing metadata (nil if not a 2D drawing).
    var drawing2DInfo: Drawing2DInfo? {
        guard let doc = rustDoc else { return nil }
        return RustBridge.shared.drawing2DInfo(doc)
    }

    /// Fetch draw commands for 2D rendering.
    var drawCommands: [DrawCommandDTO] {
        guard let doc = rustDoc else { return [] }
        return RustBridge.shared.drawCommands(doc)
    }

    /// Generation-guarded spatial query function for 2D viewport culling.
    ///
    /// Returns a closure that safely accesses the spatial index, or `nil` if
    /// no document is loaded or the document is not a 2D drawing.  The closure
    /// checks `parseGeneration` before each query — if the document has been
    /// freed and replaced, the generation won't match and `nil` is returned,
    /// which triggers a full-draw fallback instead of a use-after-free.
    var spatialQueryFunc: ((Double, Double, Double, Double) -> [Int]?)? {
        guard let doc = rustDoc else { return nil }
        let gen = parseGeneration
        return { [weak self] minX, minY, maxX, maxY in
            guard let self, self.parseGeneration == gen else { return nil }
            return RustBridge.shared.spatialQuery(doc, minX: minX, minY: minY,
                                                  maxX: maxX, maxY: maxY)
        }
    }

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func setRenderer(_ renderer: MetalRenderer) {
        self.renderer = renderer
        // Sync current state to the new renderer.
        renderer.renderMode = renderMode
        updateClipPlane()
        // Upload any pending mesh data that arrived before the renderer.
        let fullDTO = pendingDTO
        let streamDTO = pendingStreamingDTO
        pendingDTO = nil
        pendingStreamingDTO = nil
        if let dto = fullDTO {
            uploadToRenderer(dto: dto)
        }
        if let dto = streamDTO {
            startStreamingUpload(dto: dto)
        }
    }

    /// Free the current MmfDocument and clear associated state.
    private func freeCurrentDocument() {
        // Cancel any in-flight background parse.
        // mmf_open_job_free detaches the thread (non-blocking), so the
        // completion callback may still fire.  The generation counter
        // ensures stale callbacks are discarded.
        if let job = currentJob {
            mmf_open_job_free(job)
            currentJob = nil
        }
        if let token = currentCancelToken {
            mmf_cancel_token_free(token)
            currentCancelToken = nil
        }
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
            rustDoc = nil
        }
        pendingDTO = nil
        pendingStreamingDTO = nil
        streamingTask?.cancel()
        streamingTask = nil
        renderer?.clearMeshes()
        renderer?.clearOverlay()
        renderer?.clearSectionFill()
        renderer?.nodeColorOverrides = [:]
        nodeColorOverrides = [:]
        nodeNames = []
        nodes = []
        stats = nil
        selectedIndex = nil
        hiddenNodeIndices = []
        expandedIndices = []
        searchText = ""
        measurementMode = false
        measurements = []
        pendingPoint = nil
        layerVisibility = [:]
        layerColors = [:]
        annotations = []
        pendingAnnotationPoint = nil
        pendingPolygonPoints = []
        loadingFileExtension = ""
        _childrenMap = [:]
        _nodeDepth = [:]
        _cachedVisibleIndices = []
        if let url = _parseTmpURL { try? FileManager.default.removeItem(at: url); _parseTmpURL = nil }
    }

    func parseFile(data: Data, fileExtension: String = "step") {
        // Increment generation — stale results are discarded.
        parseGeneration += 1
        let generation = parseGeneration

        // Clean up previous state first (cancels streaming task, frees Rust doc, clears caches).
        // The generation bump above ensures stale callbacks are discarded.
        freeCurrentDocument()

        guard !data.isEmpty else {
            state = .empty
            return
        }

        state = .loading
        parseStage = ""
        parseProgress = 0

        // Write to temp file with the ORIGINAL extension so Rust format
        // detection works correctly (STL requires .stl, etc.).
        let ext = fileExtension.isEmpty ? "step" : fileExtension
        loadingFileExtension = ext
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmforge_\(UUID().uuidString).\(ext)")
        _parseTmpURL = tmpURL
        do {
            try data.write(to: tmpURL)
        } catch {
            state = .error("Failed to write temp file: \(error.localizedDescription)")
            return
        }

        let path = tmpURL.path

        // Create cancellation token for this parse.
        let cancelToken: UnsafeMutableRawPointer? = mmf_cancel_token_new()
        currentCancelToken = cancelToken

        // Build a context object that the C callbacks can access via user_data.
        // Uses Unmanaged to pass a reference through C void*.
        let ctx = ParseCallbackContext(viewModel: self, generation: generation, tmpURL: tmpURL)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        let job = mmf_open_async(path, UnsafeRawPointer(cancelToken),
                                 parseProgressCallback, parseCompletionCallback, ctxPtr)

        currentJob = job
    }

    deinit {
        streamingTask?.cancel()
        if let job = currentJob {
            mmf_open_job_free(job)
        }
        if let token = currentCancelToken {
            mmf_cancel_token_free(token)
        }
        if let doc = rustDoc {
            RustBridge.shared.freeDocument(doc)
        }
        if let url = _parseTmpURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Async Parse Callbacks (outside DocumentViewModel)

/// Holds context for the async parse C callbacks.
private class ParseCallbackContext {
    weak var viewModel: DocumentViewModel?
    let generation: UInt64
    let tmpURL: URL
    init(viewModel: DocumentViewModel, generation: UInt64, tmpURL: URL) {
        self.viewModel = viewModel
        self.generation = generation
        self.tmpURL = tmpURL
    }
}

private func parseProgressCallback(
    stage: UnsafePointer<CChar>?, current: UInt32, total: UInt32, user_data: UnsafeMutableRawPointer?
) {
    guard let user_data else { return }
    let ctx = Unmanaged<ParseCallbackContext>.fromOpaque(user_data).takeUnretainedValue()
    // Copy the stage string immediately — the pointer is only valid for
    // the duration of this C callback and may be freed before the main
    // thread dispatch block executes.
    let stageCopy = stage.map { String(cString: $0) } ?? ""
    let progress = total > 0 ? Double(current) / Double(total) : 0.0
    DispatchQueue.main.async {
        guard let vm = ctx.viewModel, ctx.generation == vm.parseGeneration else { return }
        vm.parseStage = stageCopy
        vm.parseProgress = progress
    }
}

private func parseCompletionCallback(
    doc: OpaquePointer?, error: UnsafePointer<CChar>?, user_data: UnsafeMutableRawPointer?
) {
    guard let user_data else { return }
    let ctx = Unmanaged<ParseCallbackContext>.fromOpaque(user_data).takeRetainedValue()
    try? FileManager.default.removeItem(at: ctx.tmpURL)
    // Copy the error string immediately — the pointer is only valid for
    // the duration of this C callback.
    let errorCopy = error.map { String(cString: $0) }
    DispatchQueue.main.async {
        guard let vm = ctx.viewModel else {
            if let doc = doc { mmf_document_free(doc) }
            return
        }
        guard ctx.generation == vm.parseGeneration else {
            if let doc = doc { mmf_document_free(doc) }
            return
        }
        // Release background job resources.  The job has finished, but we
        // must still call mmf_open_job_free to release the Rust-side
        // OpenDocumentJob allocation before clearing the Swift handle.
        if let job = vm.currentJob {
            mmf_open_job_free(job)
            vm.currentJob = nil
        }
        if let token = vm.currentCancelToken {
            mmf_cancel_token_free(token)
            vm.currentCancelToken = nil
        }
        if let doc = doc {
            if let oldDoc = vm.rustDoc { RustBridge.shared.freeDocument(oldDoc) }
            vm.rustDoc = doc
            let dto = RustBridge.shared.buildDTO(from: doc)
            vm.nodeNames = dto.nodeNames
            vm.nodes = dto.nodes
            vm.stats = dto.stats
            vm.initLayerState()
            vm.expandedIndices = [0]
            vm.rebuildTreeCaches()

            if vm.shouldStream(dto) {
                vm.uploadStreaming(dto: dto)
            } else {
                vm.uploadToRenderer(dto: dto)
                vm.parseStage = ""
                vm.parseProgress = 1
                vm.state = .loaded(
                    triangleCount: dto.triangleCount, meshCount: dto.meshes.count,
                    nodeCount: dto.nodeNames.count)
            }
        } else {
            vm.state = .error(errorCopy ?? "unknown error")
        }
    }
}

// uploadToRenderer is in an extension because the class body was split
// during refactoring.  `internal` visibility allows access from the class
// body and from the free-function completion callback.

extension DocumentViewModel {
    func uploadToRenderer(dto: RenderPacketDTO) {
        guard let renderer else {
            pendingDTO = dto
            return
        }
        renderer.clearMeshes()

        // Build geometryId → nodeIndex mapping from NodeInfo.
        // This is the authoritative key — geometryId in NodeInfo matches
        // geometryId in Mesh because both come from the same Rust model.
        var geomIdToNodeIdx = [Int: Int]()
        for (nodeIdx, node) in dto.nodes.enumerated() {
            if node.geometryId >= 0 {
                geomIdToNodeIdx[node.geometryId] = nodeIdx
            }
        }

        // Upload each mesh, using mesh.geometryId to find the owning node.
        for mesh in dto.meshes {
            let nodeIdx = geomIdToNodeIdx[mesh.geometryId] ?? -1
            let node = nodeIdx >= 0 && nodeIdx < dto.nodes.count ? dto.nodes[nodeIdx] : nil
            renderer.upload(
                positions: mesh.positions,
                normals: mesh.normals,
                vertexCount: mesh.vertexCount,
                indices: mesh.indices,
                indexCount: mesh.indexCount,
                nodeIndex: nodeIdx,
                boundsMin: node?.boundsMin ?? .zero,
                boundsMax: node?.boundsMax ?? .zero
            )
        }
        renderer.setSceneBounds(min: dto.sceneBoundsMin, max: dto.sceneBoundsMax)

        // If clip plane is active, compute section fill now that meshes are uploaded.
        if clipEnabled {
            renderer.updateSectionFill()
        }
    }

    // MARK: - Streaming / progressive loading

    /// Default chunk budget: 64 MB per chunk.
    static let defaultChunkBudget: UInt32 = 64 * 1024 * 1024

    /// Threshold for switching to streaming mode: models with over 100k
    /// triangles use progressive chunk upload.
    static let streamingTriangleThreshold = 100_000

    /// Whether the model qualifies for streaming (progressive) upload.
    func shouldStream(_ dto: RenderPacketDTO) -> Bool {
        return _testForceStreaming || dto.triangleCount > Self.streamingTriangleThreshold
    }

    /// Enqueue a progressive chunk-based upload.
    ///
    /// If the renderer is not yet bound, caches the DTO in
    /// `pendingStreamingDTO` and resumes when `setRenderer` is called.
    /// If chunking produces zero chunks, falls back to `uploadToRenderer`.
    ///
    /// Uses `Task` + `await Task.yield()` between chunks so that
    /// SwiftUI `parseStage`/`parseProgress` and Metal draw calls can
    /// refresh between chunks.
    func uploadStreaming(dto: RenderPacketDTO) {
        guard let doc = rustDoc else { return }
        guard renderer != nil else {
            pendingStreamingDTO = dto
            parseStage = ""
            parseProgress = 1
            state = .loaded(
                triangleCount: dto.triangleCount,
                meshCount: dto.meshes.count,
                nodeCount: dto.nodeNames.count
            )
            return
        }
        startStreamingUpload(dto: dto)
    }

    /// Internal entry: renderer is guaranteed non-nil.
    private func startStreamingUpload(dto: RenderPacketDTO) {
        guard let renderer, let doc = rustDoc else { return }

        var geomIdToNodeIdx = [Int: Int]()
        for (nodeIdx, node) in dto.nodes.enumerated() where node.geometryId >= 0 {
            geomIdToNodeIdx[node.geometryId] = nodeIdx
        }

        let totalChunks = Int(buildChunks(budgetBytes: Self.defaultChunkBudget))
        guard totalChunks > 0 else {
            uploadToRenderer(dto: dto)
            return
        }

        renderer.clearMeshes()

        // Capture the generation at task creation.  If parseFile() fires a new
        // parse, parseGeneration is bumped and this task will bail out.
        let gen = parseGeneration

        // Cancel any previous streaming task before starting a new one.
        streamingTask?.cancel()

        let task = Task { @MainActor [weak self, gen] in
            guard let self else { return }

            // --- Check that the document is still valid before starting ---
            guard gen == self.parseGeneration,
                  let currentDoc = self.rustDoc,
                  let renderer = self.renderer
            else {
                self.streamingTask = nil
                return
            }

            parseStage = "Uploading meshes..."
            var uploaded = 0

            for ci in 0..<UInt32(totalChunks) {
                // --- Generation guard: bail if a new parse started ---
                guard gen == self.parseGeneration,
                      self.rustDoc != nil,
                      let renderer = self.renderer,
                      !Task.isCancelled
                else {
                    self.streamingTask = nil
                    return
                }

                parseStage = "Uploading meshes (chunk \(ci + 1)/\(totalChunks))..."
                parseProgress = Double(ci) / Double(totalChunks)

                let count = RustBridge.shared.uploadChunk(
                    from: currentDoc, chunkIndex: ci,
                    nodeMap: geomIdToNodeIdx, nodeInfos: dto.nodes,
                    into: renderer
                )
                uploaded += count

                await Task.yield()
            }

            // --- Final guard: don't publish if document changed ---
            guard gen == self.parseGeneration,
                  let renderer = self.renderer,
                  self.rustDoc != nil,
                  !Task.isCancelled
            else {
                self.streamingTask = nil
                return
            }

            renderer.setSceneBounds(min: dto.sceneBoundsMin, max: dto.sceneBoundsMax)
            if clipEnabled { renderer.updateSectionFill() }

            parseStage = ""
            parseProgress = 1
            state = .loaded(
                triangleCount: dto.triangleCount,
                meshCount: uploaded,
                nodeCount: dto.nodeNames.count
            )
            self.streamingTask = nil
        }

        streamingTask = task
    }

    /// Upload a single streaming chunk into the renderer (progressive loading).
    /// Does NOT clear existing meshes — call `clearMeshes()` separately if needed.
    /// The node-map is built once from `nodes` on the first call and reused.
    func uploadChunk(chunkIndex: UInt32, dto: RenderPacketDTO) -> Int {
        guard let renderer, let doc = rustDoc else { return 0 }
        var map = [Int: Int]()
        for (ni, n) in dto.nodes.enumerated() where n.geometryId >= 0 {
            map[n.geometryId] = ni
        }
        return RustBridge.shared.uploadChunk(
            from: doc, chunkIndex: chunkIndex,
            nodeMap: map, nodeInfos: dto.nodes,
            into: renderer
        )
    }

    /// Build streaming chunks for the current document with the given budget.
    /// Returns the number of chunks (calls mmf_build_streaming_packet).
    func buildChunks(budgetBytes: UInt32) -> UInt32 {
        guard let doc = rustDoc else { return 0 }
        return RustBridge.shared.buildChunks(for: doc, budgetBytes: budgetBytes)
    }

    /// Rebuild streaming chunks with a new budget.
    func rebuildChunks(budgetBytes: UInt32) -> UInt32 {
        guard let doc = rustDoc else { return 0 }
        return RustBridge.shared.rebuildChunks(for: doc, budgetBytes: budgetBytes)
    }

    /// Number of streaming chunks (0 if not built).
    func chunkCount() -> UInt32 {
        guard let doc = rustDoc else { return 0 }
        return mmf_chunk_count(doc)
    }

    /// Info for a single chunk.
    func chunkInfo(index: UInt32) -> RenderPacketDTO.ChunkInfo? {
        guard let doc = rustDoc else { return nil }
        return RustBridge.shared.chunkInfo(for: doc, index: index)
    }

    func fitToView() {
        renderer?.fitToView()
    }

    /// Cancel the in-flight parse job.  Resets to empty state.
    ///
    /// Increments parseGeneration so any in-flight completion or progress
    /// callback that fires after this point is discarded as stale.
    func cancelParse() {
        parseGeneration += 1
        if let token = currentCancelToken {
            mmf_cancel_token_cancel(token)
        }
        if let job = currentJob {
            mmf_open_job_cancel(job)
        }
        freeCurrentDocument()
        state = .empty
        parseStage = ""
        parseProgress = 0
    }

    // MARK: - Camera / View

    func setNamedView(_ view: MetalRenderer.NamedView) {
        renderer?.setNamedView(view)
    }

    func toggleProjection() {
        renderer?.toggleProjection()
    }

    func resetCamera() {
        renderer?.resetCamera()
    }

    // MARK: - Selection

    func selectNode(_ index: Int?) {
        selectedIndex = index
        renderer?.setSelectedNode(index)
    }

    // MARK: - Visibility

    func toggleNodeVisibility(_ index: Int) {
        if hiddenNodeIndices.contains(index) {
            hiddenNodeIndices.remove(index)
            renderer?.setNodeVisible(index, visible: true)
        } else {
            hiddenNodeIndices.insert(index)
            renderer?.setNodeVisible(index, visible: false)
        }
        refreshSectionFill()
    }

    func setAllNodesVisible() {
        hiddenNodeIndices.removeAll()
        renderer?.setHiddenNodes([])
        refreshSectionFill()
    }

    /// Hide the selected node and all its descendant geometry.
    /// Works for both leaf geometry nodes and assembly nodes.
    func hideSelectedNode() {
        guard let sel = selectedIndex else { return }
        var descendants = Set<Int>()
        collectDescendants(sel, into: &descendants)
        for idx in descendants where nodes[idx].hasGeometry {
            hiddenNodeIndices.insert(idx)
        }
        renderer?.setHiddenNodes(hiddenNodeIndices)
        refreshSectionFill()
    }

    /// Hide all geometry nodes.
    func hideAllNodes() {
        let geomIndices = nodes.enumerated()
            .filter { $0.element.hasGeometry }
            .map { $0.offset }
        hiddenNodeIndices = Set(geomIndices)
        renderer?.setHiddenNodes(hiddenNodeIndices)
        refreshSectionFill()
    }

    /// Isolate the selected node: show it and all its descendants,
    /// hide all other geometry nodes.
    func isolateSelectedNode() {
        guard let sel = selectedIndex, selectedHasHideableGeometry else { return }
        var keepVisible = Set<Int>()
        collectDescendants(sel, into: &keepVisible)
        var hidden = Set<Int>()
        for (i, node) in nodes.enumerated() {
            if node.hasGeometry && !keepVisible.contains(i) {
                hidden.insert(i)
            }
        }
        hiddenNodeIndices = hidden
        renderer?.setHiddenNodes(hiddenNodeIndices)
        refreshSectionFill()
    }

    /// Isolate a specific node by index.
    func isolateNode(_ index: Int) {
        selectNode(index)
        var keepVisible = Set<Int>()
        collectDescendants(index, into: &keepVisible)
        var hidden = Set<Int>()
        for (i, node) in nodes.enumerated() {
            if node.hasGeometry && !keepVisible.contains(i) {
                hidden.insert(i)
            }
        }
        hiddenNodeIndices = hidden
        renderer?.setHiddenNodes(hiddenNodeIndices)
        refreshSectionFill()
    }

    /// Hide all geometry nodes except the given one.
    func hideAllExcept(_ index: Int) {
        var hidden = Set<Int>()
        for (i, node) in nodes.enumerated() {
            if node.hasGeometry && i != index {
                hidden.insert(i)
            }
        }
        hiddenNodeIndices = hidden
        renderer?.setHiddenNodes(hiddenNodeIndices)
        refreshSectionFill()
    }

    /// Expand a node and all its descendants in the tree.
    func expandDescendants(_ index: Int) {
        var toExpand = Set<Int>()
        collectDescendants(index, into: &toExpand)
        for i in toExpand where hasChildren(i) {
            expandedIndices.insert(i)
        }
        refreshVisibleIndices()
    }

    /// Collapse a node and all its descendants in the tree.
    func collapseDescendants(_ index: Int) {
        var toCollapse = Set<Int>()
        collectDescendants(index, into: &toCollapse)
        expandedIndices.subtract(toCollapse)
        refreshVisibleIndices()
    }

    /// Hide all nodes except the selected one (alias for toolbar).
    func hideOtherNodes() {
        isolateSelectedNode()
    }

    /// Recursively collect a node and all its descendants — uses children map.
    private func collectDescendants(_ index: Int, into set: inout Set<Int>) {
        set.insert(index)
        for child in childrenOf(index) {
            collectDescendants(child, into: &set)
        }
    }

    /// Recalculate section fill if clip plane is active.
    private func refreshSectionFill() {
        if clipEnabled {
            renderer?.updateSectionFill()
        }
    }

    /// Whether the selected node (or its descendants) has any geometry
    /// that can be hidden.
    var selectedHasHideableGeometry: Bool {
        guard let sel = selectedIndex else { return false }
        var descendants = Set<Int>()
        collectDescendants(sel, into: &descendants)
        return descendants.contains { nodes[$0].hasGeometry }
    }

    // MARK: - Layer Visibility (2D drawings)

    /// Initialize layer state from parsed drawing info.
    func initLayerState() {
        guard let info = drawing2DInfo else { return }
        var vis: [String: Bool] = [:]
        var colors: [String: Int] = [:]
        for layer in info.layers {
            vis[layer.name] = layer.visible
            colors[layer.name] = layer.colorIndex
        }
        layerVisibility = vis
        layerColors = colors
    }

    /// Toggle visibility for a specific layer.
    func toggleLayerVisibility(_ layerName: String) {
        let current = layerVisibility[layerName] ?? true
        layerVisibility[layerName] = !current
    }

    // MARK: - Measurement

    /// Toggle measurement mode.  When active, viewport clicks pick
    /// world-space points instead of nodes.
    func toggleMeasurementMode() {
        measurementMode.toggle()
        if !measurementMode {
            pendingPoint = nil
            pendingAnnotationPoint = nil
            pendingPolygonPoints = []
        }
        syncOverlay()
    }

    // MARK: - 2D Annotation Actions

    /// Add a 2D distance measurement annotation.
    func add2DMeasurement(start: CGPoint, end: CGPoint) {
        let dist = Geometry2D.distance(start, end)
        let label = String(format: "%.2f", dist)
        annotations.append(Annotation(
            kind: .measurement(start: start, end: end),
            color: .systemYellow))
        pendingAnnotationPoint = nil
    }

    /// Add a 2D angle measurement annotation.
    func add2DAngleMeasurement(vertex: CGPoint, p1: CGPoint, p2: CGPoint) {
        annotations.append(Annotation(
            kind: .angleMeasurement(vertex: vertex, p1: p1, p2: p2),
            color: .systemGreen))
        pendingAnnotationPoint = nil
        pendingPolygonPoints = []
    }

    /// Add a 2D area measurement annotation from polygon points.
    func add2DAreaMeasurement(points: [CGPoint]) {
        guard points.count >= 3 else { return }
        annotations.append(Annotation(
            kind: .areaMeasurement(points: points),
            color: .systemBlue))
        pendingPolygonPoints = []
        pendingAnnotationPoint = nil
    }

    /// Add a text annotation.
    func addTextAnnotation(position: CGPoint, text: String, fontSize: CGFloat = 14) {
        annotations.append(Annotation(
            kind: .textAnnotation(position: position, text: text, fontSize: fontSize),
            color: .white))
    }

    /// Add an arrow annotation.
    func addArrowAnnotation(tail: CGPoint, head: CGPoint, text: String? = nil) {
        annotations.append(Annotation(
            kind: .arrowAnnotation(tail: tail, head: head, text: text),
            color: .systemOrange))
    }

    /// Add a dimension annotation.
    func addDimensionAnnotation(start: CGPoint, end: CGPoint, offset: CGFloat = 20) {
        annotations.append(Annotation(
            kind: .dimension(start: start, end: end, offset: offset),
            color: .systemYellow))
    }

    /// Remove a single annotation by ID.
    func removeAnnotation(_ id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    /// Clear all annotations.
    func clearAnnotations() {
        annotations.removeAll()
        pendingAnnotationPoint = nil
        pendingPolygonPoints = []
        syncOverlay()
    }

    /// Record a measurement point.  First click stores pending point,
    /// second click creates a Measurement.
    func addMeasurementPoint(_ point: simd_float3) {
        if let start = pendingPoint {
            measurements.append(Measurement(start: start, end: point))
            pendingPoint = nil
        } else {
            pendingPoint = point
        }
        syncOverlay()
    }

    /// Cancel the current pending measurement.
    func cancelMeasurement() {
        pendingPoint = nil
        syncOverlay()
    }

    /// Clear all measurements.
    func clearMeasurements() {
        measurements.removeAll()
        pendingPoint = nil
        syncOverlay()
    }

    /// Remove a single measurement by ID.
    func removeMeasurement(_ id: UUID) {
        measurements.removeAll { $0.id == id }
        syncOverlay()
    }

    /// Sync measurement data to the Metal renderer overlay.
    private func syncOverlay() {
        guard let renderer else { return }
        if measurements.isEmpty && pendingPoint == nil {
            renderer.clearOverlay()
        } else {
            let overlayData = measurements.map { (start: $0.start, end: $0.end) }
            renderer.updateOverlay(measurements: overlayData, pendingPoint: pendingPoint)
        }
    }

    // MARK: - Color Override

    /// Set a color override for a node.  Pass nil to reset to default.
    func setNodeColor(_ index: Int, color: simd_float4?) {
        if let color {
            nodeColorOverrides[index] = color
        } else {
            nodeColorOverrides.removeValue(forKey: index)
        }
        renderer?.nodeColorOverrides = nodeColorOverrides
    }

    /// Reset color for the selected node.
    func resetSelectedNodeColor() {
        if let idx = selectedIndex {
            setNodeColor(idx, color: nil)
        }
    }

    /// Reset all color overrides.
    func resetAllColors() {
        nodeColorOverrides.removeAll()
        renderer?.nodeColorOverrides = [:]
    }

    // MARK: - Export

    /// Capture the current viewport and present NSSavePanel for export.
    func exportImage() {
        guard let renderer else {
            exportError = "No renderer available."
            return
        }
        guard let image = renderer.captureImage() else {
            exportError = "Failed to capture viewport — no drawable available."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "mmforge_view.\(AppPreferences.exportFormat)"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.saveImage(image, to: url)
        }
    }

    private func saveImage(_ image: NSImage, to url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            exportError = "Failed to encode image data."
            return
        }

        let isPNG = url.pathExtension.lowercased() == "png"
        guard let imageData = isPNG
            ? bitmapRep.representation(using: .png, properties: [:])
            : bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else {
            exportError = "Failed to encode image as \(isPNG ? "PNG" : "JPEG")."
            return
        }

        do {
            try imageData.write(to: url)
        } catch {
            exportError = "Failed to write image: \(error.localizedDescription)"
        }
    }

    /// Export the current view as a PDF.
    ///
    /// - 2D drawings: vector PDF with the same rendering pipeline as the screen.
    /// - 3D models: raster snapshot of the Metal viewport embedded in a PDF page.
    func exportPDF() {
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = is2DDrawing ? "mmforge_drawing.pdf" : "mmforge_model.pdf"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if self.is2DDrawing {
                self.exportPDFToFile(url: url)
            } else {
                self.export3DPDFToFile(url: url)
            }
        }
    }

    private func exportPDFToFile(url: URL) {
        guard let doc = rustDoc else {
            exportError = "No document loaded."
            return
        }

        let bounds = RustBridge.shared.drawing2DInfo(doc)
        guard let info = bounds,
              info.boundsMaxX > info.boundsMinX,
              info.boundsMaxY > info.boundsMinY else {
            exportError = "Invalid drawing bounds."
            return
        }

        let wb = CGRect(
            x: info.boundsMinX, y: info.boundsMinY,
            width: info.boundsMaxX - info.boundsMinX,
            height: info.boundsMaxY - info.boundsMinY)

        let pageW: CGFloat = 842  // A4 landscape
        let pageH: CGFloat = 595
        let margin: CGFloat = 36

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            exportError = "Failed to create PDF data consumer."
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            exportError = "Failed to create PDF context."
            return
        }

        // Reuse the same rendering pipeline as the screen view.
        Drawing2DView.renderPDF(
            ctx: pdfCtx,
            commands: drawCommands,
            annotations: annotations,
            layerVisibility: layerVisibility,
            worldBounds: wb,
            pageWidth: pageW,
            pageHeight: pageH,
            margin: margin)

        pdfCtx.closePDF()
    }

    /// Export a 3D model as a PDF with a raster snapshot of the current viewport.
    private func export3DPDFToFile(url: URL) {
        guard let renderer else {
            exportError = "No renderer available."
            return
        }
        guard let image = renderer.captureImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            exportError = "Failed to capture viewport."
            return
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // A4 landscape, fit image with margin.
        let pageW: CGFloat = 842
        let pageH: CGFloat = 595
        let margin: CGFloat = 36
        let drawW = pageW - margin * 2
        let drawH = pageH - margin * 2
        let scaleX = drawW / imgW
        let scaleY = drawH / imgH
        let scale = min(scaleX, scaleY)
        let renderW = imgW * scale
        let renderH = imgH * scale
        let originX = margin + (drawW - renderW) / 2
        let originY = margin + (drawH - renderH) / 2

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            exportError = "Failed to create PDF data consumer."
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            exportError = "Failed to create PDF context."
            return
        }

        pdfCtx.beginPDFPage(nil)
        pdfCtx.saveGState()

        // PDF origin is bottom-left; draw image with origin at top-left.
        pdfCtx.translateBy(x: originX, y: pageH - originY - renderH)
        pdfCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: renderW, height: renderH))

        pdfCtx.restoreGState()
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()
    }

    // MARK: - Tree expand/collapse

    /// Toggle expand/collapse for a node.
    func toggleExpanded(_ index: Int) {
        if expandedIndices.contains(index) {
            expandedIndices.remove(index)
        } else {
            expandedIndices.insert(index)
        }
        refreshVisibleIndices()
    }

    /// Expand all nodes.
    func expandAll() {
        expandedIndices = Set(nodes.indices)
        refreshVisibleIndices()
    }

    /// Collapse all nodes.
    func collapseAll() {
        expandedIndices = []
        refreshVisibleIndices()
    }

    /// Rebuild children map and depth cache after nodes change.
    /// Must be called whenever `nodes` is populated or mutated.
    func rebuildTreeCaches() {
        var cmap: [Int: [Int]] = [:]
        var depth: [Int: Int] = [:]
        for (i, node) in nodes.enumerated() {
            let p = node.parentIndex
            if p >= 0 {
                cmap[p, default: []].append(i)
            }
        }
        // Cursor-based BFS to compute depth in one pass (avoids O(n) removeFirst).
        var queue: [Int] = nodes.indices.filter { nodes[$0].parentIndex < 0 }
        for root in queue { depth[root] = 0 }
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let d = depth[cur]!
            for child in cmap[cur] ?? [] {
                depth[child] = d + 1
                queue.append(child)
            }
        }
        _childrenMap = cmap
        _nodeDepth = depth
        _lastNodeCount = nodes.count
        refreshVisibleIndices()
    }

    /// Recompute _cachedVisibleIndices from current search/expand state.
    /// Uses DFS preorder to produce stable depth-first order matching
    /// the structure tree expectation: Root → A → A1 → B (not BFS).
    func refreshVisibleIndices() {
        guard !nodes.isEmpty else { _cachedVisibleIndices = []; return }
        if searchText.isEmpty {
            // DFS preorder via cursor-based stack.
            var result: [Int] = []
            let roots = nodes.indices.filter { nodes[$0].parentIndex < 0 }
            // Push roots in reverse so first root is processed first (stack LIFO).
            var stack: [Int] = roots.reversed()
            while !stack.isEmpty {
                let i = stack.removeLast()
                result.append(i)
                if expandedIndices.contains(i), let kids = _childrenMap[i] {
                    // Push children in reverse index order so lower indices
                    // are processed first (preorder).
                    stack.append(contentsOf: kids.reversed())
                }
            }
            _cachedVisibleIndices = result
        } else {
            var visible = Set<Int>()
            for i in nodes.indices where matchesSearch(i) {
                visible.insert(i)
                var p = nodes[i].parentIndex
                while p >= 0 {
                    visible.insert(p)
                    p = nodes[p].parentIndex
                }
            }
            _cachedVisibleIndices = nodes.indices.filter { visible.contains($0) }
        }
    }

    /// Whether a node's children should be visible in the tree.
    /// Uses cached depth: a node is visible (outside search mode) if its
    /// ancestor chain is all expanded up to root.
    func isNodeVisibleInTree(_ index: Int) -> Bool {
        let node = nodes[index]
        guard node.parentIndex >= 0 else { return true }
        var cur = node.parentIndex
        while cur >= 0 {
            if !expandedIndices.contains(cur) { return false }
            cur = nodes[cur].parentIndex
        }
        return true
    }

    /// Whether a node passes the search filter.
    func matchesSearch(_ index: Int) -> Bool {
        guard !searchText.isEmpty else { return true }
        let node = nodes[index]
        if node.name.localizedCaseInsensitiveContains(searchText) { return true }
        if let label = node.geometryLabel,
           label.localizedCaseInsensitiveContains(searchText) { return true }
        return false
    }

    /// Cached visible indices.  Read-only from SwiftUI; rebuild triggered
    /// explicitly via refreshVisibleIndices() or rebuildTreeCaches().
    var visibleNodeIndices: [Int] {
        _cachedVisibleIndices
    }

    /// O(1) children lookup.  Lazily rebuilds caches if nodes changed.
    func childrenOf(_ index: Int) -> [Int] {
        _rebuildIfNodesChanged()
        return _childrenMap[index] ?? []
    }

    /// O(1) has-children check.  Lazily rebuilds caches if nodes changed.
    func hasChildren(_ index: Int) -> Bool {
        _rebuildIfNodesChanged()
        return _childrenMap[index] != nil
    }

    /// O(1) depth lookup.  Returns 0 for roots or uncached nodes.
    func nodeDepth(_ index: Int) -> Int {
        _rebuildIfNodesChanged()
        return _nodeDepth[index] ?? 0
    }

    /// Dirty flag: lazily rebuilds caches when nodes change.
    private func _rebuildIfNodesChanged() {
        if nodes.count != _lastNodeCount {
            rebuildTreeCaches()
            _lastNodeCount = nodes.count
        }
    }

    func setRenderMode(_ mode: RenderMode) {
        renderMode = mode
        renderer?.renderMode = mode
        AppPreferences.renderMode = mode.rawValue
    }

    // MARK: - Clipping Plane

    func setClipEnabled(_ enabled: Bool) {
        clipEnabled = enabled
        updateClipPlane()
    }

    func setClipAxis(_ axis: Int) {
        clipAxis = axis
        updateClipPlane()
    }

    func setClipDistance(_ distance: Float) {
        clipDistance = distance
        updateClipPlane()
    }

    func toggleClipping() {
        clipEnabled.toggle()
        updateClipPlane()
    }

    private func updateClipPlane() {
        guard let renderer else { return }
        if clipEnabled {
            var normal: simd_float3
            switch clipAxis {
            case 0: normal = simd_float3(1, 0, 0)
            case 1: normal = simd_float3(0, 1, 0)
            default: normal = simd_float3(0, 0, 1)
            }
            renderer.clipPlane = simd_float4(normal.x, normal.y, normal.z, clipDistance)
            renderer.updateSectionFill()
        } else {
            renderer.clipPlane = simd_float4(0, 0, 0, -999999)
            renderer.clearSectionFill()
        }
    }

}

// MARK: - Drawing2D Annotation Delegate

extension DocumentViewModel: Drawing2DAnnotationDelegate {
    func didCompleteMeasurement(start: CGPoint, end: CGPoint) {
        add2DMeasurement(start: start, end: end)
    }

    func didCompleteAngleMeasurement(vertex: CGPoint, p1: CGPoint, p2: CGPoint) {
        add2DAngleMeasurement(vertex: vertex, p1: p1, p2: p2)
    }

    func didCompleteAreaMeasurement(points: [CGPoint]) {
        add2DAreaMeasurement(points: points)
    }

    func didSetPendingPoint(_ point: CGPoint) {
        pendingAnnotationPoint = point
    }

    func didSetPendingAngleVertex(_ point: CGPoint) {
        pendingPolygonPoints = [point]
        pendingAnnotationPoint = point
    }

    func didSetPendingAngleRay(_ point: CGPoint) {
        pendingPolygonPoints.append(point)
    }

    func didAddPolygonPoint(_ point: CGPoint) {
        pendingPolygonPoints.append(point)
        pendingAnnotationPoint = point
    }

    func didCancelPending() {
        pendingAnnotationPoint = nil
        pendingPolygonPoints = []
    }

    func didPlaceTextAnnotation(at position: CGPoint, text: String) {
        guard !text.isEmpty else { return }
        addTextAnnotation(position: position, text: text)
    }

    func didCompleteArrowAnnotation(tail: CGPoint, head: CGPoint) {
        addArrowAnnotation(tail: tail, head: head)
        pendingAnnotationPoint = nil
    }

    func didCompleteDimensionAnnotation(start: CGPoint, end: CGPoint) {
        addDimensionAnnotation(start: start, end: end)
        pendingAnnotationPoint = nil
    }
}
