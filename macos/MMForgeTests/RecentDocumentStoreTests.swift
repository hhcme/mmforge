import XCTest
@testable import MMForge

@MainActor
final class RecentDocumentStoreTests: XCTestCase {
    private var store: RecentDocumentStore!
    private var suite: UserDefaults!
    private var suiteName: String!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        // Each test gets an isolated UserDefaults suite, simulating a fresh
        // launch without polluting UserDefaults.standard.
        suiteName = "com.mmforge.test_\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        store = RecentDocumentStore(userDefaults: suite)
    }

    override func tearDown() {
        store.clear()
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        suite = nil
        suiteName = nil
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

    // MARK: - Existing tests (adapted for isolated UserDefaults)

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

        // Adding a stale URL — add() now cleans unreachable entries from the
        // in-memory list and persistence immediately, so the stale URL should
        // be removed and only the real URL should remain.
        let stale = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_928374.step")
        store.add(url: stale)
        XCTAssertEqual(store.urls.count, 1, "stale URL should be cleaned on add")
        XCTAssertEqual(store.urls.first, real, "only the real URL should remain")
        XCTAssertFalse(store.urls.contains(stale), "stale URL should not be retained")
    }

    func testStalePathsFilteredOnRead() {
        // recentURLs() should filter out paths that don't exist on disk.
        let staleURL = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_928374.step")
        let validURL = URL(fileURLWithPath: "/tmp")

        store.add(url: validURL)
        store.add(url: staleURL)

        let filtered = store.recentURLs()
        XCTAssertFalse(filtered.contains(staleURL), "stale path should be filtered")
        XCTAssertTrue(filtered.contains(validURL), "valid path /tmp should be present")
    }

    // MARK: - New tests

    /// Verify that URLs persist across simulated "restarts" (new store instance
    /// backed by the same UserDefaults).
    func testRestartPersistence() {
        let url1 = makeTempFile(name: "persist_a")
        let url2 = makeTempFile(name: "persist_b")

        // Simulate first launch: create store A, add URLs.
        let suiteName = "com.mmforge.test_persist"
        let defaultsA = UserDefaults(suiteName: suiteName)!
        let storeA = RecentDocumentStore(userDefaults: defaultsA)
        storeA.add(url: url1)
        storeA.add(url: url2)
        XCTAssertEqual(storeA.urls.count, 2)
        XCTAssertEqual(storeA.urls.first, url2)
        XCTAssertEqual(storeA.urls.last, url1)

        // Simulate restart: create store B with the same UserDefaults suite.
        let defaultsB = UserDefaults(suiteName: suiteName)!
        let storeB = RecentDocumentStore(userDefaults: defaultsB)
        XCTAssertEqual(storeB.urls.count, 2, "URLs should survive restart")
        XCTAssertEqual(storeB.urls.first, url2, "order should be preserved")
        XCTAssertEqual(storeB.urls.last, url1, "order should be preserved")

        // Clean up.
        storeB.clear()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// Verify that stale (unreachable) URLs are cleaned from both the in-memory
    /// list and the persisted UserDefaults on init.
    func testStaleCleanupOnInit() {
        let suiteName = "com.mmforge.test_stale_cleanup"
        let defaults = UserDefaults(suiteName: suiteName)!

        // Write a mix of valid and stale URLs directly to UserDefaults,
        // simulating what a previous session might have persisted.
        let validURL = makeTempFile(name: "valid_keep")
        let staleURL = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_928374.step")
        let persistedStrings = [staleURL.path, validURL.path]
        defaults.set(persistedStrings, forKey: "MMForgeRecentDocuments")

        // Create a new store — init() should clean the stale entry.
        let freshStore = RecentDocumentStore(userDefaults: defaults)
        XCTAssertEqual(freshStore.urls.count, 1, "stale URL should be removed on init")
        XCTAssertTrue(freshStore.urls.contains(validURL), "valid URL should survive")
        XCTAssertFalse(freshStore.urls.contains(staleURL), "stale URL should be gone")

        // Verify the persisted UserDefaults was also cleaned (saved back).
        let savedStrings = defaults.stringArray(forKey: "MMForgeRecentDocuments") ?? []
        XCTAssertEqual(savedStrings.count, 1, "persisted list should also be cleaned")
        XCTAssertTrue(savedStrings.contains(validURL.path), "valid path should persist")
        XCTAssertFalse(savedStrings.contains(staleURL.path), "stale path should be removed from persistence")

        // Clean up.
        freshStore.clear()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}
