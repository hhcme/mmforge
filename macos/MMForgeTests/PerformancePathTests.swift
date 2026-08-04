import XCTest
import Combine
import Metal
import MetalKit
import simd
@testable import MMForge

// MARK: - Performance-Path Regression Tests

/// Covers the loading-path optimizations:
/// 1. BVH is built on background tasks — upload returns immediately, the
///    main thread never blocks, and picking skips not-yet-ready meshes
///    instead of crashing or hitting stale data.
/// 2. The LSM disk cache is actually used: first parse writes an entry,
///    a second parse of the same source loads it (fast path) and yields
///    identical render data.
final class PerformancePathTests: XCTestCase {

    /// Minimal valid ASCII STL content.
    private var validSTLData: Data {
        let stl = """
        solid test
         facet normal 0 0 1
          outer loop
           vertex 0 0 0
           vertex 1 0 0
           vertex 0 1 0
          endloop
         endfacet
        endsolid test
        """
        return Data(stl.utf8)
    }

    private func makeRenderer() throws -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(mtkView: view) else {
            throw NSError(domain: "MMForgeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to create MetalRenderer"])
        }
        return renderer
    }

    private func triangleData(offsetX: Float = 0) -> (pos: [Float], nrm: [Float], idx: [UInt32]) {
        let verts: [Float] = [
            -0.5 + offsetX, -0.5, 0,  0, 0, 1,
             0.5 + offsetX, -0.5, 0,  0, 0, 1,
             0.0 + offsetX,  0.5, 0,  0, 0, 1,
        ]
        var pos: [Float] = []
        var nrm: [Float] = []
        for v in 0..<3 {
            pos.append(verts[v * 6])
            pos.append(verts[v * 6 + 1])
            pos.append(verts[v * 6 + 2])
            nrm.append(verts[v * 6 + 3])
            nrm.append(verts[v * 6 + 4])
            nrm.append(verts[v * 6 + 5])
        }
        return (pos, nrm, [0, 1, 2])
    }

    // MARK: - BVH background build

    /// Immediately after upload the BVH may still be building; picking must
    /// not crash.  After waiting, the BVH is attached and picking hits.
    @MainActor
    func testBVH_buildsOnBackgroundTask_andPickingWorksAfterWait() async throws {
        let renderer = try makeRenderer()
        let tri = triangleData()

        tri.pos.withUnsafeBufferPointer { p in
            tri.nrm.withUnsafeBufferPointer { n in
                renderer.upload(
                    positions: p.baseAddress!, normals: n.baseAddress!,
                    vertexCount: 3, indices: tri.idx, indexCount: 3,
                    nodeIndex: 0,
                    boundsMin: simd_float3(-1, -1, -1),
                    boundsMax: simd_float3(1, 1, 1))
            }
        }
        renderer.setSceneBounds(min: simd_float3(-1, -1, -1), max: simd_float3(1, 1, 1))
        renderer.resetCamera()

        // Immediately after upload: picking must be safe even if the BVH
        // has not finished building (empty nodes → skipped).
        _ = renderer.pickNode(at: CGSize(width: 200, height: 200), point: CGPoint(x: 100, y: 100))

        let finished = await renderer.waitForPendingBVHBuilds()
        XCTAssertTrue(finished, "BVH builds must complete within timeout")

        let meshes = renderer.getGPUMeshes()
        XCTAssertEqual(meshes.count, 1, "exactly one mesh uploaded")
        XCTAssertFalse(meshes[0].bvh.nodes.isEmpty, "BVH must be attached after wait")

        // Grid scan for a guaranteed hit (same strategy as the acceptance test).
        let viewSize = CGSize(width: 200, height: 200)
        var hit: Int? = nil
        scan: for y in stride(from: 20.0, through: 180.0, by: 20.0) {
            for x in stride(from: 20.0, through: 180.0, by: 20.0) {
                if let h = renderer.pickNode(at: viewSize, point: CGPoint(x: x, y: y)) {
                    hit = h
                    break scan
                }
            }
        }
        XCTAssertEqual(hit, 0, "grid scan must hit the uploaded triangle node")
    }

    /// Uploading into the same renderer twice must not let a stale BVH
    /// from the first upload attach to the second mesh list.
    @MainActor
    func testBVH_generationGuard_discardsStaleBuilds() async throws {
        let renderer = try makeRenderer()

        // First upload round.
        let tri1 = triangleData(offsetX: 0)
        tri1.pos.withUnsafeBufferPointer { p in
            tri1.nrm.withUnsafeBufferPointer { n in
                renderer.upload(
                    positions: p.baseAddress!, normals: n.baseAddress!,
                    vertexCount: 3, indices: tri1.idx, indexCount: 3,
                    nodeIndex: 1,
                    boundsMin: simd_float3(-1, -1, -1),
                    boundsMax: simd_float3(1, 1, 1))
            }
        }
        // Immediately clear (simulates opening a new document before the
        // background build finished) — bumps meshGeneration.
        renderer.clearMeshes()

        // Second upload round.
        let tri2 = triangleData(offsetX: 10)
        tri2.pos.withUnsafeBufferPointer { p in
            tri2.nrm.withUnsafeBufferPointer { n in
                renderer.upload(
                    positions: p.baseAddress!, normals: n.baseAddress!,
                    vertexCount: 3, indices: tri2.idx, indexCount: 3,
                    nodeIndex: 2,
                    boundsMin: simd_float3(9, -1, -1),
                    boundsMax: simd_float3(11, 1, 1))
            }
        }

        let finished = await renderer.waitForPendingBVHBuilds()
        XCTAssertTrue(finished, "BVH builds must complete within timeout")

        let meshes = renderer.getGPUMeshes()
        XCTAssertEqual(meshes.count, 1, "only the second upload survives")
        XCTAssertEqual(meshes[0].nodeIndex, 2, "stale mesh must not survive clearMeshes")
        XCTAssertFalse(meshes[0].bvh.nodes.isEmpty, "second upload's BVH must be built")
    }

    // MARK: - Disk cache write + read

    /// First parse (cold cache) writes an entry; a second parse of the
    /// same source loads from the cache and produces identical render data.
    @MainActor
    func testDiskCache_secondParseLoadsCachedModel() throws {
        ModelCache.shared.clear()
        defer { ModelCache.shared.clear() }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmforge_cache_test_\(UUID().uuidString).stl")
        try validSTLData.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // ── First parse: cold cache → full parse → background cache write ──
        let vm1 = DocumentViewModel()
        let exp1 = expectation(description: "first parse loads")
        var state1: DocumentState = .empty
        let c1 = vm1.$state
            .filter { s in if case .loaded = s { return true }; if case .error = s { return true }; return false }
            .first()
            .sink { state1 = $0; exp1.fulfill() }
        vm1.parseSourceURL = tmpURL
        vm1.parseFile(data: validSTLData, fileExtension: "stl")
        wait(for: [exp1], timeout: 20.0)
        c1.cancel()
        guard case .loaded = state1 else {
            XCTFail("first parse must load, got \(state1)"); return
        }
        let firstNames = vm1.nodeNames
        let firstStats = vm1.stats

        // ── Wait for the background cache write to land ──
        // Key must match what parseFile computes (parser version from Rust).
        let key = ModelCache.shared.cacheKey(
            for: tmpURL, parserVersion: RustBridge.shared.cacheVersion())
        XCTAssertNotNil(key, "cache key must compute")
        let cacheAppeared = waitForCacheEntry(key: key!, timeout: 10.0)
        XCTAssertTrue(cacheAppeared, "first parse must write a cache entry")

        // ── Second parse: warm cache → fast path ──
        let vm2 = DocumentViewModel()
        let exp2 = expectation(description: "second parse loads")
        var state2: DocumentState = .empty
        let c2 = vm2.$state
            .filter { s in if case .loaded = s { return true }; if case .error = s { return true }; return false }
            .first()
            .sink { state2 = $0; exp2.fulfill() }
        vm2.parseSourceURL = tmpURL
        vm2.parseFile(data: validSTLData, fileExtension: "stl")
        wait(for: [exp2], timeout: 20.0)
        c2.cancel()
        guard case .loaded = state2 else {
            XCTFail("second parse must load, got \(state2)"); return
        }

        XCTAssertEqual(vm2.nodeNames, firstNames, "node tree must survive the cache round-trip")
        XCTAssertEqual(vm2.stats?.meshCount, firstStats?.meshCount,
                       "mesh count must survive the cache round-trip")
        XCTAssertEqual(vm2.stats?.triangleCount, firstStats?.triangleCount,
                       "triangle count must survive the cache round-trip")
    }

    /// Poll `ModelCache.load` until a non-nil entry appears (background write).
    private func waitForCacheEntry(key: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ModelCache.shared.load(key: key) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    // MARK: - Re-parse (force) + cache versioning

    /// Bumping the parser version must change the cache key — this is what
    /// invalidates all cached entries after a parser change.
    func testCacheKey_parserVersionChange_invalidatesKey() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmforge_key_test_\(UUID().uuidString).stl")
        try validSTLData.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let keyV1 = ModelCache.shared.cacheKey(for: tmpURL, parserVersion: "cache-v1")
        let keyV2 = ModelCache.shared.cacheKey(for: tmpURL, parserVersion: "cache-v2")
        XCTAssertNotNil(keyV1)
        XCTAssertNotNil(keyV2)
        XCTAssertNotEqual(keyV1, keyV2,
                          "bumping the parser version must change the cache key")
    }

    /// The app's cache version comes from the Rust core — it must be a
    /// non-empty, stable tag (not the plain crate version fallback).
    @MainActor
    func testCacheVersion_comesFromRustCore() {
        let v = RustBridge.shared.cacheVersion()
        XCTAssertFalse(v.isEmpty, "cache version must not be empty")
        XCTAssertTrue(v.hasPrefix("cache-v"), "unexpected cache version: \(v)")
    }

    /// Force re-parse (Re-parse Document): bypasses the cache read, still
    /// loads, yields identical render data, and refreshes the cached entry.
    @MainActor
    func testForceReparse_refreshesCachedModel() throws {
        ModelCache.shared.clear()
        defer { ModelCache.shared.clear() }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmforge_reparse_test_\(UUID().uuidString).stl")
        try validSTLData.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // ── Normal parse: fills the cache ──
        let vm1 = DocumentViewModel()
        let exp1 = expectation(description: "initial parse")
        var state1: DocumentState = .empty
        let c1 = vm1.$state
            .filter { s in if case .loaded = s { return true }; if case .error = s { return true }; return false }
            .first()
            .sink { state1 = $0; exp1.fulfill() }
        vm1.parseSourceURL = tmpURL
        vm1.parseFile(data: validSTLData, fileExtension: "stl")
        wait(for: [exp1], timeout: 20.0)
        c1.cancel()
        guard case .loaded = state1 else {
            XCTFail("initial parse must load, got \(state1)"); return
        }
        let firstNames = vm1.nodeNames
        let firstStats = vm1.stats

        // Key must match what parseFile computes (parser version from Rust).
        let key = ModelCache.shared.cacheKey(
            for: tmpURL, parserVersion: RustBridge.shared.cacheVersion())
        XCTAssertNotNil(key)
        XCTAssertTrue(waitForCacheEntry(key: key!, timeout: 10.0),
                      "initial parse must write a cache entry")

        // ── Force re-parse: must still load with identical data ──
        // dropFirst: at subscription time state is already .loaded from the
        // initial parse — we only want the *next* state change.
        let exp2 = expectation(description: "force re-parse")
        var state2: DocumentState = .empty
        let c2 = vm1.$state
            .dropFirst()
            .filter { s in if case .loaded = s { return true }; if case .error = s { return true }; return false }
            .first()
            .sink { state2 = $0; exp2.fulfill() }
        vm1.reparseDocument()
        wait(for: [exp2], timeout: 30.0)
        c2.cancel()

        guard case .loaded = state2 else {
            XCTFail("force re-parse must load, got \(state2)"); return
        }
        // Node names embed the temp-file basename (a per-parse UUID), so
        // compare stable parts: the first node and the geometry stats.
        XCTAssertEqual(vm1.nodeNames.first, firstNames.first,
                       "force re-parse must produce the same root node")
        XCTAssertEqual(vm1.stats?.meshCount, firstStats?.meshCount,
                       "force re-parse must produce the same mesh count")
        XCTAssertEqual(vm1.stats?.triangleCount, firstStats?.triangleCount,
                       "force re-parse must produce the same triangle count")
        XCTAssertNotNil(ModelCache.shared.load(key: key!),
                        "force re-parse must leave a cache entry (overwritten)")
    }
}
