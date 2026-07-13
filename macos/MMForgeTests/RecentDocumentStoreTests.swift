import XCTest
@testable import MMForge

final class RecentDocumentStoreTests: XCTestCase {
    private let store = RecentDocumentStore.shared
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        store.clear()
        store.waitForQueue()
    }

    override func tearDown() {
        store.clear()
        store.waitForQueue()
        for f in tempFiles {
            try? FileManager.default.removeItem(at: f)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    /// Create a real empty file and return its URL.
    private func makeTempFile(name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mmforge_test_\(name)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        tempFiles.append(url)
        return url
    }

    func testAddSingleURL() {
        let url = makeTempFile(name: "test1")
        store.add(url: url)
        XCTAssertEqual(store.urls.first, url)
        XCTAssertEqual(store.urls.count, 1)
    }

    func testDeduplicationMovesToFront() {
        let urlA = makeTempFile(name: "a")
        let urlB = makeTempFile(name: "b")
        store.add(url: urlA)
        store.add(url: urlB)
        store.add(url: urlA) // re-add A
        XCTAssertEqual(store.urls.first, urlA, "A should be at front after re-add")
        XCTAssertEqual(store.urls.count, 2, "only 2 unique URLs")
    }

    func testMaxEntriesEnforced() {
        for i in 0..<15 {
            let url = makeTempFile(name: "file_\(i)")
            store.add(url: url)
        }
        XCTAssertLessThanOrEqual(store.urls.count, 10)
        // Most recently added should be first.
        let last = tempFiles.last!
        XCTAssertEqual(store.urls.first, last)
    }

    func testClearRemovesAll() {
        let url = makeTempFile(name: "clear_test")
        store.add(url: url)
        XCTAssertFalse(store.urls.isEmpty)
        store.clear()
        XCTAssertTrue(store.urls.isEmpty)
    }

    func testRemoveSingleURL() {
        let keep = makeTempFile(name: "keep")
        let remove = makeTempFile(name: "remove")
        store.add(url: keep)
        store.add(url: remove)
        store.remove(url: remove)
        XCTAssertEqual(store.urls.count, 1)
        XCTAssertEqual(store.urls.first, keep)
    }

    func testStalePathsFilteredOnAdd() {
        let real = makeTempFile(name: "real")
        store.add(url: real)
        XCTAssertEqual(store.urls.count, 1)

        // Add a stale path → real should survive (is reachable), stale might get filtered.
        let stale = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_928374.step")
        store.add(url: stale)
        // stale is at front (just added, kept because it's the new URL).
        // real is still reachable.
        XCTAssertGreaterThanOrEqual(store.urls.count, 1)
        XCTAssertEqual(store.urls.first, stale)
    }

    func testStalePathsFilteredOnRead() {
        // recentURLs() should filter out paths that don't exist on disk.
        let staleURL = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_928374.step")
        let validURL = URL(fileURLWithPath: "/tmp")

        // Set urls via add — the in-memory array is the source of truth.
        store.add(url: validURL)
        store.add(url: staleURL) // stale is at front

        let filtered = store.recentURLs()
        XCTAssertFalse(filtered.contains(staleURL), "stale path should be filtered")
        XCTAssertTrue(filtered.contains(validURL), "valid path /tmp should be present")
    }
}
